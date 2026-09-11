import Darwin
import Dispatch
import Foundation
import RunStuffCore

enum RunStuffCLI {
  static func run() throws -> Never {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let verb = arguments.first, let command = AttachCommand(rawValue: verb) else {
      fail("usage: runstuff list | start <name-or-id> | stop <name-or-id> | attach <name-or-id>")
    }
    let expectedArgumentCount = command == .list ? 1 : 2
    guard arguments.count == expectedArgumentCount else {
      fail("usage: runstuff list | start <name-or-id> | stop <name-or-id> | attach <name-or-id>")
    }
    let identifier = arguments.dropFirst().first
    if command != .list, identifier == nil {
      fail("runstuff \(verb) requires a Stuff name or ID")
    }

    let connection: UnixSocketConnection
    do {
      connection = try UnixSocketConnection(connectingTo: RunStuffSocket.defaultPath)
    } catch {
      fail("cannot connect to RunStuff; make sure the app is open (\(error))")
    }
    try connection.writeLine(AttachRequest(command: command, job: identifier))
    guard let responseLine = try connection.readLine() else {
      fail("RunStuff closed the connection without a response")
    }
    let response = try JSONDecoder().decode(AttachResponse.self, from: responseLine)
    guard response.ok else { fail(response.message ?? "RunStuff could not complete the command") }

    switch command {
    case .list:
      for job in response.jobs ?? [] {
        print("\(job.id.uuidString)\t\(job.state)\t\(job.name)")
      }
      Foundation.exit(EXIT_SUCCESS)
    case .start, .stop:
      if let message = response.message { print(message) }
      Foundation.exit(EXIT_SUCCESS)
    case .attach:
      return try attach(connection)
    }
  }

  private static func attach(_ connection: UnixSocketConnection) throws -> Never {
    let terminal = TerminalMode()
    terminal.enableRawMode()
    sendWindowSize(connection)

    signal(SIGWINCH, SIG_IGN)
    let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    winch.setEventHandler { sendWindowSize(connection) }
    winch.resume()

    let stdinSource = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
    stdinSource.setEventHandler {
      var bytes = [UInt8](repeating: 0, count: 4096)
      let count = bytes.withUnsafeMutableBytes {
        Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count)
      }
      guard count > 0 else {
        terminal.markDetached()
        connection.close()
        return
      }
      try? connection.writeLine(
        AttachStreamMessage(kind: .input, data: Data(bytes[..<Int(count)])))
    }
    stdinSource.resume()

    DispatchQueue.global().async {
      var succeeded = false
      do {
        stream: while let line = try connection.readLine() {
          let message = try JSONDecoder().decode(AttachStreamMessage.self, from: line)
          switch message.kind {
          case .ended:
            terminal.markCompleted()
            break stream
          case .output:
            if let data = message.data { writeStandardOutput(data) }
          case .input, .resize:
            continue
          }
        }
        succeeded = terminal.wasDetached || terminal.didComplete
      } catch {
        if !terminal.wasDetached {
          let message = "\r\nrunstuff attach: \(error)\r\n"
          writeStandardError(Data(message.utf8))
        } else {
          succeeded = true
        }
      }
      if !succeeded {
        writeStandardError(Data("\r\nrunstuff attach: RunStuff closed the connection\r\n".utf8))
      }
      terminal.restore()
      Foundation.exit(succeeded ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    let terminationSources = [SIGHUP, SIGINT, SIGTERM].map { signalNumber in
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
      source.setEventHandler {
        terminal.restore()
        Foundation.exit(128 + signalNumber)
      }
      source.resume()
      return source
    }
    withExtendedLifetime((winch, stdinSource, terminationSources)) {
      dispatchMain()
    }
  }

  private static func sendWindowSize(_ connection: UnixSocketConnection) {
    var size = winsize()
    guard ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row > 0, size.ws_col > 0 else {
      return
    }
    try? connection.writeLine(
      AttachStreamMessage(kind: .resize, rows: size.ws_row, cols: size.ws_col))
  }

  private static func fail(_ message: String) -> Never {
    writeStandardError(Data("runstuff: \(message)\n".utf8))
    Foundation.exit(EXIT_FAILURE)
  }
}

/// Restores the caller's terminal exactly once, including when the socket
/// closes from the background reader.
private final class TerminalMode: @unchecked Sendable {
  private let lock = NSLock()
  private var original: termios?
  private var detached = false
  private var completed = false

  var wasDetached: Bool {
    lock.withLock { detached }
  }

  var didComplete: Bool {
    lock.withLock { completed }
  }

  func markDetached() {
    lock.withLock { detached = true }
  }

  func markCompleted() {
    lock.withLock { completed = true }
  }

  func enableRawMode() {
    guard isatty(STDIN_FILENO) == 1 else { return }
    var settings = termios()
    guard tcgetattr(STDIN_FILENO, &settings) == 0 else { return }
    lock.withLock { original = settings }
    cfmakeraw(&settings)
    _ = tcsetattr(STDIN_FILENO, TCSANOW, &settings)
  }

  func restore() {
    lock.lock()
    guard var settings = original else {
      lock.unlock()
      return
    }
    original = nil
    lock.unlock()
    _ = tcsetattr(STDIN_FILENO, TCSANOW, &settings)
  }
}

private func writeStandardOutput(_ data: Data) {
  writeAll(data, descriptor: STDOUT_FILENO)
}

private func writeStandardError(_ data: Data) {
  writeAll(data, descriptor: STDERR_FILENO)
}

private func writeAll(_ data: Data, descriptor: Int32) {
  var offset = 0
  while offset < data.count {
    let count = data.withUnsafeBytes {
      Darwin.write(descriptor, $0.baseAddress?.advanced(by: offset), data.count - offset)
    }
    if count < 0, errno == EINTR { continue }
    guard count > 0 else { return }
    offset += count
  }
}

do {
  try RunStuffCLI.run()
} catch {
  let message = Data("runstuff: \(error)\n".utf8)
  writeStandardError(message)
  Foundation.exit(EXIT_FAILURE)
}
