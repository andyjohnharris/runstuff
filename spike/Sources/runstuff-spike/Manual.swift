import Darwin
import Dispatch
import RunStuffCore

/// `--manual`: run a fixture and behave like a terminal for it. Raw stdin
/// goes to the master, master output goes to stdout, our own SIGWINCH is
/// forwarded as a resize. For eyeballing colours and \r redraws.
enum ManualRunner {
  static func run(_ h: Harness, fixture: String, mode: ShellMode) async -> Int32 {
    let isTTY = isatty(0) == 1
    var size = WindowSize.default
    if isTTY {
      var ws = winsize()
      if ioctl(1, TIOCGWINSZ, &ws) == 0, ws.ws_row > 0, ws.ws_col > 0 {
        size = WindowSize(rows: ws.ws_row, cols: ws.ws_col)
      }
    }
    let runtime: JobRuntime
    do {
      runtime = try await h.start(h.scriptSpec(mode, script: fixture, windowSize: size))
    } catch {
      print("spawn failed: \(error)")
      return 1
    }

    var saved = termios()
    if isTTY {
      tcgetattr(0, &saved)
      var raw = saved
      cfmakeraw(&raw)
      tcsetattr(0, TCSANOW, &raw)
    }
    defer {
      if isTTY {
        var restore = saved
        tcsetattr(0, TCSANOW, &restore)
      }
    }

    let stdinSource = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .global())
    stdinSource.setEventHandler {
      var buffer = [UInt8](repeating: 0, count: 1024)
      let n = buffer.withUnsafeMutableBytes { Darwin.read(0, $0.baseAddress, $0.count) }
      guard n > 0 else { return }
      let bytes = Array(buffer[0..<Int(n)])
      Task { try? await runtime.write(bytes) }
    }
    stdinSource.resume()

    let winchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    signal(SIGWINCH, SIG_IGN)
    winchSource.setEventHandler {
      var ws = winsize()
      guard ioctl(1, TIOCGWINSZ, &ws) == 0 else { return }
      let newSize = WindowSize(rows: ws.ws_row, cols: ws.ws_col)
      Task { try? await runtime.resize(newSize) }
    }
    winchSource.resume()

    for await chunk in await runtime.attach() {
      var offset = 0
      while offset < chunk.bytes.count {
        let n = chunk.bytes[offset...].withUnsafeBytes { Darwin.write(1, $0.baseAddress, $0.count) }
        if n <= 0 { break }
        offset += Int(n)
      }
    }
    let exit = await runtime.waitForExit(timeout: .seconds(30))
    stdinSource.cancel()
    winchSource.cancel()
    let footer = "\r\n[runstuff-spike] \(exit.map { "\($0)" } ?? "no exit observed")\r\n"
    _ = footer.withCString { Darwin.write(1, $0, strlen($0)) }
    await h.finish(runtime)
    return 0
  }
}
