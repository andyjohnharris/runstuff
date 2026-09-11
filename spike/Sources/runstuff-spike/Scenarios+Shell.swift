import Darwin
import Foundation
import RunStuffCore

private struct NodeReport {
  var version: String?
  var execPath: String?
  var path: String?
}

private func parseNodeReport(_ recorder: Recorder) async -> NodeReport {
  var report = NodeReport()
  if let node = await recorder.value(after: "NODE ") {
    let parts = node.split(separator: " ", maxSplits: 1).map(String.init)
    report.version = parts.first
    report.execPath = parts.count > 1 ? parts[1] : nil
  }
  report.path = await recorder.value(after: "PATH=")
  return report
}

func nvmProjectScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("nvm-project/")
  let home = SpawnEnvironment.launchdLikeBase()["HOME"] ?? ""
  let projectDir = h.fixture("nvm-project")
  if case .unmet(let reason) = Precondition.nvm(home: home) {
    check.skipped("nvm-managed node runs only under -l -i", reason: "precondition: \(reason)")
    return check.report
  }
  let nvmRoot = "\(home)/.nvm/"

  for mode in [ShellMode.interactiveLogin, .login] {
    let tag = mode.flagDescription
    do {
      let runtime = try await h.start(
        h.spec(mode, command: ["npm", "run", "dev"], cwd: projectDir))
      let recorder = Recorder(await runtime.attach())
      let exit = await runtime.waitForExit(timeout: .seconds(30))
      _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
      _ = await recorder.waitForFinish(timeout: .seconds(2))
      let report = await parseNodeReport(recorder)
      check.note(
        "\(tag): exit \(exit.map { "\($0)" } ?? "none"); node \(report.version ?? "-") at \(report.execPath ?? "-")"
      )
      check.note("\(tag): PATH=\(report.path ?? "(not reported)")")
      switch mode {
      case .interactiveLogin:
        check.p0("\(tag): exited(0)", exit == .exited(code: 0))
        check.p0(
          "\(tag): execPath is under ~/.nvm", report.execPath?.hasPrefix(nvmRoot) == true,
          detail: report.execPath ?? "no NODE line")
        check.p0(
          "\(tag): version matches .nvmrc major (24)", report.version?.hasPrefix("v24") == true,
          detail: report.version ?? "-")
      case .login:
        // Whatever resolves instead (mise's shim, nothing, a failing
        // shim) is the finding; only nvm's node is wrong here.
        let notNvm = report.execPath.map { !$0.hasPrefix(nvmRoot) } ?? true
        check.p0(
          "\(tag): nvm's node does NOT run", notNvm,
          detail: report.execPath ?? "no node ran; \(exit.map { "\($0)" } ?? "?")")
        if report.execPath == nil {
          let tail = await recorder.lines().suffix(3).joined(separator: " | ")
          check.note("\(tag): output tail: \(tail)")
        }
      case .direct:
        break
      }
      await h.finish(runtime)
    } catch {
      check.p0("\(tag): spawn", false, detail: "\(error)")
    }
  }

  do {
    let runtime = try await h.start(
      h.spec(.direct, command: ["npm", "run", "dev"], cwd: projectDir))
    check.p0(
      "direct: spawn fails with ENOENT on the scrubbed PATH", false,
      detail: "spawned pid \(runtime.pid) instead")
    _ = await runtime.stop(grace: .seconds(1))
    await h.finish(runtime)
  } catch let error as SpawnError {
    check.p0(
      "direct: spawn fails with ENOENT on the scrubbed PATH", error.errnoValue == ENOENT,
      detail: "\(error)")
  } catch {
    check.p0("direct: spawn fails with ENOENT on the scrubbed PATH", false, detail: "\(error)")
  }
  do {
    let job = Job(
      name: "nvm direct",
      command: "npm run dev",
      workingDirectory: URL(fileURLWithPath: projectDir),
      shellMode: .direct,
      colorSeed: 1)
    let context = try h.supervisor(for: job)
    try await context.supervisor.start(jobID: job.id)
    let snapshot = await context.supervisor.snapshot(jobID: job.id)
    check.p1(
      "failed start surfaced with the shell-mode hint",
      snapshot?.state == .failedToStart(RunStuffMessage.commandNotFound),
      detail: "\(snapshot?.state ?? .idle)",
      ref: "plan §1 PATH problem")
    try? FileManager.default.removeItem(at: context.directory)
  } catch {
    check.p1(
      "failed start surfaced with the shell-mode hint", false,
      detail: "\(error)", ref: "plan §1 PATH problem")
  }
  return check.report
}

