import Darwin
import Foundation

public struct CommandDiagnostics: Equatable, Sendable {
  public let effectivePATH: String
  public let resolvedExecutable: String?
  public let executableVersion: String?
  public let versionTimedOut: Bool

  public init(
    effectivePATH: String,
    resolvedExecutable: String?,
    executableVersion: String?,
    versionTimedOut: Bool
  ) {
    self.effectivePATH = effectivePATH
    self.resolvedExecutable = resolvedExecutable
    self.executableVersion = executableVersion
    self.versionTimedOut = versionTimedOut
  }
}

public enum CommandDiagnosticsError: Error, Equatable, Sendable {
  case emptyCommand
  case probeFailed(String)
}

/// Resolves the command using the same startup-file classes and environment
/// layering as a job spawn, then probes the resolved executable's version.
public enum CommandDiagnosticsResolver {
  public static func resolve(
    job: Job,
    launchdEnvironment: [String: String] = SpawnEnvironment.launchdLikeBase(),
    versionTimeout: Duration = .seconds(2)
  ) async throws -> CommandDiagnostics {
    guard !job.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw CommandDiagnosticsError.emptyCommand
    }

    let defaults = SpawnEnvironment.jobDefaults(
      jobID: job.id.uuidString, windowSize: .default)
    let effectiveEnvironment = SpawnEnvironment.layered(
      launchdEnvironment, defaults, job.env)
    let executableName = job.command
      .split(whereSeparator: { $0 == " " || $0 == "\t" })
      .first.map(String.init)
    guard let executableName, !executableName.isEmpty else {
      throw CommandDiagnosticsError.emptyCommand
    }

    let effectivePATH: String
    let executable: String?
    switch job.shellMode {
    case .direct:
      effectivePATH = effectiveEnvironment["PATH"] ?? ""
      executable = SpawnEnvironment.resolveExecutable(executableName, path: effectivePATH)
    case .login, .interactiveLogin:
      let values = try await shellResolution(
        executableName: executableName,
        mode: job.shellMode,
        launchdEnvironment: launchdEnvironment,
        finalEnvironment: SpawnEnvironment.layered(defaults, job.env),
        workingDirectory: job.workingDirectory)
      effectivePATH = values.path
      executable = values.executable
    }

    guard let executable else {
      return CommandDiagnostics(
        effectivePATH: effectivePATH,
        resolvedExecutable: nil,
        executableVersion: nil,
        versionTimedOut: false)
    }

    let version = await runProbe(
      executable: executable,
      arguments: ["--version"],
      environment: effectiveEnvironment.merging(["PATH": effectivePATH]) { _, new in new },
      workingDirectory: job.workingDirectory,
      timeout: versionTimeout)
    let versionLine = version.output?
      .split(whereSeparator: \.isNewline)
      .first
      .map { String($0.prefix(200)) }
    return CommandDiagnostics(
      effectivePATH: effectivePATH,
      resolvedExecutable: executable,
      executableVersion: version.timedOut ? nil : versionLine,
      versionTimedOut: version.timedOut)
  }

  private static func shellResolution(
    executableName: String,
    mode: ShellMode,
    launchdEnvironment: [String: String],
    finalEnvironment: [String: String],
    workingDirectory: URL
  ) async throws -> (path: String, executable: String?) {
    let exports = finalEnvironment.sorted { $0.key < $1.key }.map {
      "export \($0.key)=\(ShellMode.shellQuote($0.value))"
    }.joined(separator: "; ")
    let pathMarker = "__RUNSTUFF_PATH__"
    let executableMarker = "__RUNSTUFF_EXECUTABLE__"
    let script =
      "\(exports); printf '\(pathMarker)%s\\n' \"$PATH\"; printf '\(executableMarker)'; command -v -- \(ShellMode.shellQuote(executableName)) || true"
    let shell = launchdEnvironment["SHELL"] ?? "/bin/zsh"
    let arguments: [String]
    switch mode {
    case .login: arguments = ["-l", "-c", script]
    case .interactiveLogin: arguments = ["-l", "-i", "-c", script]
    case .direct: preconditionFailure("Direct mode does not use a shell probe")
    }
    let probe = await runProbe(
      executable: shell,
      arguments: arguments,
      environment: launchdEnvironment,
      workingDirectory: workingDirectory,
      timeout: .seconds(3))
    guard !probe.timedOut, let output = probe.output else {
      throw CommandDiagnosticsError.probeFailed("Shell environment probe timed out")
    }
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard let pathLine = lines.first(where: { $0.hasPrefix(pathMarker) }) else {
      throw CommandDiagnosticsError.probeFailed("Shell environment probe returned no PATH")
    }
    let path = String(pathLine.dropFirst(pathMarker.count))
    let executable = lines.first(where: { $0.hasPrefix(executableMarker) })
      .map { String($0.dropFirst(executableMarker.count)) }
      .flatMap { $0.isEmpty ? nil : $0 }
    return (path, executable)
  }

  private static func runProbe(
    executable: String,
    arguments: [String],
    environment: [String: String],
    workingDirectory: URL,
    timeout: Duration
  ) async -> (output: String?, timedOut: Bool) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = workingDirectory
    process.standardOutput = pipe
    process.standardError = pipe
    let readFD = pipe.fileHandleForReading.fileDescriptor
    _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) | O_NONBLOCK)
    do {
      try process.run()
    } catch {
      return (nil, false)
    }

    var data = Data()
    let outputLimit = 64 * 1024
    var buffer = [UInt8](repeating: 0, count: 4096)
    func drainAvailable() {
      while true {
        let count = read(readFD, &buffer, buffer.count)
        if count > 0 {
          let remaining = outputLimit - data.count
          if remaining > 0 {
            data.append(buffer, count: min(count, remaining))
          }
        } else {
          return
        }
      }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while process.isRunning && clock.now < deadline {
      drainAvailable()
      try? await Task.sleep(for: .milliseconds(10))
    }
    let timedOut = process.isRunning
    if timedOut {
      process.terminate()
      try? await Task.sleep(for: .milliseconds(50))
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
    let reapDeadline = clock.now.advanced(by: .seconds(1))
    while process.isRunning && clock.now < reapDeadline {
      try? await Task.sleep(for: .milliseconds(10))
    }
    drainAvailable()
    let output = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (output.isEmpty ? nil : output, timedOut)
  }
}
