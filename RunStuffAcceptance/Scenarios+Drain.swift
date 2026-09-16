import Darwin
import Dispatch
import RunStuffCore

private actor SignalCounter {
  private(set) var count = 0

  func increment() { count += 1 }
}

/// Proves the runtime drains the master from spawn with no subscriber
/// attached. Nothing calls `attach()`; if the drain were subscriber-gated the
/// child would block on `write()` filling the PTY buffer and never exit.
func writesThenExitsScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("writes-then-exits.sh")
  do {
    let runtime = try await h.start(h.scriptSpec(.direct, script: "writes-then-exits.sh"))
    // Deliberately no attach().
    let exit = await runtime.waitForExit(timeout: .seconds(20))
    let drain = await runtime.waitForDrainEnd(timeout: .seconds(5))
    let spooled = await runtime.spooledLength()
    check.p0(
      "exits with nothing attached", exit == .exited(code: 0),
      detail: "\(exit.map { "\($0)" } ?? "still running: drain is subscriber-gated")")
    check.p0(
      "drain ended at EOF", drain == .eof || drain == .eio,
      detail: "\(drain.map { "\($0)" } ?? "none")")
    check.p0(
      "full 1 MB drained without a subscriber", spooled >= 1_048_576,
      detail: "\(formatBytes(spooled)) spooled")
    await h.finish(runtime)
  } catch {
    check.p0("spawn", false, detail: "\(error)")
  }
  return check.report
}

