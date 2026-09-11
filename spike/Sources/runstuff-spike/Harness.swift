import Darwin
import Foundation
import RunStuffCore

/// Shared configuration for every scenario.
struct Harness: Sendable {
  let fixturesDirectory: String
  let repoRoot: String
  let shell: String
  let spoolDirectory: String
  let ttyHelperPath: String
  let verbose: Bool

  func fixture(_ name: String) -> String { "\(fixturesDirectory)/\(name)" }

  /// A spec for running `command` (an argv) under `mode`, from a scrubbed
  /// launchd-like environment plus RunStuff's job defaults.
  func spec(
    _ mode: ShellMode, command: [String], cwd: String? = nil,
    windowSize: WindowSize = .default, extraEnv: [String: String] = [:]
  ) -> SpawnSpec {
    SpawnSpec(
      argv: mode.argv(command: command, shell: shell),
      workingDirectory: cwd ?? repoRoot,
      environment: SpawnEnvironment.layered(
        SpawnEnvironment.launchdLikeBase(),
        SpawnEnvironment.jobDefaults(jobID: "spike", windowSize: windowSize),
        extraEnv),
      windowSize: windowSize,
      ttyHelperPath: ttyHelperPath)
  }

  /// A spec for a command line typed by a user (shell modes pass it through).
  func spec(
    _ mode: ShellMode, commandLine: String, cwd: String? = nil, windowSize: WindowSize = .default
  ) -> SpawnSpec {
    SpawnSpec(
      argv: mode.argv(commandLine: commandLine, shell: shell),
      workingDirectory: cwd ?? repoRoot,
      environment: SpawnEnvironment.layered(
        SpawnEnvironment.launchdLikeBase(),
        SpawnEnvironment.jobDefaults(jobID: "spike", windowSize: windowSize)),
      windowSize: windowSize,
      ttyHelperPath: ttyHelperPath)
  }

  /// Runs a fixture script: direct mode execs `/bin/sh <script>`, shell
  /// modes hand the script path to the shell.
  func scriptSpec(
    _ mode: ShellMode, script: String, arguments: [String] = [], cwd: String? = nil,
    windowSize: WindowSize = .default
  ) -> SpawnSpec {
    let path = fixture(script)
    let command = mode == .direct ? ["/bin/sh", path] + arguments : [path] + arguments
    return spec(mode, command: command, cwd: cwd, windowSize: windowSize)
  }

  func start(_ spec: SpawnSpec) async throws -> JobRuntime {
    let runtime = try JobRuntime.start(spec, spoolDirectory: spoolDirectory)
    await LiveJobs.shared.register(runtime)
    if verbose {
      print(
        "  (spawned pid \(runtime.pid) on \(runtime.slavePath): \(spec.argv.joined(separator: " ")))"
      )
    }
    return runtime
  }

  func supervisor(for job: Job) throws -> (supervisor: Supervisor, directory: URL) {
    let directory = URL(fileURLWithPath: spoolDirectory)
      .appendingPathComponent("supervisor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let supervisor = try Supervisor(
      configuration: RunStuffConfiguration(jobs: [job]),
      configStore: ConfigStore(fileURL: directory.appendingPathComponent("config.json")),
      runtimeRegistry: RuntimeRegistry(fileURL: directory.appendingPathComponent("runtime.json")),
      ttyHelperPath: ttyHelperPath,
      spoolDirectory: directory.path)
    return (supervisor, directory)
  }

