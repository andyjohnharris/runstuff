import Darwin
import Foundation

public enum UnixSocketError: Error, CustomStringConvertible, Sendable {
  case pathTooLong
  case system(call: String, code: Int32)

  public var description: String {
    switch self {
    case .pathTooLong:
      return "Unix socket path must be at most 103 UTF-8 bytes"
    case .system(let call, let code):
      return "\(call): \(String(cString: strerror(code)))"
    }
  }
}

/// Owns each socket descriptor and coordinates `close` with active system
/// calls. `shutdown` unblocks connection reads before the descriptor is closed.
private final class UnixSocketState: @unchecked Sendable {
  enum Kind {
    case connection
    case listener(path: String)
  }

  let descriptor: Int32
  private let kind: Kind
  private let readLock = NSLock()
  private let writeLock = NSLock()
  private let condition = NSCondition()
  private var readBuffer = Data()
  private var activeCalls = 0
  private var isClosing = false

  init(descriptor: Int32, kind: Kind) {
    self.descriptor = descriptor
    self.kind = kind
  }

  deinit {
    close()
  }

  func readLine(maxBytes: Int) throws -> Data? {
    readLock.lock()
    defer { readLock.unlock() }
    try beginCall()
    defer { endCall() }

    while true {
      if let newline = readBuffer.firstIndex(of: 0x0A) {
        guard newline <= maxBytes else {
          throw UnixSocketError.system(call: "read (line too long)", code: EMSGSIZE)
        }
        let line = readBuffer[..<newline]
        readBuffer.removeSubrange(...newline)
        return Data(line)
      }
      guard readBuffer.count < maxBytes else {
        throw UnixSocketError.system(call: "read (line too long)", code: EMSGSIZE)
      }
      var bytes = [UInt8](repeating: 0, count: 16_384)
      let count = bytes.withUnsafeMutableBytes {
        Darwin.read(descriptor, $0.baseAddress, $0.count)
      }
      if count == 0 {
        guard !readBuffer.isEmpty else { return nil }
        let remainder = readBuffer
        readBuffer.removeAll(keepingCapacity: false)
        return remainder
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw UnixSocketError.system(call: "read", code: errno)
      }
      readBuffer.append(contentsOf: bytes[..<Int(count)])
    }
  }

  func write(_ data: Data) throws {
    writeLock.lock()
    defer { writeLock.unlock() }
    try beginCall()
    defer { endCall() }

    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeBytes {
        Darwin.write(descriptor, $0.baseAddress?.advanced(by: offset), data.count - offset)
      }
      if count < 0 {
        if errno == EINTR { continue }
        throw UnixSocketError.system(call: "write", code: errno)
      }
      guard count > 0 else {
        throw UnixSocketError.system(call: "write", code: EPIPE)
      }
      offset += count
    }
  }

  func accept() throws -> Int32 {
    while true {
      try beginCall()
      let client = Darwin.accept(descriptor, nil, nil)
      let code = errno
      endCall()
      if client >= 0 { return client }
      if code == EINTR { continue }
      if code == EAGAIN || code == EWOULDBLOCK {
        usleep(20_000)
        continue
      }
      throw UnixSocketError.system(call: "accept", code: code)
    }
  }

  func close() {
    condition.lock()
    guard !isClosing else {
      condition.unlock()
      return
    }
    isClosing = true
    if case .connection = kind {
      _ = shutdown(descriptor, SHUT_RDWR)
    }
    while activeCalls > 0 {
      condition.wait()
    }
    if case .listener(let path) = kind {
      _ = unlink(path)
    }
    Darwin.close(descriptor)
    condition.unlock()
  }

  private func beginCall() throws {
    condition.lock()
    defer { condition.unlock() }
    guard !isClosing else {
      throw UnixSocketError.system(call: "socket closed", code: EBADF)
    }
    activeCalls += 1
  }

  private func endCall() {
    condition.lock()
    activeCalls -= 1
    if activeCalls == 0 { condition.broadcast() }
    condition.unlock()
  }
}

public final class UnixSocketConnection: Sendable {
  private let state: UnixSocketState

  public convenience init(connectingTo path: String) throws {
    let descriptor = try Self.makeDescriptor()
    do {
      try Self.withAddress(path: path) { address, length in
        guard Darwin.connect(descriptor, address, length) == 0 else {
          throw UnixSocketError.system(call: "connect", code: errno)
        }
      }
      self.init(descriptor: descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  init(descriptor: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(
      descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled))
    )
    _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) }
    state = UnixSocketState(descriptor: descriptor, kind: .connection)
  }

  public func readLine(maxBytes: Int = RunStuffSocket.maximumLineBytes) throws -> Data? {
    try state.readLine(maxBytes: maxBytes)
  }

  public func writeLine<T: Encodable>(_ value: T) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0A)
    try state.write(data)
  }

  public func write(_ data: Data) throws {
    try state.write(data)
  }

  public func close() {
    state.close()
  }

  fileprivate static func makeDescriptor() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw UnixSocketError.system(call: "socket", code: errno)
    }
    return descriptor
  }

  fileprivate static func withAddress<T>(
    path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
  ) throws -> T {
    let pathBytes = Array(path.utf8)
    guard pathBytes.count <= 103 else { throw UnixSocketError.pathTooLong }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
      destination.copyBytes(from: pathBytes)
      destination[pathBytes.count] = 0
    }
    let length = socklen_t(2 + pathBytes.count + 1)
    return try withUnsafePointer(to: &address) {
      try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        try body($0, length)
      }
    }
  }
}

public final class UnixSocketListener: Sendable {
  private let state: UnixSocketState

  public init(path: String) throws {
    let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: path) {
      do {
        let liveConnection = try UnixSocketConnection(connectingTo: path)
        liveConnection.close()
        throw UnixSocketError.system(call: "bind", code: EADDRINUSE)
      } catch UnixSocketError.system(let call, _) where call == "connect" {
        guard unlink(path) == 0 else {
          throw UnixSocketError.system(call: "unlink", code: errno)
        }
      }
    }

    let descriptor = try UnixSocketConnection.makeDescriptor()
    do {
      try UnixSocketConnection.withAddress(path: path) { address, length in
        guard Darwin.bind(descriptor, address, length) == 0 else {
          throw UnixSocketError.system(call: "bind", code: errno)
        }
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: path)
      guard Darwin.listen(descriptor, 16) == 0 else {
        throw UnixSocketError.system(call: "listen", code: errno)
      }
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw UnixSocketError.system(call: "fcntl", code: errno)
      }
      _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
      state = UnixSocketState(descriptor: descriptor, kind: .listener(path: path))
    } catch {
      Darwin.close(descriptor)
      _ = unlink(path)
      throw error
    }
  }

  public func accept() throws -> UnixSocketConnection {
    try UnixSocketConnection(descriptor: state.accept())
  }

  public func close() {
    state.close()
  }
}
