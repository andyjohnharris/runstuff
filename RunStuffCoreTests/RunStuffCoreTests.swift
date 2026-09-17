import XCTest

@testable import RunStuffCore

// XCTest rather than Swift Testing keeps the production module tests usable
// under both Xcode and SwiftPM.

final class ExitStatusTests: XCTestCase {
  func testNormalExit() {
    XCTAssertEqual(ExitStatus(waitStatus: 0), .exited(code: 0))
    XCTAssertEqual(ExitStatus(waitStatus: 1 << 8), .exited(code: 1))
    XCTAssertEqual(ExitStatus(waitStatus: 127 << 8), .exited(code: 127))
    XCTAssertEqual(ExitStatus(waitStatus: 255 << 8), .exited(code: 255))
  }

  func testSignalDeath() {
    XCTAssertEqual(ExitStatus(waitStatus: 11), .signalled(signal: 11, coreDumped: false))
    XCTAssertEqual(ExitStatus(waitStatus: 11 | 0x80), .signalled(signal: 11, coreDumped: true))
    XCTAssertEqual(ExitStatus(waitStatus: 9), .signalled(signal: 9, coreDumped: false))
  }

  func testExit139IsNotSignal11() {
    // A shell that saw its child die of SIGSEGV reports 128 + 11.
    XCTAssertEqual(ExitStatus(waitStatus: 139 << 8), .exited(code: 139))
  }
}

final class OutputSpoolTests: XCTestCase {
  func testStoppingRetentionTruncatesAndDiscardsFutureBytes() throws {
    let directory = FileManager.default.temporaryDirectory.path
    let spool = try OutputSpool(directory: directory)
    defer { spool.close() }
    spool.append(Array(repeating: 0x78, count: 1024), at: .now)
    XCTAssertEqual(spool.retainedLength, 1024)

    spool.stopRetaining()
    spool.append(Array(repeating: 0x79, count: 2048), at: .now)

    XCTAssertEqual(spool.length, 3072)
    XCTAssertEqual(spool.retainedLength, 0)
    XCTAssertEqual(spool.chunks.count, 0)
    XCTAssertEqual(
      spool.historyOutput,
      Data(Array(repeating: 0x78, count: 1024) + Array(repeating: 0x79, count: 2048)))
  }

  func testHistoryTailWrapsInByteOrderAfterReplayStops() throws {
    let spool = try OutputSpool(directory: FileManager.default.temporaryDirectory.path)
    defer { spool.close() }
    spool.stopRetaining()
    let size = 262144
    let total = size * 2 + 73
    for start in stride(from: 0, to: total, by: 17003) {
      let end = min(total, start + 17003)
      spool.append((start..<end).map { UInt8($0 % 251) }, at: .now)
    }
    XCTAssertEqual(spool.historyOutput, Data(((total - size)..<total).map { UInt8($0 % 251) }))
    spool.append(Array(repeating: 0xFE, count: size + 1), at: .now)
    spool.append([1, 2, 3], at: .now)
    XCTAssertEqual(spool.historyOutput, Data(Array(repeating: 0xFE, count: size - 3) + [1, 2, 3]))
    XCTAssertEqual(spool.retainedLength, 0)
  }
}

final class ShellModeTests: XCTestCase {
  func testLoginArgv() {
    XCTAssertEqual(
      ShellMode.login.argv(command: ["npm", "run", "dev"], shell: "/bin/zsh"),
      ["/bin/zsh", "-l", "-c", "unset COLUMNS LINES; npm run dev"])
  }

  func testInteractiveLoginArgv() {
    XCTAssertEqual(
      ShellMode.interactiveLogin.argv(command: ["npm", "run", "dev"], shell: "/bin/zsh"),
      ["/bin/zsh", "-l", "-i", "-c", "unset COLUMNS LINES; npm run dev"])
  }

  func testDirectArgvIsUntouched() {
    // Direct mode gets no shell, so no unset prefix; its environment never
    // carries COLUMNS/LINES in the first place.
    XCTAssertEqual(
      ShellMode.direct.argv(command: ["node", "-e", "console.log(1)"], shell: "/bin/zsh"),
      ["node", "-e", "console.log(1)"])
  }

  func testColumnsNeutralized() {
    XCTAssertEqual(ShellMode.neutralizeColumns("npm run dev"), "unset COLUMNS LINES; npm run dev")
  }

  func testQuotingProtectsSpacesAndQuotes() {
    XCTAssertEqual(ShellMode.shellQuote("plain-word_1.txt"), "plain-word_1.txt")
    XCTAssertEqual(ShellMode.shellQuote("has space"), "'has space'")
    XCTAssertEqual(ShellMode.shellQuote("it's"), "'it'\\''s'")
    XCTAssertEqual(ShellMode.shellQuote(""), "''")
    XCTAssertEqual(
      ShellMode.login.argv(command: ["node", "-e", "console.log('x')"], shell: "/bin/zsh")[3],
      "unset COLUMNS LINES; node -e 'console.log('\\''x'\\'')'")
  }

  func testCommandLinePassThrough() {
    XCTAssertEqual(
      ShellMode.login.argv(commandLine: "fixtures/job-control.sh && true", shell: "/bin/zsh"),
      ["/bin/zsh", "-l", "-c", "unset COLUMNS LINES; fixtures/job-control.sh && true"])
    XCTAssertEqual(
      ShellMode.direct.argv(commandLine: "a  b\tc", shell: "/bin/zsh"), ["a", "b", "c"])
  }
}

