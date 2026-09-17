import Darwin
import Foundation

/// Append-only, file-backed retention of everything read from a PTY master,
/// with the arrival time of each read. A consumer that attaches late can
/// replay from byte 0. Accessed only from inside `JobRuntime`.
final class OutputSpool {
  struct ChunkRecord: Sendable {
    let offset: UInt64
    let count: Int
    let at: ContinuousClock.Instant
  }

  private let fd: Int32
  private let path: String
  private var retaining = true
  private(set) var length: UInt64 = 0
  private var tail = [UInt8](repeating: 0, count: JobRunRecord.maximumOutputBytes)
  private var tailEnd = 0

  var historyOutput: Data {
    if length < UInt64(tail.count) { return Data(tail.prefix(Int(length))) }
    return Data(tail[tailEnd...] + tail[..<tailEnd])
  }

  var retainedLength: off_t {
    var info = stat()
    return fstat(fd, &info) == 0 ? info.st_size : -1
  }
  private(set) var chunks: [ChunkRecord] = []

  init(directory: String) throws(SpoolError) {
    var template = Array("\(directory)/runstuff-spool.XXXXXX".utf8CString)
    let fd = mkstemp(&template)
    guard fd >= 0 else { throw SpoolError.create(errno: errno) }
    self.fd = fd
    self.path = String(
      decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  func append(_ bytes: [UInt8], at instant: ContinuousClock.Instant) {
    // Retain history before subscribers can drop chunks, even after disk replay is discarded.
    if bytes.count >= tail.count {
      tail = Array(bytes.suffix(tail.count))
      tailEnd = 0
    } else {
      var offset = 0
      while offset < bytes.count {
        let count = min(tail.count - tailEnd, bytes.count - offset)
        tail.replaceSubrange(tailEnd..<(tailEnd + count), with: bytes[offset..<(offset + count)])
        tailEnd = (tailEnd + count) % tail.count
        offset += count
      }
    }
    guard retaining else {
      length += UInt64(bytes.count)
      return
    }
    let offset = length
    var written = 0
    while written < bytes.count {
      let n = bytes[written...].withUnsafeBytes { raw in
        pwrite(fd, raw.baseAddress, raw.count, off_t(offset) + off_t(written))
      }
      if n > 0 {
        written += Int(n)
      } else if n < 0 && errno == EINTR {
        continue
      } else {
        retaining = false
        break
      }
    }
    chunks.append(ChunkRecord(offset: offset, count: written, at: instant))
    length += UInt64(bytes.count)
  }

  func stopRetaining() {
    retaining = false
    chunks.removeAll(keepingCapacity: false)
    _ = ftruncate(fd, 0)
  }

  /// Reads `[offset, offset + count)`; may return fewer bytes at the end.
  func read(offset: UInt64, count: Int) -> [UInt8] {
    var buffer = [UInt8](repeating: 0, count: count)
    var got = 0
    while got < count {
      let n = buffer[got...].withUnsafeMutableBytes { raw in
        pread(fd, raw.baseAddress, raw.count, off_t(offset) + off_t(got))
      }
      if n > 0 {
        got += Int(n)
      } else if n < 0 && errno == EINTR {
        continue
      } else {
        break
      }
    }
    return Array(buffer[0..<got])
  }

  func close() {
    Darwin.close(fd)
    unlink(path)
  }
}

public enum SpoolError: Error, Sendable {
  case create(errno: Int32)
}