  func waitForCompletion(
    _ supervisor: Supervisor, jobID: UUID, timeout: Duration
  ) async -> JobSnapshot? {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if let snapshot = await supervisor.snapshot(jobID: jobID), snapshot.pid == nil {
        switch snapshot.state {
        case .exited, .signalled, .failedToStart:
          return snapshot
        case .idle, .starting, .running, .stopping:
          break
        }
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
  }

  func finish(_ runtime: JobRuntime) async {
    await runtime.close()
    await LiveJobs.shared.unregister(runtime)
  }

  /// Compiles `fixtures/<name>.c` to a binary next to it with `/usr/bin/cc`,
  /// skipping the compile when the binary is already newer than the source.
  /// Uses the inherited environment (cc needs the active Xcode toolchain,
  /// which the scrubbed job environment hides) and captures stderr for the
  /// error message. Returns the binary path, or nil with a reason.
  func compileCFixture(_ name: String) -> (path: String?, detail: String) {
    let src = fixture("\(name).c")
    let out = fixture(name)
    let fm = FileManager.default
    if let srcAttr = try? fm.attributesOfItem(atPath: src),
      let outAttr = try? fm.attributesOfItem(atPath: out),
      let srcDate = srcAttr[.modificationDate] as? Date,
      let outDate = outAttr[.modificationDate] as? Date,
      outDate >= srcDate
    {
      return (out, "already built")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    process.arguments = ["-O2", "-Wall", "-o", out, src]
    process.environment = ProcessInfo.processInfo.environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return (nil, "could not run cc: \(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(
        in: .whitespacesAndNewlines)
      return (nil, "cc exited \(process.terminationStatus): \(text)")
    }
    return (out, "compiled")
  }

  /// Wall time of a command run outside any PTY, for baselines and
  /// precondition probes. Returns (exit code, stdout, seconds).
  func runOutsidePTY(_ argv: [String], cwd: String? = nil, environment: [String: String]? = nil)
    -> (code: Int32, stdout: String, seconds: Double)
  {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    process.currentDirectoryURL = URL(fileURLWithPath: cwd ?? repoRoot)
    process.environment = environment ?? SpawnEnvironment.launchdLikeBase()
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let start = ContinuousClock.now
    do {
      try process.run()
    } catch {
      return (-1, "", 0)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let seconds = (ContinuousClock.now - start).seconds
    return (process.terminationStatus, String(decoding: data, as: UTF8.self), seconds)
  }
}

/// Every runtime that is currently alive, so a scenario timeout or process
/// exit can kill whatever a fixture left running.
actor LiveJobs {
  static let shared = LiveJobs()
  private var jobs: [pid_t: JobRuntime] = [:]

  func register(_ runtime: JobRuntime) { jobs[runtime.pid] = runtime }
  func unregister(_ runtime: JobRuntime) { jobs[runtime.pid] = nil }

  /// SIGKILL to every live job's group and session.
  func killAll() async {
    for runtime in jobs.values {
      _ = await runtime.signalGroup(SIGKILL)
      await runtime.signalSession(SIGKILL)
    }
    jobs.removeAll()
  }
}

/// Runs a scenario with a hard deadline. On timeout every live job is killed
/// so the scenario body can unwind, and the report is marked hung.
func withDeadline(
  _ name: String, _ deadline: Duration, _ body: @escaping @Sendable () async -> ScenarioReport
) async -> ScenarioReport {
  await withTaskGroup(of: ScenarioReport?.self) { group in
    group.addTask { await body() }
    group.addTask {
      try? await Task.sleep(for: deadline)
      return nil
    }
    guard let first = await group.next() else {
      return ScenarioReport(name: name, hung: true)
    }
    if let report = first {
      group.cancelAll()
      return report
    }
    // Timed out. Kill jobs so the body can finish, then keep its partial report.
    await LiveJobs.shared.killAll()
    group.cancelAll()
    var partial = ScenarioReport(name: name, hung: true)
    if let late = await group.next(), let report = late {
      partial = report
      partial.hung = true
    }
    return partial
  }
}

func elapsedSeconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
  (to - from).seconds
}

/// Polls until `condition` holds or `timeout` passes.
func eventually(_ timeout: Duration, every: Duration = .milliseconds(25), _ condition: () -> Bool)
  async -> Bool
{
  let start = ContinuousClock.now
  while true {
    if condition() { return true }
    if ContinuousClock.now - start >= timeout { return false }
    try? await Task.sleep(for: every)
  }
}
