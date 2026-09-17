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
    let history = await supervisor.runHistory()
    XCTAssertEqual(history.first?.exitStatus, "exited(0)")
    XCTAssertEqual(history.first?.metrics, snapshot.metricHistory)
  }

  func testRunHistorySeparatesRunsAndSurvivesRenameDeletionAndRelaunch() async throws {
    let context = try TestContext(
      script: "if [ -e once ]; then printf second; else touch once; printf first; fi\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])
    try await supervisor.start(jobID: context.job.id)
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)
    try await supervisor.start(jobID: context.job.id)
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)

    var renamed = context.job
    renamed.name = "Renamed"
    renamed.command = "changed command"
    try await supervisor.update(renamed)
    try await supervisor.delete(jobID: renamed.id)

    let relaunched = try Supervisor(
      configuration: RunStuffConfiguration(), configStore: context.configStore,
      runtimeRegistry: context.registry, ttyHelperPath: context.helperPath,
      spoolDirectory: context.directory.path)
    let history = await relaunched.runHistory()
    XCTAssertEqual(history.count, 2)
    XCTAssertTrue(history.allSatisfy { $0.name == "Test" && $0.command == context.job.command })
    XCTAssertEqual(
      history.map { String(decoding: $0.rawOutput, as: UTF8.self) }, ["second", "first"])
    XCTAssertEqual(Set(history.map(\.id)).count, 2)
    XCTAssertTrue(history.allSatisfy { !$0.outputTruncated })
  }

  func testManualRestartArchivesFinalOutputAndLaunchTimeName() async throws {
    let context = try TestContext(
      script: """
        if [ -e once ]; then printf second; exit 0; fi
        trap 'printf final; exit 0' TERM
        printf ready
        touch once
        while :; do sleep 0.1; done
        """)
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])
    try await supervisor.start(jobID: context.job.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !FileManager.default.fileExists(
      atPath: context.directory.appendingPathComponent("once").path)
    {
      guard ContinuousClock.now < deadline else { throw TestFailure.timedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
    var renamed = context.job
    renamed.name = "Next run"
    try await supervisor.update(renamed)
    try await supervisor.restart(jobID: context.job.id)
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)
    let history = await supervisor.runHistory()
    XCTAssertEqual(history.map(\.name), ["Next run", "Test"])
    XCTAssertEqual(history.map(\.outcome), ["Exit 0", "Stopped"])
    XCTAssertEqual(history.first?.rawOutput, Data("second".utf8))
    XCTAssertTrue(
      String(decoding: try XCTUnwrap(history.last).rawOutput, as: UTF8.self).hasSuffix("final"))
  }

  func testHistoryLimitDoesNotMarkAnExactlyFullTailAsTruncated() async throws {
    let context = try TestContext(script: "head -c 262144 /dev/zero\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])
    try await supervisor.start(jobID: context.job.id)
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)
    let history = await supervisor.runHistory()
    XCTAssertEqual(history.first?.rawOutput.count, 262144)
    XCTAssertEqual(history.first?.outputTruncated, false)
  }

  func testStopAllPersistsFinalOutputBeforeReturning() async throws {
    let script = "trap 'printf final; exit 0' TERM\ntouch ready\nwhile :; do sleep 0.1; done\n"
    let first = try TestContext(script: script)
    let second = try TestContext(script: script)
    defer {
      first.remove()
      second.remove()
    }
    let supervisor = try first.makeSupervisor(signals: [])
    try await supervisor.add(second.job)
    try await supervisor.start(jobID: first.job.id)
    try await supervisor.start(jobID: second.job.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    for context in [first, second] {
      while !FileManager.default.fileExists(
        atPath: context.directory.appendingPathComponent("ready").path)
      {
        guard ContinuousClock.now < deadline else { throw TestFailure.timedOut }
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    let failures = await supervisor.stopAll()
    XCTAssertEqual(failures, [])
    let persisted = RunHistoryStore(configURL: first.configStore.fileURL).load()
    XCTAssertEqual(Set(persisted.records.map(\.jobID)), [first.job.id, second.job.id])
    XCTAssertTrue(
      persisted.records.allSatisfy {
        $0.outcome == "Stopped" && String(decoding: $0.rawOutput, as: UTF8.self).hasSuffix("final")
      })
  }

  func testRunHistoryKeepsExactLatest256KiB() async throws {
    let context = try TestContext(
      script: "head -c 300000 /dev/zero | tr '\\000' A; printf Z\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])
    try await supervisor.start(jobID: context.job.id)
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)

    let history = await supervisor.runHistory()
    let record = try XCTUnwrap(history.first)
    XCTAssertEqual(record.rawOutput.count, 256 * 1024)
    XCTAssertTrue(record.outputTruncated)
    XCTAssertEqual(record.rawOutput.last, Character("Z").asciiValue)
    XCTAssertTrue(record.rawOutput.dropLast().allSatisfy { $0 == Character("A").asciiValue })
  }

  func testSpawnFailureIsArchivedOnce() async throws {
    let context = try TestContext(script: "exit 0\n")
    defer { context.remove() }
    var job = context.job
    job.command = context.directory.appendingPathComponent("missing").path
    let supervisor = try context.makeSupervisor(job: job, signals: [])
    try await supervisor.start(jobID: job.id)
    _ = try await waitForCompletion(supervisor, jobID: job.id)

    let history = await supervisor.runHistory()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.first?.outcome, "Failed to start")
    XCTAssertNotNil(history.first?.failureSummary)
  }

  func testHistorySkipsCorruptRecordsAndKeepsPrivateFiles() async throws {
    let context = try TestContext(script: "printf saved\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])
    try await supervisor.start(jobID: context.job.id)
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)
    let store = RunHistoryStore(configURL: context.configStore.fileURL)
    let saved = store.load()
    XCTAssertEqual(saved.records.count, 1)
    let record = try XCTUnwrap(saved.records.first)
    let file = store.directory.appendingPathComponent("\(record.id.uuidString).json")
    let permissions =
      try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
    XCTAssertEqual(permissions?.intValue, 0o600)
    let broken = store.directory.appendingPathComponent("broken.json")
    try Data("not JSON".utf8).write(to: broken)
    let reloaded = store.load()
    XCTAssertEqual(reloaded.records, saved.records)
    XCTAssertEqual(reloaded.errors.count, 1)
    XCTAssertEqual(try Data(contentsOf: broken), Data("not JSON".utf8))
  }

  func testHistorySaveFailureKeepsRunAvailableForThisSession() async throws {
    let context = try TestContext(script: "printf unsaved\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])
    try Data().write(to: context.directory.appendingPathComponent("history"))
    try await supervisor.start(jobID: context.job.id)
    _ = try await waitForCompletion(supervisor, jobID: context.job.id)
    let history = await supervisor.runHistory()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.first?.rawOutput, Data("unsaved".utf8))
    for await event in supervisor.events {
      if case .persistenceFailed(let message) = event {
        XCTAssertTrue(message.contains("run history"))
        break
      }
      if case .jobExited = event {
        XCTFail("Missing history persistence error")
        break
      }
    }
  }

  func testANSIWrappedSignalRuleChangesHealthWithoutChangingRawOutput() async throws {
    let context = try TestContext(
      script: "printf '\\033[31mEADDRINUSE: socket busy\\033[0m\\n'; exit 1\n")
    defer { context.remove() }
    let rule = SignalRule(pattern: "EADDRINUSE", severity: .error, notify: true)
    let supervisor = try context.makeSupervisor(signals: [rule])

    try await supervisor.start(jobID: context.job.id)
    let snapshot = try await waitForCompletion(supervisor, jobID: context.job.id)

    guard case .error(let reason, _) = snapshot.health else {
      return XCTFail("expected signal rule to set error health, got \(snapshot.health)")
    }
    XCTAssertEqual(reason, "EADDRINUSE: socket busy")
    XCTAssertEqual(snapshot.failure?.summary, "EADDRINUSE: socket busy")
    let output = await supervisor.output(jobID: context.job.id)
    XCTAssertTrue(output[0].raw.contains(0x1B))
    XCTAssertEqual(output[0].stripped, "EADDRINUSE: socket busy\r\n")
  }

  func testPortConflictParsingUsesTheBindAddressNotOtherNumbers() {
    let line =
      #"smokescreen | {"level":"fatal","msg":"can't find listenerlisten tcp :3400: bind: address already in use","time":"2026-09-16T18:01:23+10:00"}"#
    let failure = FailureDiagnostic.portConflict(in: line)
    XCTAssertEqual(failure?.conflictingPort, 3400)
    XCTAssertEqual(failure?.summary, "Could not listen on TCP port 3400: address already in use.")
    XCTAssertEqual(failure?.evidence, line)
    XCTAssertEqual(
      FailureDiagnostic.portConflict(
        in: "Error: listen EADDRINUSE: address already in use :::5173")?.conflictingPort, 5173)
    XCTAssertEqual(
      FailureDiagnostic.portConflict(in: "listen tcp [::1]:65535: bind: address already in use")?
        .conflictingPort, 65535)
    for text in [
      "listen tcp :65536: bind: address already in use",
      "listen tcp :0: bind: address already in use",
      "Listening on port 3100; error count 3400",
      "EADDRINUSE in documentation for port 3400",
      "dial tcp :3400: bind: address already in use",
    ] {
      XCTAssertNil(FailureDiagnostic.portConflict(in: text), text)
    }
  }

  func testPumaPortConflictRetainsEvidenceAndRejectsOtherErrors() {
    let line =
      #"puma-agent | /ruby/4.0.6/gems/puma-7.2.1/lib/puma/binder.rb:344:in 'TCPServer#initialize': Address already in use - bind(2) for "0.0.0.0" port 3800 (Errno::EADDRINUSE)"#
    let diagnostic = FailureDiagnostic.portConflict(in: line)
    XCTAssertEqual(diagnostic?.conflictingPort, 3800)
    XCTAssertEqual(
      diagnostic?.summary, "Could not listen on TCP port 3800: address already in use.")
    XCTAssertEqual(diagnostic?.evidence, line)
    XCTAssertEqual(FailureDiagnostic.matchedLine(line), diagnostic)
    for invalid in [
      line.replacingOccurrences(of: "port 3800", with: "port 0"),
      line.replacingOccurrences(of: "port 3800", with: "port 65536"),
      line.replacingOccurrences(of: "Errno::EADDRINUSE", with: "Errno::EACCES"),
      line.replacingOccurrences(of: "TCPServer#initialize", with: "UDPSocket#bind"),
    ] {
      XCTAssertNil(FailureDiagnostic.portConflict(in: invalid), invalid)
    }
  }

  func testExitEventIncludesFinalUnterminatedFailureAndEvidenceResetsOnNextRun() async throws {
    let context = try TestContext(
      script: """
        if [ -e once ]; then exit 0; fi
        touch once
        printf 'listen tcp :3400: bind: address already in use'
        exit 1
        """)
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])
    try await supervisor.start(jobID: context.job.id)
    let snapshot = try await waitForCompletion(supervisor, jobID: context.job.id)
    XCTAssertEqual(snapshot.failure?.conflictingPort, 3400)
    let history = await supervisor.runHistory()
    XCTAssertEqual(history.first?.conflictingPort, 3400)
    XCTAssertEqual(history.first?.failureEvidence, "listen tcp :3400: bind: address already in use")
    var sawFinalSnapshot = false
    for await event in supervisor.events {
      if case .jobChanged(let snapshot) = event, snapshot.pid == nil,
        snapshot.failure?.conflictingPort == 3400
      {
        sawFinalSnapshot = true
      }
      if case .jobExited(let id, let status, let userInitiated, let failure, _) = event {
        XCTAssertEqual(id, context.job.id)
        XCTAssertEqual(status, .exited(code: 1))
        XCTAssertFalse(userInitiated)
        XCTAssertTrue(sawFinalSnapshot)
        XCTAssertEqual(failure?.conflictingPort, 3400)
        break
      }
    }
    try await supervisor.start(jobID: context.job.id)
    let restarted = try await waitForCompletion(supervisor, jobID: context.job.id)
    XCTAssertEqual(restarted.health, .ok)
    XCTAssertNil(restarted.failure)
    XCTAssertNil(restarted.reportedPortConflict)
    for await event in supervisor.events {
      if case .jobExited(_, _, _, _, let reportedPortConflict) = event {
        XCTAssertNil(reportedPortConflict)
        break
      }
    }
  }

  func testConflictTextDoesNotTurnCleanExitIntoFailure() async throws {
    let context = try TestContext(
      script: """
        printf '%s\\n' 'smokescreen | {"level":"fatal","msg":"can’t find listenerlisten tcp :3400: bind: address already in use"}'
        printf '%s\\n' 'smokescreen | Exited with code 1' 'puma | Interrupting...' 'puma | Exited with code 0'
        exit 0
        """)
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])
    try await supervisor.start(jobID: context.job.id)
    let snapshot = try await waitForCompletion(supervisor, jobID: context.job.id)
    XCTAssertEqual(snapshot.health, .ok)
    XCTAssertNil(snapshot.failure)
    XCTAssertEqual(snapshot.reportedPortConflict?.conflictingPort, 3400)
    var sawReportedSnapshot = false
    for await event in supervisor.events {
      if case .jobChanged(let changed) = event,
        changed.reportedPortConflict?.conflictingPort == 3400
      {
        sawReportedSnapshot = true
      }
      if case .jobExited(_, let status, let userInitiated, let failure, let reportedPortConflict) =
        event
      {
        XCTAssertTrue(sawReportedSnapshot)
        XCTAssertEqual(status, .exited(code: 0))
        XCTAssertFalse(userInitiated)
        XCTAssertNil(failure)
        XCTAssertEqual(reportedPortConflict?.conflictingPort, 3400)
        XCTAssertTrue(reportedPortConflict?.evidence.contains("smokescreen") == true)
        break
      }
    }
    let configured = try context.makeSupervisor(signals: [
      SignalRule(pattern: "address already in use", severity: .error, notify: true)
    ])
    try await configured.start(jobID: context.job.id)
    let matched = try await waitForCompletion(configured, jobID: context.job.id)
    XCTAssertEqual(matched.state, .exited(code: 0))
    XCTAssertEqual(matched.failure?.conflictingPort, 3400)
    guard case .error = matched.health else {
      return XCTFail("the explicit rule must still mark failure")
    }
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
    let context = try TestContext(
      script:
        "printf 'listen tcp :3400: bind: address already in use\\n'; while :; do sleep 1; done\n")
    defer { context.remove() }
    let supervisor = try context.makeSupervisor(signals: [])

    try await supervisor.start(jobID: context.job.id)
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await supervisor.output(jobID: context.job.id).isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    let outputBeforeStop = await supervisor.output(jobID: context.job.id)
    XCTAssertFalse(outputBeforeStop.isEmpty)
    try await supervisor.stop(jobID: context.job.id, grace: .seconds(1))
    let snapshot = try await waitForCompletion(supervisor, jobID: context.job.id)

    XCTAssertEqual(snapshot.health, .ok)
    XCTAssertNil(snapshot.failure)
    XCTAssertNil(snapshot.reportedPortConflict)
    for await event in supervisor.events {
      if case .jobExited(_, _, let userInitiated, _, _) = event {
        XCTAssertTrue(userInitiated)
        break
      }
    }
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
    let history = await relaunched.runHistory()
    XCTAssertEqual(history.count, 1)
    XCTAssertEqual(history.first?.isRecovered, true)
    XCTAssertEqual(history.first?.outcome, "Stopped")
    XCTAssertEqual(history.first?.rawOutput, Data())
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
    let history = await supervisor.runHistory()
    XCTAssertEqual(history.count, 3)
    XCTAssertTrue(history.allSatisfy { $0.outcome == "Exit 1" })
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
