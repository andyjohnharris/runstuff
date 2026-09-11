import XCTest

@testable import RunStuffCore

final class OutputBufferTests: XCTestCase {
  func testRawBytesAreUnchangedWhileProjectionStripsCSI() {
    let raw: [UInt8] = [
      0xFF, 0x1B, 0x5B, 0x33, 0x31, 0x6D, 0x72, 0x1B, 0x5B, 0x30, 0x6D, 0x0D, 0x0A,
    ]
    var buffer = OutputBuffer(maximumLines: 3, maximumBytes: 40)
    let timestamp = Date(timeIntervalSince1970: 123)

    buffer.append(raw, at: timestamp)

    XCTAssertEqual(buffer.lines[0].raw, raw)
    XCTAssertEqual(buffer.lines[0].timestamp, timestamp)
    XCTAssertEqual(buffer.lines[0].stripped, "�r\r\n")
  }

  func testSplitCSIAndBareEscapeDoNotLeakIntoProjection() {
    var buffer = OutputBuffer(maximumLines: 4, maximumBytes: 80)

    buffer.append(Array("a\u{1B}".utf8))
    buffer.append(Array("[38;5;2".utf8))
    buffer.append(Array("08morange\u{1B}".utf8))
    buffer.append([0x37])  // ESC 7: save cursor, split between reads.
    buffer.append(Array("!\n".utf8))

    XCTAssertEqual(buffer.lines.map(\.stripped), ["aorange!\n"])
  }

  func testSplitOSCTerminatorsCarryAcrossAppends() {
    var buffer = OutputBuffer(maximumLines: 5, maximumBytes: 100)

    buffer.append(Array("x\u{1B}]0;hidden".utf8))
    buffer.append([0x07])
    buffer.append(Array("y\u{1B}]8;;https://example.invalid\u{1B}".utf8))
    buffer.append(Array("\\label\n".utf8))

    XCTAssertEqual(buffer.lines[0].stripped, "xylabel\n")
  }

  func testLineCeilingEvictsOldestWithoutResettingSequence() {
    var buffer = OutputBuffer(maximumLines: 2, maximumBytes: 50)
    buffer.append(Array("zero\none\ntwo\n".utf8))

    XCTAssertEqual(buffer.lines.map(\.sequence), [1, 2])
    XCTAssertEqual(
      buffer.lines.map { String(decoding: $0.raw, as: UTF8.self) }, ["one\n", "two\n"])
    XCTAssertTrue(buffer.hasEvictedLines)

    buffer.append(Array("three\n".utf8))
    XCTAssertEqual(buffer.lines.map(\.sequence), [2, 3])
  }

  func testByteCeilingEvictsEnoughWholeLines() {
    var buffer = OutputBuffer(maximumLines: 9, maximumBytes: 11)
    buffer.append(Array("aa\nbbbbb\ncc\n".utf8))

    XCTAssertEqual(buffer.byteCount, 9)
    XCTAssertEqual(buffer.lines.map(\.sequence), [1, 2])
    XCTAssertEqual(
      buffer.lines.map { String(decoding: $0.raw, as: UTF8.self) }, ["bbbbb\n", "cc\n"])
  }

  func testOversizedLineIsDroppedAndSequenceStillAdvances() {
    var buffer = OutputBuffer(maximumLines: 4, maximumBytes: 5)
    buffer.append(Array("123456789\nok\n".utf8))

    XCTAssertEqual(buffer.lines.map(\.sequence), [1])
    XCTAssertEqual(buffer.lines[0].raw, Array("ok\n".utf8))
    XCTAssertLessThanOrEqual(buffer.byteCount, 5)
  }

  func testDiscardEarlierOutputResetsPartialParserStateAndMarksReplay() {
    var buffer = OutputBuffer(maximumLines: 4, maximumBytes: 20)
    buffer.append(Array("old\npartial\u{1B}[31".utf8))

    buffer.discardEarlierOutput()
    buffer.append(Array("new\n".utf8))

    XCTAssertTrue(buffer.hasEvictedLines)
    XCTAssertEqual(buffer.lines.map(\.stripped), ["new\n"])
  }

  func testFinishRetainsAnUnterminatedLineOnlyOnce() {
    var buffer = OutputBuffer(maximumLines: 2, maximumBytes: 20)
    buffer.append(Array("tail".utf8))
    XCTAssertEqual(buffer.pendingBytes, Array("tail".utf8))
    buffer.finish()
    buffer.finish()

    XCTAssertEqual(buffer.lines.map(\.sequence), [0])
    XCTAssertEqual(buffer.lines[0].raw, Array("tail".utf8))
    XCTAssertTrue(buffer.pendingBytes.isEmpty)
  }
}