/// Resize when the tty's foreground process group is NOT the job leader's,
/// the exact divergence finding #4 describes. The C helper foregrounds a
/// child in its own group with `tcsetpgrp`, so a correct `resize()` must
/// target `tcgetpgrp(master)`, not the job's static pgid. Also observes what
/// an interactive login shell does to the foreground group, a separate finding.
func resizeJobControlScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("winch-fg (resize under job control)")

  // Deterministic divergent-foreground-group case via the C helper.
  let build = h.compileCFixture("winch-fg")
  guard let helper = build.path else {
    check.p0("compile winch-fg.c with cc", false, detail: build.detail)
    return check.report
  }
  do {
    let runtime = try await h.start(
      h.spec(.direct, command: [helper], windowSize: WindowSize(rows: 40, cols: 120)))
    let recorder = Recorder(await runtime.attach())
    let ready = await recorder.waitFor("READY", timeout: .seconds(10))
    check.p0("helper ran and forked a child", ready != nil)
    let leaderCtty = await recorder.value(after: "LEADER-CTTY ")
    let leaderFg0 = await recorder.value(after: "LEADER-FG0 ")
    let childPgid = await recorder.value(after: "CHILD-PGID ").flatMap { pid_t($0) }
    let leaderLine = await recorder.value(after: "LEADER-PGID ")
    let foreground = await runtime.foregroundGroup()
    check.note(
      "raw (non-shell) spawned program: /dev/tty open = \(leaderCtty ?? "?"), its tcgetpgrp(fd0) = \(leaderFg0 ?? "?")"
    )
    check.p0(
      "raw binary has the PTY as its controlling terminal",
      leaderCtty == "yes" && leaderFg0 == "\(runtime.pgid)",
      detail: "open /dev/tty = \(leaderCtty ?? "?"), foreground = \(leaderFg0 ?? "?")")

    if leaderCtty == "yes", let childPgid, foreground == childPgid, foreground != runtime.pgid {
      // Divergent foreground group established: assert resize targets it.
      check.p0(
        "resize reached the foreground child, not the job leader",
        await { () -> Bool in
          try? await runtime.resize(WindowSize(rows: 24, cols: 60))
          return await recorder.waitFor("SIZE 24 60", from: ready ?? 0, timeout: .seconds(5)) != nil
        }(),
        detail: "foreground group \(foreground) != job pgid \(runtime.pgid)")
    } else {
      check.p0(
        "resize reaches a divergent foreground group", false,
        detail:
          "raw binary did not establish the required foreground group (LEADER-CTTY=\(leaderCtty ?? "?"), tcgetpgrp master=\(foreground), leader [\(leaderLine ?? "")])"
      )
    }
    _ = await runtime.stop(grace: .seconds(2))
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("spawn/resize", false, detail: "\(error)")
  }

  // Re-measure the earlier interactive-login finding after establishing the
  // controlling terminal in the helper.
  do {
    let runtime = try await h.start(
      h.spec(
        .interactiveLogin, commandLine: "\(h.fixture("resize-job-control.sh")) && true",
        windowSize: WindowSize(rows: 40, cols: 120)))
    let recorder = Recorder(await runtime.attach())
    _ = await recorder.waitFor("READY", timeout: .seconds(15))
    try? await Task.sleep(for: .milliseconds(300))
    let foreground = await runtime.foregroundGroup()
    try await runtime.resize(WindowSize(rows: 24, cols: 60))
    let resized = await recorder.waitFor("SIZE 24 60", from: 0, timeout: .seconds(3))
    if foreground <= 0 {
      check.p0(
        "interactive login shell keeps a foreground group", false,
        detail: "tcgetpgrp=\(foreground); refusing any negated kill for this value")
    } else {
      check.p0(
        "interactive login shell keeps a foreground group", resized != nil,
        detail:
          "foreground group \(foreground); resize \(resized != nil ? "reached" : "did not reach") the command"
      )
    }
    _ = await runtime.stop(grace: .seconds(2))
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.note("interactive-login observation failed to spawn: \(error)")
  }

  // Negative case for the negated-kill guard. Without the tty helper a raw
  // program leaves tcgetpgrp(master) at zero. An unguarded kill(-0,
  // SIGWINCH) would signal the harness's own process group.
  do {
    var spec = h.spec(
      .direct, command: [helper], windowSize: WindowSize(rows: 40, cols: 120))
    spec.ttyHelperPath = nil
    let runtime = try await h.start(spec)
    let recorder = Recorder(await runtime.attach())
    _ = await recorder.waitFor("READY", timeout: .seconds(10))
    let foreground = await runtime.foregroundGroup()

    signal(SIGWINCH, SIG_IGN)
    let counter = SignalCounter()
    let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    source.setEventHandler {
      Task { await counter.increment() }
    }
    source.resume()
    try await runtime.resize(WindowSize(rows: 24, cols: 60))
    try? await Task.sleep(for: .milliseconds(200))
    source.cancel()
    let received = await counter.count
    check.p0(
      "resize refuses a non-positive foreground group",
      foreground <= 0 && received == 0,
      detail: "tcgetpgrp=\(foreground), harness received \(received) SIGWINCH signals")

    _ = await runtime.stop(grace: .seconds(1))
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("non-positive foreground-group guard", false, detail: "\(error)")
  }
  return check.report
}

/// Job B must not keep job A's slave open. If it inherited that fd, A would
/// exit but its master would not reach EOF until B also ended.
func eofIsolationScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("eof-isolation (sibling remains running)")
  var first: JobRuntime?
  var sibling: JobRuntime?
  do {
    let a = try await h.start(h.scriptSpec(.direct, script: "prompt-wait.sh"))
    first = a
    let firstRecorder = Recorder(await a.attach())
    check.p0(
      "job A reached its prompt",
      await firstRecorder.waitFor("Continue?", timeout: .seconds(5)) != nil)

    let b = try await h.start(h.scriptSpec(.direct, script: "prompt-wait.sh"))
    sibling = b
    let siblingRecorder = Recorder(await b.attach())
    check.p0(
      "job B is running concurrently",
      await siblingRecorder.waitFor("Continue?", timeout: .seconds(5)) != nil)

    try await a.write(Array("yes\n".utf8))
    let exit = await a.waitForExit(timeout: .seconds(2))
    let drain = await a.waitForDrainEnd(timeout: .seconds(2))
    let siblingAlive = ProcessTable.info(pid: b.pid)?.isZombie == false
    check.p0("job A exited while job B remained alive", exit == .exited(code: 0) && siblingAlive)
    check.p0(
      "job A reached EOF while job B remained alive",
      (drain == .eof || drain == .eio) && siblingAlive,
      detail: "drain = \(drain.map { "\($0)" } ?? "none")")

    _ = await b.stop(grace: .seconds(1))
    _ = await b.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(a)
    first = nil
    await h.finish(b)
    sibling = nil
  } catch {
    check.p0("spawn/input", false, detail: "\(error)")
    if let first {
      _ = await first.stop(grace: .seconds(1))
      await h.finish(first)
    }
    if let sibling {
      _ = await sibling.stop(grace: .seconds(1))
      await h.finish(sibling)
    }
  }
  return check.report
}

