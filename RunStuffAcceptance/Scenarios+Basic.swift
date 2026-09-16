import Darwin
import Foundation
import RunStuffCore
import SwiftTerm

/// Expected bytes for a fixture that prints plain lines: the tty's ONLCR
/// turns each `\n` into `\r\n`.
func crlf(_ lines: [String]) -> [UInt8] {
  Array(lines.map { $0 + "\r\n" }.joined().utf8)
}

func exitCleanScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("exit-clean.sh")
  var expectedLines = (1...200).map { "line \($0)" }
  expectedLines.append("DONE")
  let expected = crlf(expectedLines)

  // Direct mode: byte-exact.
  do {
    let runtime = try await h.start(h.scriptSpec(.direct, script: "exit-clean.sh"))
    let recorder = Recorder(await runtime.attach())
    let exit = await runtime.waitForExit(timeout: .seconds(10))
    let drain = await runtime.waitForDrainEnd(timeout: .seconds(5))
    _ = await recorder.waitForFinish(timeout: .seconds(2))
    check.p0(
      "direct: exited(0)", exit == .exited(code: 0), detail: "\(exit.map { "\($0)" } ?? "no exit")")
    let got = await recorder.bytes
    check.p0(
      "direct: output byte-exact with CRLF", got == expected,
      detail: got == expected
        ? "\(formatBytes(UInt64(got.count))) bytes" : firstDifference(expected, got))
    check.p0(
      "direct: drain ended with EOF", drain == .eof || drain == .eio,
      detail: "\(drain.map { "\($0)" } ?? "none")")
    if drain == .eio { check.note("read() reported EIO rather than 0 at EOF") }
    let spins = await runtime.handlerCallsAfterDrainEnd
    check.p0(
      "direct: no read-source spin after EOF", spins == 0, detail: "\(spins) extra handler calls")
    if let exitAt = await runtime.exitedAt, let drainAt = await runtime.drainEndedAt {
      check.note(
        "exit observed \(exitAt <= drainAt ? "before" : "after") EOF (\(formatSeconds(exitAt > drainAt ? exitAt - drainAt : drainAt - exitAt)) apart)"
      )
    }
    await h.finish(runtime)
  } catch {
    check.p0("direct: spawn", false, detail: "\(error)")
  }

  // Login mode: exit 0 and the fixture's text at the end; startup files may
  // print before it.
  do {
    let runtime = try await h.start(h.scriptSpec(.login, script: "exit-clean.sh"))
    let recorder = Recorder(await runtime.attach())
    let exit = await runtime.waitForExit(timeout: .seconds(15))
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    _ = await recorder.waitForFinish(timeout: .seconds(2))
    check.p0(
      "login: exited(0)", exit == .exited(code: 0), detail: "\(exit.map { "\($0)" } ?? "no exit")")
    let got = await recorder.bytes
    check.p0(
      "login: output ends with the fixture's text",
      got.count >= expected.count && Array(got.suffix(expected.count)) == expected,
      detail: "\(formatBytes(UInt64(got.count))) bytes received")
    if got.count > expected.count {
      check.note(
        "login shell startup printed \(got.count - expected.count) bytes before the fixture")
    }
    await h.finish(runtime)
  } catch {
    check.p0("login: spawn", false, detail: "\(error)")
  }
  return check.report
}

func firstDifference(_ expected: [UInt8], _ got: [UInt8]) -> String {
  let n = min(expected.count, got.count)
  var i = 0
  while i < n && expected[i] == got[i] { i += 1 }
  if i == n && expected.count == got.count { return "identical" }
  let e = expected.count > i ? String(format: "0x%02x", expected[i]) : "end"
  let g = got.count > i ? String(format: "0x%02x", got[i]) : "end"
  return "differs at byte \(i): expected \(e), got \(g); lengths \(expected.count) vs \(got.count)"
}

func exitFailScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("exit-fail.sh")
  for mode in [ShellMode.direct, .login] {
    do {
      let runtime = try await h.start(h.scriptSpec(mode, script: "exit-fail.sh"))
      let exit = await runtime.waitForExit(timeout: .seconds(15))
      _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
      check.p0(
        "\(mode.rawValue): exited(1), not a signal", exit == .exited(code: 1),
        detail: "\(exit.map { "\($0)" } ?? "no exit")")
      await h.finish(runtime)
    } catch {
      check.p0("\(mode.rawValue): spawn", false, detail: "\(error)")
    }
  }
  return check.report
}

func notFoundScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("not-found.sh")
  for mode in [ShellMode.login, .interactiveLogin] {
    do {
      let runtime = try await h.start(h.scriptSpec(mode, script: "not-found.sh"))
      let exit = await runtime.waitForExit(timeout: .seconds(15))
      let elapsed =
        await runtime.exitedAt.map { elapsedSeconds(runtime.spawnedAt, $0) } ?? .infinity
      _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
      check.p0(
        "\(mode.flagDescription): exited(127)", exit == .exited(code: 127),
        detail: "\(exit.map { "\($0)" } ?? "no exit")")
      check.p0(
        "\(mode.flagDescription): exit within 2 s", elapsed < 2,
        detail: "\(formatSeconds(.milliseconds(Int(elapsed * 1000))))")
      await h.finish(runtime)
    } catch {
      check.p0("\(mode.flagDescription): spawn", false, detail: "\(error)")
    }
  }
  do {
    let job = Job(
      name: "not found",
      command: h.fixture("not-found.sh"),
      workingDirectory: URL(fileURLWithPath: h.repoRoot),
      shellMode: .login,
      colorSeed: 1)
    let context = try h.supervisor(for: job)
    try await context.supervisor.start(jobID: job.id)
    let snapshot = await h.waitForCompletion(
      context.supervisor, jobID: job.id, timeout: .seconds(5))
    check.p1(
      "exit 127 surfaced as shell-mode hint copy",
      snapshot?.state == .failedToStart(RunStuffMessage.commandNotFound),
      detail: "\(snapshot?.state ?? .idle)",
      ref: "plan §1 PATH problem")
    try? FileManager.default.removeItem(at: context.directory)
  } catch {
    check.p1(
      "exit 127 surfaced as shell-mode hint copy", false,
      detail: "\(error)", ref: "plan §1 PATH problem")
  }

  // Direct mode: the command name does not resolve on the job's PATH.
  let fdsBefore = ProcessTable.openFileDescriptors()
  do {
    let runtime = try await h.start(h.spec(.direct, command: ["definitely-not-a-command-4f2a"]))
    check.p0(
      "direct: spawn fails with ENOENT, no child", false,
      detail: "spawned pid \(runtime.pid) instead")
    _ = await runtime.stop(grace: .seconds(1))
    await h.finish(runtime)
  } catch let error as SpawnError {
    check.p0(
      "direct: spawn fails with ENOENT, no child", error.errnoValue == ENOENT, detail: "\(error)")
  } catch {
    check.p0("direct: spawn fails with ENOENT, no child", false, detail: "\(error)")
  }
  let fdsAfter = ProcessTable.openFileDescriptors()
  check.p0(
    "direct: no fd leaked by the failed spawn", fdsBefore == fdsAfter,
    detail: "\(fdsBefore.count) → \(fdsAfter.count) fds")
  return check.report
}

func crashDelayedScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("crash-delayed.sh")
  for mode in [ShellMode.direct, .login] {
    do {
      let runtime = try await h.start(h.scriptSpec(mode, script: "crash-delayed.sh"))
      let exit = await runtime.waitForExit(timeout: .seconds(20))
      let elapsed = await runtime.exitedAt.map { elapsedSeconds(runtime.spawnedAt, $0) } ?? 0
      _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
      let isSegv =
        exit == .signalled(signal: SIGSEGV, coreDumped: false)
        || exit == .signalled(signal: SIGSEGV, coreDumped: true)
      check.p0(
        "\(mode.rawValue): signalled(SIGSEGV), not exited(139)", isSegv,
        detail: "\(exit.map { "\($0)" } ?? "no exit")")
      check.p0(
        "\(mode.rawValue): after at least 5 s", elapsed >= 5,
        detail: formatSeconds(.milliseconds(Int(elapsed * 1000))))
      if exit == .exited(code: 139) {
        check.note(
          "\(mode.rawValue): the shell did not exec the command, so the signal became exit 139 (plan §2 rank 2 caveat)"
        )
      }
      await h.finish(runtime)
    } catch {
      check.p0("\(mode.rawValue): spawn", false, detail: "\(error)")
    }
  }
  return check.report
}

func crashLoopScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("crash-loop.sh")
  let fdsBefore = ProcessTable.openFileDescriptors()
  var pids: [pid_t] = []
  var detected = 0
  var reaped = 0
  let rounds = 20
  for _ in 0..<rounds {
    do {
      let runtime = try await h.start(h.scriptSpec(.direct, script: "crash-loop.sh"))
      pids.append(runtime.pid)
      let exit = await runtime.waitForExit(timeout: .seconds(10))
      if exit == .exited(code: 1) { detected += 1 }
      _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
      await h.finish(runtime)
      if let info = ProcessTable.info(pid: runtime.pid), info.isZombie {
        // Left a zombie: not reaped.
      } else {
        reaped += 1
      }
    } catch {
      check.p0("spawn round \(pids.count + 1)", false, detail: "\(error)")
      break
    }
  }
  check.p0(
    "\(rounds) crashes each detected as exited(1)", detected == rounds,
    detail: "\(detected)/\(rounds)")
  check.p0("every pid reaped (no zombies)", reaped == rounds, detail: "\(reaped)/\(rounds)")
  let fdsAfter = ProcessTable.openFileDescriptors()
  check.p0(
    "fd census unchanged", fdsBefore == fdsAfter,
    detail: "\(fdsBefore.count) → \(fdsAfter.count) fds")
  do {
    let job = Job(
      name: "crash loop",
      command: "/bin/sh \(h.fixture("crash-loop.sh"))",
      workingDirectory: URL(fileURLWithPath: h.repoRoot),
      shellMode: .direct,
      restartOnCrash: true,
      maxRestarts: 3,
      colorSeed: 1)
    let context = try h.supervisor(for: job)
    let started = ContinuousClock.now
    try await context.supervisor.start(jobID: job.id)
    var snapshot: JobSnapshot?
    let deadline = started.advanced(by: .seconds(12))
    while ContinuousClock.now < deadline {
      let current = await context.supervisor.snapshot(jobID: job.id)
      if case .error(let reason, _)? = current?.health, reason.hasPrefix("Restart loop:") {
        snapshot = current
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }
    let elapsed = ContinuousClock.now - started
    check.p1(
      "exponential backoff between restarts",
      snapshot != nil && elapsed >= .seconds(7),
      detail: "gave up after \(formatSeconds(elapsed))",
      ref: "plan §5")
    check.p1(
      "gives up after maxRestarts within 60 s",
      snapshot != nil && elapsed < .seconds(60),
      detail: "\(snapshot?.health ?? .ok)",
      ref: "plan §5")
    try? FileManager.default.removeItem(at: context.directory)
  } catch {
    check.p1("exponential backoff between restarts", false, detail: "\(error)", ref: "plan §5")
    check.p1("gives up after maxRestarts within 60 s", false, detail: "\(error)", ref: "plan §5")
  }
  return check.report
}

func promptWaitScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("prompt-wait.sh")
  do {
    let runtime = try await h.start(h.scriptSpec(.direct, script: "prompt-wait.sh"))
    let recorder = Recorder(await runtime.attach())
    let promptEnd = await recorder.waitFor("Continue? [y/N] ", timeout: .seconds(5))
    check.p0("prompt bytes observed", promptEnd != nil)
    if let promptEnd {
      try await runtime.write(Array("y\n".utf8))
      let gotEnd = await recorder.waitFor("GOT:y", from: promptEnd, timeout: .seconds(5))
      check.p0("response to typed input observed", gotEnd != nil)
      let echoed = await recorder.find(Array("y\r\n".utf8), from: promptEnd)
      check.p0(
        "tty echoed the typed input before the response",
        echoed != nil && (gotEnd == nil || echoed! < gotEnd!))
    }
    let exit = await runtime.waitForExit(timeout: .seconds(5))
    check.p0("exited(0)", exit == .exited(code: 0), detail: "\(exit.map { "\($0)" } ?? "no exit")")
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("spawn/write", false, detail: "\(error)")
  }
  return check.report
}

func coloursScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("colours.sh")
  let esc = "\u{1b}"
  let expected = crlf([
    "\(esc)[31mred\(esc)[0m \(esc)[1;32mbold green\(esc)[0m",
    "\(esc)[38;5;208m256-colour orange\(esc)[0m",
    "\(esc)[38;2;255;105;180mtruecolor pink\(esc)[0m",
    "\(esc)[31msplit red\(esc)[0m",
    "TERM=xterm-256color",
    "COLOURS-DONE",
  ])
  do {
    let runtime = try await h.start(h.scriptSpec(.direct, script: "colours.sh"))
    let recorder = Recorder(await runtime.attach())
    let exit = await runtime.waitForExit(timeout: .seconds(10))
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    _ = await recorder.waitForFinish(timeout: .seconds(2))
    let got = await recorder.bytes
    check.p0("exited(0)", exit == .exited(code: 0), detail: "\(exit.map { "\($0)" } ?? "no exit")")
    check.p0(
      "raw bytes byte-exact, every ESC intact", got == expected,
      detail: got == expected ? "\(got.count) bytes" : firstDifference(expected, got))
    check.p0("TERM reached the child", await recorder.contains("TERM=xterm-256color"))
    // Did the split escape really cross a read boundary?
    let arrivals = await recorder.arrivals
    let splitAt = Array("\(esc)[31msplit".utf8)
    if let end = await recorder.find(splitAt),
      let boundary = arrivals.first(where: {
        Int($0.offset) > end - splitAt.count && Int($0.offset) < end
      })
    {
      check.note(
        "split CSI crossed a read boundary at stream offset \(boundary.offset); reassembled by concatenation"
      )
    } else {
      check.note(
        "the split CSI arrived in one read this run (child paused 100 ms; timing-dependent)")
    }
    let colourRendered = await MainActor.run {
      let view = TerminalView(
        frame: .zero,
        options: TerminalOptions(cols: 120, rows: 10, scrollback: 20))
      view.feed(byteArray: got[...])
      let terminal = view.getTerminal()
      return terminal.getLine(row: 0)?[0].attribute.fg == .ansi256(code: 1)
        && terminal.getLine(row: 0)?[4].attribute.fg == .ansi256(code: 2)
        && terminal.getLine(row: 1)?[0].attribute.fg == .ansi256(code: 208)
        && terminal.getLine(row: 2)?[0].attribute.fg
          == .trueColor(red: 255, green: 105, blue: 180)
        && terminal.getLine(row: 3)?[0].attribute.fg == .ansi256(code: 1)
    }
    check.p1(
      "SwiftTerm renders ANSI, 256-colour, truecolor, and split-CSI colour",
      colourRendered,
      ref: "plan §4 terminal window")
    var buffer = OutputBuffer()
    buffer.append(got)
    let stripped = buffer.lines.map(\.stripped).joined()
    check.p1(
      "ANSI-stripped copy matches the plain text",
      stripped
        == "red bold green\r\n256-colour orange\r\ntruecolor pink\r\nsplit red\r\nTERM=xterm-256color\r\nCOLOURS-DONE\r\n",
      detail: stripped,
      ref: "plan §1 output buffer")
    await h.finish(runtime)
  } catch {
    check.p0("spawn", false, detail: "\(error)")
  }
  return check.report
}

func progressBarScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("progress-bar.sh")
  do {
    let runtime = try await h.start(
      h.scriptSpec(.direct, script: "progress-bar.sh", windowSize: WindowSize(rows: 40, cols: 120)))
    let recorder = Recorder(await runtime.attach())
    let initial = await recorder.waitFor("SIZE 40 120", timeout: .seconds(5))
    check.p0("child saw the initial 40x120 window", initial != nil)
    try? await Task.sleep(for: .seconds(1))
    try await runtime.resize(WindowSize(rows: 24, cols: 60))
    let winch = await recorder.waitFor("WINCH", from: initial ?? 0, timeout: .seconds(5))
    check.p0("SIGWINCH reached the child", winch != nil)
    let resized = await recorder.waitFor("SIZE 24 60", from: winch ?? 0, timeout: .seconds(5))
    check.p0("child reports the new 24x60 window after TIOCSWINSZ", resized != nil)
    if let resized {
      let width = await recorder.waitFor("WIDTH-DONE", from: resized, timeout: .seconds(5))
      let hashLine = await recorder.lines().first { $0.hasPrefix("#") }
      check.p0(
        "post-resize line is exactly 60 columns wide", width != nil && hashLine?.count == 60,
        detail: "\(hashLine?.count ?? 0) columns")
      // COLUMNS is no longer set in the job environment, so ncurses reads
      // the ioctl and tput agrees with stty.
      let tputCols = await recorder.value(after: "TPUT_COLS=")
      check.p0(
        "tput cols agrees with the ioctl (60), COLUMNS not set", tputCols == "60",
        detail: "tput cols=\(tputCols ?? "?")")
    }
    let done = await recorder.waitFor("BAR-DONE", timeout: .seconds(15))
    check.p0("fixture completed", done != nil)
    let crs = await recorder.count(of: 0x0D)
    check.p0("carriage-return redraws captured (>= 30)", crs >= 30, detail: "\(crs) CR bytes")
    let exit = await runtime.waitForExit(timeout: .seconds(5))
    check.p0("exited(0)", exit == .exited(code: 0), detail: "\(exit.map { "\($0)" } ?? "no exit")")
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    let got = await recorder.bytes
    let finalProgress = await MainActor.run {
      let view = TerminalView(
        frame: .zero,
        options: TerminalOptions(cols: 60, rows: 24, scrollback: 100))
      view.feed(byteArray: got[...])
      let terminal = view.getTerminal()
      return (0..<terminal.getDims().rows).compactMap {
        terminal.getLine(row: $0)?.translateToString(trimRight: true)
      }.contains("[####################] 100%")
    }
    check.p1(
      "carriage-return redraw leaves the final progress state in SwiftTerm",
      finalProgress,
      ref: "plan §4 terminal window")
    await h.finish(runtime)
  } catch {
    check.p0("spawn/resize", false, detail: "\(error)")
  }
  return check.report
}