func miseProjectScenario(_ h: Harness) async -> ScenarioReport {
  let check = Check("mise-project/")
  let home = SpawnEnvironment.launchdLikeBase()["HOME"] ?? ""
  let projectDir = h.fixture("mise-project")
  if case .unmet(let reason) = Precondition.mise(harness: h, projectDir: projectDir) {
    check.skipped("mise-pinned node runs under login shells", reason: "precondition: \(reason)")
    return check.report
  }
  let installRoot = "\(home)/.local/share/mise/installs/node/"
  let script = h.fixture("mise-project/print-node.sh")

  for mode in [ShellMode.login, .interactiveLogin] {
    let tag = mode.flagDescription
    do {
      let runtime = try await h.start(h.spec(mode, command: [script], cwd: projectDir))
      let recorder = Recorder(await runtime.attach())
      let exit = await runtime.waitForExit(timeout: .seconds(30))
      _ = await runtime.waitForDrainEnd(timeout: .seconds(5))
      _ = await recorder.waitForFinish(timeout: .seconds(2))
      let report = await parseNodeReport(recorder)
      check.note(
        "\(tag): exit \(exit.map { "\($0)" } ?? "none"); node \(report.version ?? "-") at \(report.execPath ?? "-")"
      )
      check.note("\(tag): PATH=\(report.path ?? "(not reported)")")
      check.p0("\(tag): exited(0)", exit == .exited(code: 0))
      let underMise = report.execPath?.hasPrefix(installRoot) == true
      switch mode {
      case .login:
        check.p0(
          "\(tag): execPath is under mise's install root", underMise,
          detail: report.execPath ?? "no NODE line")
      case .interactiveLogin:
        // .zshrc may add another manager (nvm) ahead of mise's shims.
        // Which node wins is this machine's dotfile order, not the
        // process layer, so it is reported rather than asserted.
        check.p0(
          "\(tag): a node ran", report.execPath != nil, detail: report.execPath ?? "no NODE line")
        if !underMise {
          check.note(
            "\(tag): mise pins node 24 for this project but \(report.execPath ?? "?") ran: another manager shadows mise under -i (plan §11 open question 5, silent toolchain mismatch)"
          )
        }
      case .direct:
        break
      }
      check.p0(
        "\(tag): version matches the pinned major (24)", report.version?.hasPrefix("v24") == true,
        detail: report.version ?? "-")
      await h.finish(runtime)
    } catch {
      check.p0("\(tag): spawn", false, detail: "\(error)")
    }
  }

  do {
    let runtime = try await h.start(
      h.spec(.direct, command: ["node", "-e", "console.log(process.version)"], cwd: projectDir))
    check.p0(
      "direct: spawn fails with ENOENT on the scrubbed PATH", false,
      detail: "spawned pid \(runtime.pid) instead")
    _ = await runtime.stop(grace: .seconds(1))
    await h.finish(runtime)
  } catch let error as SpawnError {
    check.p0(
      "direct: spawn fails with ENOENT on the scrubbed PATH", error.errnoValue == ENOENT,
      detail: "\(error)")
  } catch {
    check.p0("direct: spawn fails with ENOENT on the scrubbed PATH", false, detail: "\(error)")
  }
  return check.report
}
