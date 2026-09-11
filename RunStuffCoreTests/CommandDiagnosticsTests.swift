import Foundation
import XCTest

@testable import RunStuffCore

final class CommandDiagnosticsTests: XCTestCase {
  func testDirectUsesJobPATHInsteadOfLoginShellPATH() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeExecutable(
      name: "diagnostic-tool",
      body: "#!/bin/sh\nprintf 'direct 1.0\\nextra usage text\\n'\n")
    try "export PATH='\(fixture.loginBin.path):/usr/bin:/bin'\n".write(
      to: fixture.home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: fixture.loginBin, withIntermediateDirectories: true)
    try fixture.writeExecutable(
      at: fixture.loginBin.appendingPathComponent("diagnostic-tool"),
      body: "#!/bin/sh\nprintf 'login 2.0\\n'\n")

    let direct = try await CommandDiagnosticsResolver.resolve(
      job: fixture.job(mode: .direct, path: fixture.bin.path),
      launchdEnvironment: fixture.environment)
    let login = try await CommandDiagnosticsResolver.resolve(
      job: fixture.job(mode: .login),
      launchdEnvironment: fixture.environment)

    XCTAssertEqual(
      direct.resolvedExecutable, fixture.bin.appendingPathComponent("diagnostic-tool").path)
    XCTAssertEqual(direct.executableVersion, "direct 1.0")
    XCTAssertEqual(
      login.resolvedExecutable, fixture.loginBin.appendingPathComponent("diagnostic-tool").path)
    XCTAssertEqual(login.executableVersion, "login 2.0")
    XCTAssertTrue(login.effectivePATH.hasPrefix(fixture.loginBin.path))
  }

  func testVersionProbeTimesOutAndKillsProcess() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.writeExecutable(
      name: "diagnostic-tool",
      body: "#!/bin/sh\ntrap '' TERM\nwhile :; do printf 'not a version\\n'; done\n")
    let start = ContinuousClock.now
    let result = try await CommandDiagnosticsResolver.resolve(
      job: fixture.job(mode: .direct, path: fixture.bin.path),
      launchdEnvironment: fixture.environment,
      versionTimeout: .milliseconds(100))

    XCTAssertTrue(result.versionTimedOut)
    XCTAssertNil(result.executableVersion)
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
  }
}

private struct Fixture {
  let root: URL
  let home: URL
  let bin: URL
  let loginBin: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    home = root.appendingPathComponent("home")
    bin = root.appendingPathComponent("direct-bin")
    loginBin = root.appendingPathComponent("login-bin")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  }

  var environment: [String: String] {
    ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": "/bin/zsh", "USER": "test"]
  }

  func job(mode: ShellMode, path: String? = nil) -> Job {
    Job(
      name: "diagnostic",
      command: "diagnostic-tool",
      workingDirectory: root,
      shellMode: mode,
      env: path.map { ["PATH": $0] } ?? [:],
      colorSeed: 1)
  }

  func writeExecutable(name: String, body: String) throws {
    try writeExecutable(at: bin.appendingPathComponent(name), body: body)
  }

  func writeExecutable(at url: URL, body: String) throws {
    try body.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
