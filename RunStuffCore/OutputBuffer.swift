import Foundation

/// One complete line retained from a job's raw PTY output.
public struct OutputLine: Sendable, Equatable {
  /// Monotonic within an `OutputBuffer`, including lines that were evicted.
  public let sequence: UInt64
  /// Wall-clock arrival time of the chunk that completed the line.
  public let timestamp: Date
  /// The bytes exactly as read, including the line terminator when present.
  public let raw: [UInt8]
  /// A lossy UTF-8 projection with terminal escape sequences removed.
  public let stripped: String
}

/// A bounded ring of complete output lines.
///
/// Call `finish()` at EOF to retain a final unterminated line. A line larger
/// than the byte ceiling is consumed but not retained, keeping the buffer
/// bounded without altering any retained raw bytes.
public struct OutputBuffer: Sendable {
  private enum ANSIState: Sendable {
    case text
    case escape
    case csi
    case osc
    case oscEscape
  }

  public let maximumLines: Int
  public let maximumBytes: Int

  private var storage: [OutputLine?]
  private var head = 0
  private var count = 0
  private var retainedBytes = 0
  private var nextSequence: UInt64 = 0
  public private(set) var hasEvictedLines = false

  private var pendingRaw: [UInt8] = []
  private var pendingStripped: [UInt8] = []
  private var pendingIsOversized = false
  private var ansiState = ANSIState.text

  public init(maximumLines: Int = 10_000, maximumBytes: Int = 8 * 1_024 * 1_024) {
    precondition(maximumLines > 0, "maximumLines must be positive")
    precondition(maximumBytes > 0, "maximumBytes must be positive")
    self.maximumLines = maximumLines
    self.maximumBytes = maximumBytes
    self.storage = Array(repeating: nil, count: maximumLines)
  }

  /// Retained lines in oldest-to-newest order.
  public var lines: [OutputLine] {
    (0..<count).compactMap { storage[(head + $0) % maximumLines] }
  }

  public var byteCount: Int { retainedBytes }
  public var pendingBytes: [UInt8] { pendingRaw }
  public var pendingStrippedText: String { String(decoding: pendingStripped, as: UTF8.self) }

  /// Drops retained parser state after a bounded subscriber falls behind.
  /// The next bytes begin a fresh line and terminal replay shows an eviction marker.
  public mutating func discardEarlierOutput() {
    storage = Array(repeating: nil, count: maximumLines)
    head = 0
    count = 0
    retainedBytes = 0
    pendingRaw.removeAll(keepingCapacity: true)
    pendingStripped.removeAll(keepingCapacity: true)
    pendingIsOversized = false
    ansiState = .text
    hasEvictedLines = true
  }

  /// Consumes arbitrary read-sized chunks. Escape-parser state and the
  /// unfinished line both carry across calls.
  public mutating func append(_ bytes: [UInt8], at timestamp: Date = Date()) {
    for byte in bytes {
      if !pendingIsOversized {
        if pendingRaw.count == maximumBytes {
          pendingRaw.removeAll(keepingCapacity: true)
          pendingStripped.removeAll(keepingCapacity: true)
          pendingIsOversized = true
        } else {
          pendingRaw.append(byte)
        }
      }

      consumeForProjection(byte)

      if byte == 0x0A {
        completePendingLine(at: timestamp)
      }
    }
  }

  /// Completes an unterminated final line. Does nothing between lines.
  public mutating func finish(at timestamp: Date = Date()) {
    guard pendingIsOversized || !pendingRaw.isEmpty else { return }
    completePendingLine(at: timestamp)
  }

  private mutating func consumeForProjection(_ byte: UInt8) {
    switch ansiState {
    case .text:
      if byte == 0x1B {
        ansiState = .escape
      } else if !pendingIsOversized {
        pendingStripped.append(byte)
      }
    case .escape:
      if byte == 0x5B {
        ansiState = .csi
      } else if byte == 0x5D {
        ansiState = .osc
      } else if byte == 0x1B {
        ansiState = .escape
      } else {
        // All other ESC sequences are the two-byte form.
        ansiState = .text
      }
    case .csi:
      if byte == 0x1B {
        ansiState = .escape
      } else if (0x40...0x7E).contains(byte) {
        ansiState = .text
      }
    case .osc:
      if byte == 0x07 {
        ansiState = .text
      } else if byte == 0x1B {
        ansiState = .oscEscape
      }
    case .oscEscape:
      if byte == 0x5C {
        ansiState = .text
      } else if byte != 0x1B {
        ansiState = .osc
      }
    }
  }

  private mutating func completePendingLine(at timestamp: Date) {
    let sequence = nextSequence
    nextSequence &+= 1

    if !pendingIsOversized {
      let line = OutputLine(
        sequence: sequence,
        timestamp: timestamp,
        raw: pendingRaw,
        stripped: String(decoding: pendingStripped, as: UTF8.self))
      makeRoom(for: line.raw.count)
      insert(line)
    }

    pendingRaw.removeAll(keepingCapacity: true)
    pendingStripped.removeAll(keepingCapacity: true)
    pendingIsOversized = false
  }

  private mutating func makeRoom(for bytes: Int) {
    while count == maximumLines || retainedBytes + bytes > maximumBytes {
      evictOldest()
    }
  }

  private mutating func insert(_ line: OutputLine) {
    let index = (head + count) % maximumLines
    storage[index] = line
    count += 1
    retainedBytes += line.raw.count
  }

  private mutating func evictOldest() {
    guard count > 0, let line = storage[head] else { return }
    hasEvictedLines = true
    retainedBytes -= line.raw.count
    storage[head] = nil
    head = (head + 1) % maximumLines
    count -= 1
  }
}