/// Hundreds of short-lived jobs spawned concurrently. Stresses the one thing
/// finding #3 (NOTE_EXIT before the child is reapable) can pass in isolation
/// and fail under load: every exit must be detected and every pid reaped,
/// with no thread-per-job blowup and no leaked fds.
func reapStressScenario(_ h: Harness) async -> ScenarioReport {
  let total = 300
  let maxConcurrent = 24
  let check = Check("reap-stress (quick-exit.sh ×\(total), \(maxConcurrent) in flight)")
  let fdsBefore = ProcessTable.openFileDescriptors()

  struct StressOutcome: Sendable {
    var exited = false
    var zombie = false
    var spawnError: String?
    var observed: String?
  }

  @Sendable func runOne() async -> StressOutcome {
    do {
      let runtime = try await h.start(h.scriptSpec(.direct, script: "quick-exit.sh"))
      let exit = await runtime.waitForExit(timeout: .seconds(30))
      _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
      let zombie = ProcessTable.info(pid: runtime.pid)?.isZombie == true
      await h.finish(runtime)
      return StressOutcome(
        exited: exit == .exited(code: 0), zombie: zombie, spawnError: nil,
        observed: exit.map { "\($0)" } ?? "timeout")
    } catch {
      return StressOutcome(exited: false, zombie: false, spawnError: "\(error)")
    }
  }

  // Bounded concurrency: keep at most maxConcurrent PTYs live at once so the
  // test stresses spawn/reap churn, not the pty allocator (~511 cap).
  let outcomes = await withTaskGroup(of: StressOutcome.self) { group in
    var launched = 0
    for _ in 0..<min(maxConcurrent, total) {
      group.addTask { await runOne() }
      launched += 1
    }
    var acc: [StressOutcome] = []
    while let outcome = await group.next() {
      acc.append(outcome)
      if launched < total {
        group.addTask { await runOne() }
        launched += 1
      }
    }
    return acc
  }

  let exited = outcomes.filter { $0.exited }.count
  let zombies = outcomes.filter { $0.zombie }.count
  let spawnFails = outcomes.compactMap { $0.spawnError }
  check.p0("all \(total) churned jobs exited(0)", exited == total, detail: "\(exited)/\(total)")
  check.p0("no zombies left by any reap", zombies == 0, detail: "\(zombies) zombies")
  if exited != total {
    if let firstErr = spawnFails.first {
      check.note("\(spawnFails.count) spawn failures; first: \(firstErr)")
    }
    let observed = Set(outcomes.filter { $0.spawnError == nil }.compactMap { $0.observed })
    if !observed.isEmpty { check.note("non-failing exit observations: \(observed.sorted())") }
  }
  // Allow the closes to settle; fd reclamation is async in the cancel handler.
  _ = await eventually(.seconds(3)) { ProcessTable.openFileDescriptors().count <= fdsBefore.count }
  let fdsAfter = ProcessTable.openFileDescriptors()
  check.p0(
    "fd census returned to baseline", fdsAfter.count <= fdsBefore.count,
    detail: "\(fdsBefore.count) → \(fdsAfter.count) fds")
  check.note("reaps serialise on one shared queue (runstuff.reap); no thread-per-job")
  return check.report
}
