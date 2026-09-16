import Darwin
import Foundation
import RunStuffCore

func cttyProbeScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("ctty-probe.sh")
  for mode in [ShellMode.direct, .login] {
    let tag = mode.rawValue
    do {
      let runtime = try await h.start(h.scriptSpec(mode, script: "ctty-probe.sh"))
      let recorder = Recorder(await runtime.attach())
      let done = await recorder.waitFor("PROBE-DONE", timeout: .seconds(15))
      guard done != nil else {
        check.p0("\(tag): probe completed", false, detail: "no PROBE-DONE within 15 s")
        await h.finish(runtime)
        continue
      }
      // The script sleeps after reporting, so the process table still shows it.
      let info = ProcessTable.info(pid: runtime.pid)
      let ctty = await recorder.value(after: "CTTY=")
      let ttyRdev = await recorder.value(after: "TTY_RDEV=")
      let fd0Rdev = await recorder.value(after: "FD0_RDEV=")
      let tpgid = await recorder.value(after: "TPGID=")
      let pgid = await recorder.value(after: "PGID=")
      let reportedPID = await recorder.value(after: "PID=")

      let hasCtty = ctty == "yes"
      check.p0(
        "\(tag): child can open /dev/tty O_RDWR (has a controlling terminal)", hasCtty,
        detail: hasCtty
          ? "CTTY=yes"
          : "CTTY=no under posix_spawn + POSIX_SPAWN_SETSID; fallback: tty helper that does TIOCSCTTY before exec"
      )
      // The child's stdio is on our slave: fd 0's rdev equals the slave.
      // /dev/tty always stats as the alias device (major 2) on macOS, so
      // it is reported, not compared.
      check.p0(
        "\(tag): child's fd 0 is our slave (script rdev)", fd0Rdev == "\(runtime.slaveDevice)",
        detail: "FD0_RDEV=\(fd0Rdev ?? "?") slave=\(runtime.slaveDevice)")
      if let ttyRdev {
        check.note(
          "\(tag): /dev/tty stats as \(ttyRdev) (the /dev/tty alias device, major 2); the real terminal is the slave"
        )
      }
      check.p0(
        "\(tag): tty foreground pgrp == job pgid (script)", tpgid == "\(runtime.pgid)",
        detail: "TPGID=\(tpgid ?? "?") job pgid=\(runtime.pgid)")
      check.p0(
        "\(tag): script pgid == job pgid", pgid == "\(runtime.pgid)", detail: "PGID=\(pgid ?? "?")")
      check.p0(
        "\(tag): sysctl e_tdev == slave device", info?.ttyDevice == runtime.slaveDevice,
        detail: "e_tdev=\(info?.ttyDevice ?? 0) slave=\(runtime.slaveDevice)")
      check.p0(
        "\(tag): sysctl e_tpgid == job pgid", info?.ttyForegroundGroup == runtime.pgid,
        detail: "e_tpgid=\(info?.ttyForegroundGroup ?? -2)")
      if let reportedPID, reportedPID != "\(runtime.pid)" {
        check.note(
          "\(tag): script ran as pid \(reportedPID), not the job pid \(runtime.pid): the shell did not exec it"
        )
      }
      _ = await runtime.waitForExit(timeout: .seconds(10))
      _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
      await h.finish(runtime)
    } catch {
      check.p0("\(tag): spawn", false, detail: "\(error)")
    }
  }
  return check.report
}

func ctrlCScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("ctrl-c.sh")
  do {
    let runtime = try await h.start(h.scriptSpec(.direct, script: "ctrl-c.sh"))
    let recorder = Recorder(await runtime.attach())
    let ready = await recorder.waitFor("READY", timeout: .seconds(5))
    check.p0("fixture ready", ready != nil)
    let info = ProcessTable.info(pid: runtime.pid)
    if info?.ttyDevice != runtime.slaveDevice {
      check.skipped(
        "0x03 on the master kills the child by SIGINT",
        reason:
          "blocked by ctty-probe: the child has no controlling terminal, so the tty cannot signal it"
      )
      _ = await runtime.stop(grace: .seconds(1))
      await h.finish(runtime)
      return check.report
    }
    try await runtime.write([0x03])
    let exit = await runtime.waitForExit(timeout: .seconds(2))
    let ok = exit == .signalled(signal: SIGINT, coreDumped: false) || exit == .exited(code: 130)
    check.p0(
      "0x03 on the master kills the child by SIGINT", ok,
      detail: "\(exit.map { "\($0)" } ?? "still running after 2 s")")
    if exit == nil { _ = await runtime.stop(grace: .seconds(1)) }
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("spawn/write", false, detail: "\(error)")
  }

  let build = h.compileCFixture("ctrl-c-raw")
  guard let binary = build.path else {
    check.p0("compile ctrl-c-raw.c with cc", false, detail: build.detail)
    return check.report
  }
  do {
    let runtime = try await h.start(h.spec(.direct, command: [binary]))
    let recorder = Recorder(await runtime.attach())
    let ready = await recorder.waitFor("READY", timeout: .seconds(5))
    check.p0("raw binary ready", ready != nil)
    try await runtime.write([0x03])
    let exit = await runtime.waitForExit(timeout: .seconds(2))
    check.p0(
      "0x03 kills a raw binary by SIGINT",
      exit == .signalled(signal: SIGINT, coreDumped: false),
      detail: "\(exit.map { "\($0)" } ?? "still running after 2 s")")
    if exit == nil { _ = await runtime.stop(grace: .seconds(1)) }
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("raw binary spawn/write", false, detail: "\(error)")
  }
  return check.report
}

func bindsPortScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("binds-port.sh")
  guard let port = ProcessTable.freeLoopbackPort() else {
    check.p0("pick a free loopback port", false, detail: "bind :0 failed")
    return check.report
  }
  do {
    let runtime = try await h.start(
      h.scriptSpec(.login, script: "binds-port.sh", arguments: ["\(port)"]))
    let recorder = Recorder(await runtime.attach())
    let announced = await recorder.waitFor("PORT \(port)", timeout: .seconds(15))
    check.p0("fixture announced port \(port)", announced != nil)
    let listening = await eventually(.seconds(3)) {
      ProcessTable.connectLoopback(port: port) == .connected
    }
    check.p0("connect() succeeds while the job runs", listening)
    // nc -k needs a moment to accept again after the first connection closes.
    var last = ProcessTable.ConnectResult.refused
    let stillListening = await eventually(.seconds(2)) {
      last = ProcessTable.connectLoopback(port: port)
      return last == .connected
    }
    check.p0("listener survives a connection (nc -k)", stillListening, detail: "\(last)")
    let detected = ProcessTable.listeningPorts(pgid: runtime.pgid)
    check.p2(
      "listening port detected via proc_pidfdinfo",
      detected.contains(port),
      detail: "detected \(detected)",
      ref: "plan §1 port detection")
    let report = await runtime.stop(grace: .seconds(2))
    let refused = await eventually(.seconds(1)) {
      ProcessTable.connectLoopback(port: port) == .refused
    }
    check.p0("port refused within 1 s of stop()", refused)
    check.p0(
      "session empty after stop()", report.remaining.isEmpty,
      detail: report.remaining.isEmpty
        ? "cleared in \(report.sessionClearedAfter.map(formatSeconds) ?? "?")"
        : "survivors \(report.remaining)")
    check.note(
      "leader ended \(report.leaderExit.map { "\($0)" } ?? "?")\(report.escalatedToKill ? ", escalated to SIGKILL" : "")"
    )
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("spawn", false, detail: "\(error)")
  }
  return check.report
}

func spawnsChildrenScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("spawns-children.sh")
  do {
    let runtime = try await h.start(h.scriptSpec(.login, script: "spawns-children.sh"))
    let recorder = Recorder(await runtime.attach())
    let ready = await recorder.waitFor("CHILDREN-READY", timeout: .seconds(15))
    check.p0("children started", ready != nil)
    let children = await recorder.values(after: "CHILD ").compactMap { pid_t($0) }
    check.p0(
      "three descendants plus the subshell reported", children.count == 4, detail: "\(children)")
    let scriptPgid = await recorder.value(after: "PGID ")
    check.p0(
      "script pgid == job pgid", scriptPgid == "\(runtime.pgid)",
      detail: "PGID=\(scriptPgid ?? "?") job=\(runtime.pgid)")
    let groups = children.map { ProcessTable.info(pid: $0)?.pgid }
    check.p0(
      "every descendant shares the job pgid", groups.allSatisfy { $0 == runtime.pgid },
      detail: "\(groups.map { $0.map(String.init) ?? "gone" })")

    let usage = MetricsSampler.readProcessGroup(runtime.pgid)
    check.p1(
      "metrics sum across the whole group",
      usage.processCount >= children.count + 1 && usage.residentBytes > 0,
      detail:
        "sampled \(usage.processCount) processes, \(formatBytes(usage.residentBytes)) resident",
      ref: "plan §1 metrics")

    // Non-negotiable 2 fast path on its own: one group kill.
    let outcome = await runtime.signalGroup(SIGTERM)
    check.p0("kill(-pgid, SIGTERM) delivered", outcome == .delivered, detail: "\(outcome)")
    let exit = await runtime.waitForExit(timeout: .seconds(3))
    check.p0(
      "leader ended by SIGTERM", exit == .signalled(signal: SIGTERM, coreDumped: false),
      detail: "\(exit.map { "\($0)" } ?? "no exit")")
    let allGone = await eventually(.seconds(2)) {
      children.allSatisfy {
        !ProcessTable.exists(pid: $0) || ProcessTable.info(pid: $0)?.isZombie == true
      }
    }
    check.p0(
      "all descendants dead within 2 s of the group kill", allGone,
      detail: "\(children.filter { ProcessTable.exists(pid: $0) })")
    let groupEmpty = await eventually(.seconds(2)) {
      ProcessTable.groupMembers(pgid: runtime.pgid).isEmpty
    }
    check.p0(
      "process group swept clean", groupEmpty,
      detail: "\(ProcessTable.groupMembers(pgid: runtime.pgid))")
    let sessionEmpty = await eventually(.seconds(2)) {
      ProcessTable.sessionMembers(sid: runtime.sid).isEmpty
    }
    check.p0(
      "session swept clean", sessionEmpty,
      detail: "\(ProcessTable.sessionMembers(sid: runtime.sid))")
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("spawn", false, detail: "\(error)")
  }
  return check.report
}

func jobControlScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("job-control.sh")
  do {
    let runtime = try await h.start(
      h.spec(.interactiveLogin, commandLine: "\(h.fixture("job-control.sh")) && true"))
    let recorder = Recorder(await runtime.attach())
    let ready = await recorder.waitFor("CHILDREN-READY", timeout: .seconds(20))
    check.p0("children started under an interactive login shell", ready != nil)
    let children = await recorder.values(after: "CHILD ").compactMap { pid_t($0) }
    let selfPid = await recorder.value(after: "SELF ").flatMap { pid_t($0) }
    let scriptPgid = await recorder.value(after: "PGID ").flatMap { pid_t($0) }
    let tracked = children + (selfPid.map { [$0] } ?? [])
    check.p0(
      "descendants reported", children.count == 3 && selfPid != nil,
      detail: "children \(children), script pid \(selfPid.map(String.init) ?? "?")")
    if let scriptPgid {
      if scriptPgid == runtime.pgid {
        check.note(
          "job control did not move the script out of the job pgid (shell pgid == script pgid \(scriptPgid)); the session path is exercised but not needed this run"
        )
      } else {
        check.note(
          "job control placed the script in pgid \(scriptPgid), outside the job pgid \(runtime.pgid): kill(-pgid) alone would miss it"
        )
      }
    }
    let report = await runtime.stop(grace: .seconds(2))
    let allGone = await eventually(.seconds(2)) {
      tracked.allSatisfy {
        !ProcessTable.exists(pid: $0) || ProcessTable.info(pid: $0)?.isZombie == true
      }
    }
    check.p0(
      "one stop() removed every descendant", allGone,
      detail:
        "survivors \(tracked.filter { ProcessTable.exists(pid: $0) && ProcessTable.info(pid: $0)?.isZombie != true })"
    )
    check.p0(
      "session empty after stop()", report.remaining.isEmpty,
      detail: report.remaining.isEmpty
        ? "cleared in \(report.sessionClearedAfter.map(formatSeconds) ?? "?")"
        : "survivors \(report.remaining)")
    check.p0(
      "leader reaped", report.leaderExit != nil,
      detail: "\(report.leaderExit.map { "\($0)" } ?? "none")")
    check.note(
      "session members outside the job pgid at SIGTERM: \(report.outsideGroupAtTerm)\(report.escalatedToKill ? "; escalated to SIGKILL (interactive shells ignore SIGTERM)" : "")"
    )
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("spawn", false, detail: "\(error)")
  }
  return check.report
}

func ignoresSigtermScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("ignores-sigterm.sh")
  do {
    let runtime = try await h.start(h.scriptSpec(.login, script: "ignores-sigterm.sh"))
    let recorder = Recorder(await runtime.attach())
    let ready = await recorder.waitFor("READY", timeout: .seconds(15))
    check.p0("fixture ready", ready != nil)
    let grace = Duration.seconds(2)
    let stopStart = ContinuousClock.now
    let stopTask = Task { await runtime.stop(grace: grace) }
    try? await Task.sleep(for: .milliseconds(1800))
    let aliveInfo = ProcessTable.info(pid: runtime.pid)
    check.p0("still alive 1.8 s after SIGTERM", aliveInfo != nil && aliveInfo?.isZombie == false)
    let report = await stopTask.value
    let total = ContinuousClock.now - stopStart
    check.p0("escalated to SIGKILL after the grace period", report.escalatedToKill)
    check.p0(
      "leader ended by SIGKILL",
      report.leaderExit == .signalled(signal: SIGKILL, coreDumped: false),
      detail: "\(report.leaderExit.map { "\($0)" } ?? "none")")
    check.p0(
      "session swept clean within grace + 1.5 s",
      report.remaining.isEmpty && total < grace + .milliseconds(1500),
      detail: "stop() took \(formatSeconds(total)); survivors \(report.remaining)")
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
    await h.finish(runtime)
  } catch {
    check.p0("spawn", false, detail: "\(error)")
  }
  return check.report
}

/// Tolerances for the firehose.
enum FirehoseTolerance {
  static let expectedXBytes: UInt64 = 30 * 10 * 1_048_576
  static let noAttachWindow = Duration.seconds(5)
  /// Consecutive TICK lines must be at least this far apart on arrival: the
  /// child sleeps 1 s between bursts, so a burst of ticks at attach time
  /// means the drain was gated. This is the sensitive check.
  static let minTickGap = 0.8
  static let firstTickWithin = 1.5
  /// Observed 2026-09-11 on an M-series Mac: PTY wall 38.7 s vs /dev/null
  /// baseline 39.3 s (0.98x). The fixture is sleep-paced, so wall time only
  /// catches gross stalls; 1.5x leaves room for a loaded machine.
  static let maxWallFactor: Double? = 1.5
}

func firehoseScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("firehose.sh")
  let baseline = h.runOutsidePTY(["/bin/sh", "-c", "'\(h.fixture("firehose.sh"))' > /dev/null"])
  check.note(
    "baseline (same pipeline into /dev/null, no PTY): \(formatSeconds(.milliseconds(Int(baseline.seconds * 1000)))), exit \(baseline.code)"
  )

  do {
    let runtime = try await h.start(h.scriptSpec(.direct, script: "firehose.sh"))
    // Attach nothing. The runtime must drain on its own.
    try? await Task.sleep(for: FirehoseTolerance.noAttachWindow)
    let spooledBeforeAttach = await runtime.spooledLength()
    let recordsBeforeAttach = await runtime.chunkRecords().count
    check.p0(
      "drained while nothing was attached for 5 s", spooledBeforeAttach >= 10 * 1_048_576,
      detail:
        "\(formatBytes(spooledBeforeAttach)) bytes in \(recordsBeforeAttach) reads before attach")

    var scanner = LineScanner(countedByte: UInt8(ascii: "x"), prefixes: ["TICK ", "FIREHOSE-DONE"])
    var ring = OutputBuffer(maximumLines: 5, maximumBytes: 64 * 1024)
    for await chunk in await runtime.attach() {
      scanner.consume(chunk)
      ring.append(chunk.bytes)
    }
    let exit = await runtime.waitForExit(timeout: .seconds(30))
    let wall = await runtime.exitedAt.map { elapsedSeconds(runtime.spawnedAt, $0) } ?? .infinity
    _ = await runtime.waitForDrainEnd(timeout: .seconds(5))

    check.p0("exited(0)", exit == .exited(code: 0), detail: "\(exit.map { "\($0)" } ?? "no exit")")
    check.p0(
      "every payload byte present from t=0", scanner.counted == FirehoseTolerance.expectedXBytes,
      detail:
        "\(formatBytes(scanner.counted)) of \(formatBytes(FirehoseTolerance.expectedXBytes)) x bytes"
    )
    let spooled = await runtime.spooledLength()
    check.p0(
      "late consumer received the whole stream", scanner.totalBytes == spooled,
      detail: "\(formatBytes(scanner.totalBytes)) consumed, \(formatBytes(spooled)) spooled")
    check.p0("sentinel seen", scanner.matches.contains { $0.line.hasPrefix("FIREHOSE-DONE") })

    // Arrival cadence of the TICK lines, from the spool's read records.
    let records = await runtime.chunkRecords()
    func arrival(of offset: UInt64) -> ContinuousClock.Instant? {
      records.first { $0.offset <= offset && offset < $0.offset + UInt64($0.count) }?.at
    }
    let ticks = scanner.matches.filter { $0.line.hasPrefix("TICK ") }.compactMap { m in
      arrival(of: m.offset).map { (m.line, $0) }
    }
    check.p0("30 TICK lines observed", ticks.count == 30, detail: "\(ticks.count)")
    if let first = ticks.first {
      let firstAt = elapsedSeconds(runtime.spawnedAt, first.1)
      check.p0(
        "first TICK arrived within \(FirehoseTolerance.firstTickWithin) s of spawn",
        firstAt <= FirehoseTolerance.firstTickWithin,
        detail: "\(formatSeconds(.milliseconds(Int(firstAt * 1000))))")
    }
    var minGap = Double.infinity
    for i in 1..<max(ticks.count, 1) {
      minGap = min(minGap, (ticks[i].1 - ticks[i - 1].1).seconds)
    }
    check.p0(
      "TICKs arrived on the child's cadence (child never blocked)",
      ticks.count == 30 && minGap >= FirehoseTolerance.minTickGap,
      detail:
        "smallest gap between consecutive TICK arrivals \(formatSeconds(.milliseconds(Int(minGap.isFinite ? minGap * 1000 : 0))))"
    )
    let ticksBeforeAttach = ticks.filter {
      elapsedSeconds(runtime.spawnedAt, $0.1) < FirehoseTolerance.noAttachWindow.seconds
    }.count
    check.note("\(ticksBeforeAttach) TICKs arrived during the 5 s with nothing attached")

    if baseline.seconds > 0 {
      let factor = wall / baseline.seconds
      check.note(
        "PTY wall time \(formatSeconds(.milliseconds(Int(wall * 1000)))) = \(String(Int(factor * 100)))% of the /dev/null baseline"
      )
      if let limit = FirehoseTolerance.maxWallFactor {
        check.p0("wall time within \(limit)x of baseline", factor <= limit, detail: "\(factor)")
      } else {
        check.note(
          "wall-time threshold unset; set FirehoseTolerance.maxWallFactor from this observation")
      }
    }
    check.p1(
      "ring evicts correctly under sustained output",
      ring.lines.count == 5 && ring.byteCount <= ring.maximumBytes
        && (ring.lines.first?.sequence ?? 0) > 0,
      detail:
        "\(ring.lines.count) lines, \(formatBytes(UInt64(ring.byteCount))) bytes, first sequence \(ring.lines.first?.sequence ?? 0)",
      ref: "plan §1 output buffer")
    await h.finish(runtime)
  } catch {
    check.p0("spawn", false, detail: "\(error)")
  }
  return check.report
}
