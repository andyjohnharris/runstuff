import RunStuffCore

/// Consumes an attached output stream, keeps every byte, and answers
/// "has this text arrived yet" questions. For small fixtures only; the
/// firehose uses `LineScanner`.
actor Recorder {
  private(set) var bytes: [UInt8] = []
  private(set) var arrivals: [(offset: UInt64, count: Int, at: ContinuousClock.Instant)] = []
  private(set) var finished = false

  init(_ stream: AsyncStream<OutputChunk>) {
    Task { [weak self] in
      for await chunk in stream {
        guard let self else { return }
        await self.append(chunk)
      }
      await self?.markFinished()
    }
  }

  private func append(_ chunk: OutputChunk) {
    bytes.append(contentsOf: chunk.bytes)
    arrivals.append((chunk.offset, chunk.bytes.count, chunk.at))
  }

  private func markFinished() {
    finished = true
  }

  /// Index just past the first occurrence of `pattern` at or after `from`,
  /// or nil if it has not arrived within `timeout`.
  func waitFor(_ pattern: String, from: Int = 0, timeout: Duration) async -> Int? {
    let needle = Array(pattern.utf8)
    let start = ContinuousClock.now
    while true {
      if let end = find(needle, from: from) { return end }
      if finished || ContinuousClock.now - start >= timeout { return nil }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Waits until the stream has ended, then returns whether it did.
  func waitForFinish(timeout: Duration) async -> Bool {
    let start = ContinuousClock.now
    while !finished {
      if ContinuousClock.now - start >= timeout { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return true
  }

  func find(_ needle: [UInt8], from: Int = 0) -> Int? {
    guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
    var i = max(0, from)
    while i + needle.count <= bytes.count {
      if bytes[i] == needle[0] && Array(bytes[i..<(i + needle.count)]) == needle {
        return i + needle.count
      }
      i += 1
    }
    return nil
  }

  func contains(_ text: String, from: Int = 0) -> Bool {
    find(Array(text.utf8), from: from) != nil
  }

  func count(of byte: UInt8) -> Int {
    bytes.reduce(0) { $0 + ($1 == byte ? 1 : 0) }
  }

  /// Lossy UTF-8 view of everything received.
  func text() -> String {
    String(decoding: bytes, as: UTF8.self)
  }

  /// Lines split on CR and LF bytes; used to parse `KEY value` reports.
  /// Split on bytes, not Characters: Swift treats "\r\n" as one Character.
  func lines() -> [String] {
    bytes.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D })
      .map { String(decoding: $0, as: UTF8.self) }
  }

  /// The first line starting with `prefix`, minus the prefix.
  func value(after prefix: String) -> String? {
    for line in lines() where line.hasPrefix(prefix) {
      return String(line.dropFirst(prefix.count)).trimmingSpaces()
    }
    return nil
  }

  /// All lines starting with `prefix`, minus the prefix.
  func values(after prefix: String) -> [String] {
    lines().filter { $0.hasPrefix(prefix) }.map {
      String($0.dropFirst(prefix.count)).trimmingSpaces()
    }
  }
}

extension String {
  func trimmingSpaces() -> String {
    var s = self[...]
    while let f = s.first, f == " " || f == "\t" { s = s.dropFirst() }
    while let l = s.last, l == " " || l == "\t" { s = s.dropLast() }
    return String(s)
  }
}

/// Streams through large output without keeping it: counts one byte value
/// and records the stream offset of lines that start with given prefixes.
struct LineScanner {
  let countedByte: UInt8
  let prefixes: [[UInt8]]
  private(set) var counted: UInt64 = 0
  private(set) var totalBytes: UInt64 = 0
  /// (stream offset of line start, line text) for matching lines.
  private(set) var matches: [(offset: UInt64, line: String)] = []
  private var partial: [UInt8] = []
  private var partialStart: UInt64 = 0

  init(countedByte: UInt8, prefixes: [String]) {
    self.countedByte = countedByte
    self.prefixes = prefixes.map { Array($0.utf8) }
  }

  mutating func consume(_ chunk: OutputChunk) {
    totalBytes += UInt64(chunk.bytes.count)
    var lineStart = chunk.offset
    var i = 0
    let bytes = chunk.bytes
    while i < bytes.count {
      let b = bytes[i]
      if b == countedByte { counted += 1 }
      if b == 0x0A {
        if partial.isEmpty {
          finishLine(bytes[Int(lineStart - chunk.offset)..<i], start: lineStart)
        } else {
          partial.append(contentsOf: bytes[Int(lineStart - chunk.offset)..<i])
          finishLine(partial[...], start: partialStart)
          partial.removeAll(keepingCapacity: true)
        }
        lineStart = chunk.offset + UInt64(i + 1)
      }
      i += 1
    }
    let tail = bytes[Int(lineStart - chunk.offset)..<bytes.count]
    if !tail.isEmpty {
      if partial.isEmpty { partialStart = lineStart }
      partial.append(contentsOf: tail)
      // Only the beginning of a line matters for prefix matching.
      if partial.count > 4096 { partial.removeLast(partial.count - 4096) }
    }
  }

  private mutating func finishLine(_ line: ArraySlice<UInt8>, start: UInt64) {
    var text = line
    if text.last == 0x0D { text = text.dropLast() }
    for prefix in prefixes
    where text.count >= prefix.count && Array(text.prefix(prefix.count)) == prefix {
      matches.append((start, String(decoding: text, as: UTF8.self)))
      return
    }
  }
}
