import Darwin
import Foundation
import XCTest

@testable import RunStuffCore

final class SupervisorTests: XCTestCase {
  func testCleanExitRetainsOutputAndClearsRuntimeRecord() async throws {
    let context = try TestContext(script: "printf 'hello\\n'\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])

    try await supervisor.start(jobID: context.job.id)
    let snapshot = try await waitForCompletion(supervisor, jobID: context.job.id)

    XCTAssertEqual(snapshot.state, .exited(code: 0))
    XCTAssertEqual(snapshot.health, .ok)
    let output = await supervisor.output(jobID: context.job.id)
    XCTAssertEqual(output.map(\.stripped).joined(), "hello\r\n")
    XCTAssertEqual(try context.registry.load(), [])
  }

  func testANSIWrappedSignalRuleChangesHealthWithoutChangingRawOutput() async throws {
    let context = try TestContext(script: "printf '\\033[31mEADDRINUSE\\033[0m\\n'\n")
    defer { context.remove() }
    let rule = SignalRule(pattern: "EADDRINUSE", severity: .error, notify: true)
    let supervisor = try context.makeSupervisor(signals: [rule])

    try await supervisor.start(jobID: context.job.id)
    let snapshot = try await waitForCompletion(supervisor, jobID: context.job.id)

    guard case .error(let reason, _) = snapshot.health else {
      return XCTFail("expected signal rule to set error health, got \(snapshot.health)")
    }
    XCTAssertEqual(reason, "EADDRINUSE")
    let output = await supervisor.output(jobID: context.job.id)
    XCTAssertTrue(output[0].raw.contains(0x1B))
    XCTAssertEqual(output[0].stripped, "EADDRINUSE\r\n")
  }

  func testOutputReadyRuleMatchesStrippedOutputOnce() async throws {
    let context = try TestContext(script: "printf '\\033[32mready in 20ms\\033[0m\\n'; sleep 1\n")
    defer { context.remove() }
    var job = context.job
    job.readyRule = .outputPattern("READY IN")
    let supervisor = try context.makeSupervisor(job: job, signals: [])

    try await supervisor.start(jobID: job.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
      if await supervisor.snapshot(jobID: job.id)?.isReady == true { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    let snapshot = await supervisor.snapshot(jobID: job.id)
    XCTAssertEqual(snapshot?.isReady, true)
    try await supervisor.stop(jobID: job.id, grace: .seconds(1))
    _ = try await waitForCompletion(supervisor, jobID: job.id)
  }

  func testPortReadyRuleMatchesDetectedListener() async throws {
    guard let port = ProcessTable.freeLoopbackPort() else {
      return XCTFail("no free loopback port")
    }
    let context = try TestContext(script: "exec /usr/bin/nc -l \(port)\n")
    defer { context.remove() }
    var job = context.job
    job.readyRule = .port(Int(port))
    let supervisor = try context.makeSupervisor(job: job, signals: [])

    try await supervisor.start(jobID: job.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while ContinuousClock.now < deadline {
      if await supervisor.snapshot(jobID: job.id)?.isReady == true { break }
      try await Task.sleep(for: .milliseconds(20))
    }

    let snapshot = await supervisor.snapshot(jobID: job.id)
    XCTAssertEqual(snapshot?.isReady, true)
    XCTAssertEqual(snapshot?.listeningPorts, [port])
    try await supervisor.stop(jobID: job.id, grace: .seconds(1))
    _ = try await waitForCompletion(supervisor, jobID: job.id)
  }

  func testTerminalFeedReplaysCompleteAndPendingOutputThenContinuesLive() async throws {
    let context = try TestContext(
      script: "printf 'before\\n'; printf 'prompt: '; touch ready; sleep 1; printf 'after\\n'\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])

    try await supervisor.start(jobID: context.job.id)
    while !FileManager.default.fileExists(
      atPath: context.directory.appendingPathComponent("ready").path)
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(50))

    let feed = await supervisor.terminalOutput(jobID: context.job.id)
    var iterator = feed.makeAsyncIterator()
    guard case .reset? = await iterator.next(),
      case .bytes(let replay)? = await iterator.next(),
      case .bytes(let live)? = await iterator.next()
    else {
      return XCTFail("terminal feed ended before replay and live output arrived")
    }

    XCTAssertEqual(String(decoding: replay, as: UTF8.self), "before\r\nprompt: ")
    XCTAssertEqual(String(decoding: live, as: UTF8.self), "after\r\n")
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)
  }

  func testTerminalSessionFeedFinishesAfterFinalOutput() async throws {
    let context = try TestContext(script: "printf 'session complete\\n'; sleep 0.1\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])

    try await supervisor.start(jobID: context.job.id)
    let feed = await supervisor.terminalSessionOutput(jobID: context.job.id)
    var bytes: [UInt8] = []
    for await event in feed {
      if case .bytes(let chunk) = event { bytes.append(contentsOf: chunk) }
    }

    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "session complete\r\n")
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)
  }

  func testUserStopDoesNotMarkJobUnhealthy() async throws {
    let context = try TestContext(script: "while :; do sleep 1; done\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])

    try await supervisor.start(jobID: context.job.id)
    try await supervisor.stop(jobID: context.job.id, grace: .seconds(1))
    let snapshot = try await waitForCompletion(supervisor, jobID: context.job.id)

    XCTAssertEqual(snapshot.health, .ok)
  }

  func testPreviousSessionCanAdoptAndStopARecordedJob() async throws {
    let context = try TestContext(script: "trap '' TERM\nwhile :; do sleep 1; done\n")
    defer { context.remove() }
    let original = try context.makeSupervisor(signals: [])
    try await original.start(jobID: context.job.id)

    let relaunched = try context.makeSupervisor(signals: [])
    do {
      try await relaunched.start(jobID: context.job.id)
      XCTFail("a live orphan must block a duplicate start")
    } catch {
      XCTAssertEqual(error as? SupervisorError, .orphanUnavailable)
    }
    try await relaunched.adoptOrphan(jobID: context.job.id)
    let adopted = await relaunched.snapshot(jobID: context.job.id)
    XCTAssertEqual(adopted?.isAdopted, true)
    XCTAssertNotNil(adopted?.pid)

    try await relaunched.stop(jobID: context.job.id, grace: .milliseconds(50))
    _ = try await waitForCompletion(original, jobID: context.job.id)
    let stopped = await relaunched.snapshot(jobID: context.job.id)
    XCTAssertEqual(stopped?.state, .idle)
    XCTAssertEqual(try context.registry.load(), [])
  }

  func testDirectCommandNotFoundUsesShellModeHint() async throws {
    let context = try TestContext(script: "exit 0\n")
    defer { context.remove() }
    var missing = context.job
    missing.command = "definitely-not-a-command-4f2a"
    let supervisor = try context.makeSupervisor(job: missing, signals: [])

    try await supervisor.start(jobID: missing.id)
    let snapshot = await supervisor.snapshot(jobID: missing.id)

    XCTAssertEqual(snapshot?.state, .failedToStart(RunStuffMessage.commandNotFound))
  }

  func testMetricsReadTheWholeCurrentProcessGroup() {
    let reading = MetricsSampler.readProcessGroup(getpgrp())
    XCTAssertGreaterThan(reading.residentBytes, 0)
    XCTAssertGreaterThan(reading.cpuNanoseconds, 0)
  }

  func testCrashRestartUsesBackoffAndStopsAtMaximum() async throws {
    let context = try TestContext(script: "echo x >> count\nexit 1\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(
      signals: [], restartOnCrash: true, maxRestarts: 2)

    let started = ContinuousClock.now
    try await supervisor.start(jobID: context.job.id)
    let deadline = started.advanced(by: .seconds(6))
    var final: JobSnapshot?
    while ContinuousClock.now < deadline {
      if let snapshot = await supervisor.snapshot(jobID: context.job.id),
        case .error(let reason, _) = snapshot.health,
        reason.hasPrefix("Restart loop:")
      {
        final = snapshot
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertNotNil(final)
    let runs = try String(
      contentsOf: context.directory.appendingPathComponent("count"), encoding: .utf8
    )
    .split(separator: "\n").count
    XCTAssertEqual(runs, 3)
    XCTAssertGreaterThanOrEqual((ContinuousClock.now - started).seconds, 3)
  }

  func testPromptDetectionRequiresAnUnterminatedPromptShape() {
    XCTAssertTrue(isPromptLike("Continue? "))
    XCTAssertTrue(isPromptLike("Deploy [Y/n] "))
    XCTAssertFalse(isPromptLike("Continue?\n"))
    XCTAssertFalse(isPromptLike("ordinary output "))
  }

  func testWaitingInputDetectionWarnsOnlyWhenEnabled() async throws {
    let context = try TestContext(script: "printf 'Continue? '; sleep 10\n")
    defer { context.remove() }
    var job = context.job
    job.notifyWhenWaitingForInput = true
    let supervisor = try context.makeSupervisor(job: job, signals: [])

    try await supervisor.start(jobID: job.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    var warned = false
    while ContinuousClock.now < deadline {
      if let snapshot = await supervisor.snapshot(jobID: job.id),
        case .warning(let reason, _) = snapshot.health, reason == "Waiting for input"
      {
        warned = true
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    XCTAssertTrue(warned)
    try await supervisor.stop(jobID: job.id, grace: .seconds(1))
    _ = try await waitForCompletion(supervisor, jobID: job.id)
  }

  func testSustainedHighCPURequiresContinuousThresholdAndFiresOnce() {
    var detector = SustainedHighCPUDetector()
    let start = ContinuousClock.now

    XCTAssertFalse(detector.observe(cpuPercent: 81, at: start, duration: .seconds(2)))
    XCTAssertFalse(
      detector.observe(
        cpuPercent: 79, at: start.advanced(by: .seconds(1)), duration: .seconds(2)))
    XCTAssertFalse(
      detector.observe(
        cpuPercent: 90, at: start.advanced(by: .seconds(2)), duration: .seconds(2)))
    XCTAssertTrue(
      detector.observe(
        cpuPercent: 90, at: start.advanced(by: .seconds(4)), duration: .seconds(2)))
    XCTAssertFalse(
      detector.observe(
        cpuPercent: 90, at: start.advanced(by: .seconds(10)), duration: .seconds(2)))
  }

  func testPreviewRunsWithoutPersistingTheJob() async throws {
    let context = try TestContext(script: "printf 'preview\\n'\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])

    let runtime = try await supervisor.startPreview(context.job)
    XCTAssertEqual(try context.registry.load().count, 1)
    var bytes: [UInt8] = []
    for await chunk in await runtime.attach() {
      bytes.append(contentsOf: chunk.bytes)
    }
    let status = await runtime.waitForExit(timeout: .seconds(2))
    await runtime.close()
    try await supervisor.finishPreview(runtime)

    XCTAssertEqual(status, .exited(code: 0))
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "preview\r\n")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: context.directory.appendingPathComponent("config.json").path))
    XCTAssertEqual(try context.registry.load(), [])
  }

  func testRelaunchCanRecoverAnUnsavedPreview() async throws {
    let context = try TestContext(script: "while :; do sleep 1; done\n")
    defer { context.remove() }
    let original = try context.makeSupervisor(signals: [])
    var preview = context.job
    preview.id = UUID()

    let runtime = try await original.startPreview(preview)
    let relaunched = try context.makeSupervisor(signals: [])
    let recovered = await relaunched.snapshot(jobID: preview.id)
    XCTAssertNotNil(recovered)

    try await relaunched.stopOrphan(jobID: preview.id, grace: .seconds(1))
    let status = await runtime.waitForExit(timeout: .seconds(2))
    XCTAssertNotNil(status)
    _ = await runtime.waitForDrainEnd(timeout: .seconds(2))
    await runtime.close()
    XCTAssertEqual(try context.registry.load(), [])
  }

  private func waitForCompletion(
    _ supervisor: Supervisor, jobID: UUID, timeout: Duration = .seconds(5)
  ) async throws -> JobSnapshot {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let snapshot = await supervisor.snapshot(jobID: jobID), snapshot.pid == nil {
        switch snapshot.state {
        case .exited, .signalled, .failedToStart:
          return snapshot
        case .idle, .starting, .running, .stopping:
          break
        }
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw TestFailure.timedOut
  }
}

private enum TestFailure: Error {
  case timedOut
}

private struct TestContext {
  let directory: URL
  let job: Job
  let configStore: ConfigStore
  let registry: RuntimeRegistry
  let helperPath: String

  init(script: String) throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let scriptURL = directory.appendingPathComponent("job.sh")
    try Data(("#!/bin/sh\n" + script).utf8).write(to: scriptURL)
    XCTAssertEqual(chmod(scriptURL.path, 0o700), 0)
    job = Job(
      name: "Test",
      command: scriptURL.path,
      workingDirectory: directory,
      shellMode: .direct,
      colorSeed: 1)
    configStore = ConfigStore(fileURL: directory.appendingPathComponent("config.json"))
    registry = RuntimeRegistry(fileURL: directory.appendingPathComponent("runtime.json"))
    helperPath = Self.findHelper()
  }

  func makeSupervisor(
    signals: [SignalRule], restartOnCrash: Bool = false, maxRestarts: Int = 3
  ) throws -> Supervisor {
    try makeSupervisor(
      job: job, signals: signals, restartOnCrash: restartOnCrash, maxRestarts: maxRestarts)
  }

  func makeSupervisor(
    job: Job, signals: [SignalRule], restartOnCrash: Bool = false, maxRestarts: Int = 3
  ) throws -> Supervisor {
    var configuredJob = job
    configuredJob.signals = signals
    configuredJob.restartOnCrash = restartOnCrash
    configuredJob.maxRestarts = maxRestarts
    return try Supervisor(
      configuration: RunStuffConfiguration(jobs: [configuredJob]),
      configStore: configStore,
      runtimeRegistry: registry,
      ttyHelperPath: helperPath,
      spoolDirectory: directory.path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  private static func findHelper() -> String {
    if let override = ProcessInfo.processInfo.environment["RUNSTUFF_TTY_HELPER"] {
      return override
    }
    let testBundle = Bundle(for: SupervisorTests.self).bundleURL
    return testBundle.deletingLastPathComponent().appendingPathComponent("runstuff-tty-helper").path
  }
}