final class Phase3InfrastructureTests: XCTestCase {
  func testKeychainReferencesResolveOnlyWholeEnvironmentValues() throws {
    let environment = [
      "TOKEN": "${keychain:api-token}",
      "LITERAL": "prefix-${keychain:not-a-reference}",
      "EMPTY": "${keychain:}",
    ]

    let resolved = try KeychainEnvironment.resolve(environment) { name in
      XCTAssertEqual(name, "api-token")
      return "secret-value"
    }

    XCTAssertEqual(resolved["TOKEN"], "secret-value")
    XCTAssertEqual(resolved["LITERAL"], "prefix-${keychain:not-a-reference}")
    XCTAssertEqual(resolved["EMPTY"], "${keychain:}")
  }

  func testUnixSocketRoundTripUsesJSONLines() async throws {
    let path = "/tmp/runstuff-test-\(UUID().uuidString).sock"
    let listener = try UnixSocketListener(path: path)
    defer { listener.close() }
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
    XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    let server = Task.detached(priority: .userInitiated) {
      let connection = try listener.accept()
      defer { connection.close() }
      let line = try XCTUnwrap(connection.readLine())
      let request = try JSONDecoder().decode(AttachRequest.self, from: line)
      try connection.writeLine(AttachResponse(ok: request.command == .list))
    }

    let client = try UnixSocketConnection(connectingTo: path)
    defer { client.close() }
    try client.writeLine(AttachRequest(command: .list))
    let responseLine = try XCTUnwrap(client.readLine())
    let response = try JSONDecoder().decode(AttachResponse.self, from: responseLine)

    XCTAssertTrue(response.ok)
    try await server.value
  }

  func testClosingConnectionUnblocksActiveRead() async throws {
    let path = "/tmp/runstuff-test-\(UUID().uuidString).sock"
    let listener = try UnixSocketListener(path: path)
    defer { listener.close() }
    let acceptTask = Task.detached(priority: .userInitiated) { try listener.accept() }
    let client = try UnixSocketConnection(connectingTo: path)
    defer { client.close() }
    let server = try await acceptTask.value
    let readTask = Task.detached(priority: .userInitiated) {
      do {
        return try server.readLine() == nil
      } catch {
        return true
      }
    }

    try await Task.sleep(for: .milliseconds(20))
    server.close()

    let readEnded = await readTask.value
    XCTAssertTrue(readEnded)
  }

  func testClosingListenerEndsActiveAccept() async throws {
    let path = "/tmp/runstuff-test-\(UUID().uuidString).sock"
    let listener = try UnixSocketListener(path: path)
    let acceptTask = Task.detached(priority: .userInitiated) {
      do {
        _ = try listener.accept()
        return false
      } catch {
        return true
      }
    }

    try await Task.sleep(for: .milliseconds(20))
    listener.close()

    let acceptEnded = await acceptTask.value
    XCTAssertTrue(acceptEnded)
  }

  func testUnixSocketRejectsOversizedCompleteLine() async throws {
    let path = "/tmp/runstuff-test-\(UUID().uuidString).sock"
    let listener = try UnixSocketListener(path: path)
    defer { listener.close() }
    let acceptTask = Task.detached(priority: .userInitiated) { try listener.accept() }
    let client = try UnixSocketConnection(connectingTo: path)
    defer { client.close() }
    let server = try await acceptTask.value
    defer { server.close() }

    try client.write(Data("01234567890\n".utf8))

    XCTAssertThrowsError(try server.readLine(maxBytes: 10))
  }

  func testMaximumReplayMessageFitsSocketLineLimit() throws {
    let message = AttachStreamMessage(
      kind: .output,
      data: Data(repeating: 0xFF, count: RunStuffSocket.replayChunkBytes))
    let lineBytes = try JSONEncoder().encode(message).count + 1

    XCTAssertLessThanOrEqual(lineBytes, RunStuffSocket.maximumLineBytes)
  }
}

final class SpawnEnvironmentTests: XCTestCase {
  func testLayeringLaterWins() {
    let env = SpawnEnvironment.layered(
      ["PATH": "/usr/bin", "HOME": "/Users/x"],
      ["TERM": "xterm-256color"],
      ["PATH": "/opt/override"])
    XCTAssertEqual(env["PATH"], "/opt/override")
    XCTAssertEqual(env["HOME"], "/Users/x")
    XCTAssertEqual(env["TERM"], "xterm-256color")
  }

  func testBaseIsScrubbed() {
    let env = SpawnEnvironment.launchdLikeBase()
    XCTAssertEqual(env["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    XCTAssertNotNil(env["HOME"])
    XCTAssertNotNil(env["SHELL"])
    XCTAssertNil(env["NVM_DIR"])
  }

  func testJobDefaults() {
    let env = SpawnEnvironment.jobDefaults(jobID: "abc", windowSize: WindowSize(rows: 24, cols: 80))
    XCTAssertEqual(env["TERM"], "xterm-256color")
    XCTAssertEqual(env["RUNSTUFF_JOB"], "abc")
    // COLUMNS/LINES are deliberately not set: the TIOCSWINSZ ioctl is the
    // single source of terminal size.
    XCTAssertNil(env["COLUMNS"])
    XCTAssertNil(env["LINES"])
  }

  func testResolveExecutable() {
    XCTAssertEqual(SpawnEnvironment.resolveExecutable("sh", path: "/usr/bin:/bin"), "/bin/sh")
    XCTAssertNil(
      SpawnEnvironment.resolveExecutable("definitely-not-a-command-4f2a", path: "/usr/bin:/bin"))
    XCTAssertEqual(SpawnEnvironment.resolveExecutable("/bin/sh", path: ""), "/bin/sh")
  }
}
