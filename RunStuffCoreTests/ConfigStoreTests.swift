import Foundation
import XCTest

@testable import RunStuffCore

final class ConfigStoreTests: XCTestCase {
  func testJobDefaultsAndConfigurationRoundTrip() throws {
    let job = Job(
      id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
      name: "Web",
      command: "npm run dev",
      workingDirectory: URL(fileURLWithPath: "/tmp/project"),
      readyRule: .outputPattern("ready in"),
      colorSeed: 42
    )

    XCTAssertEqual(job.shellMode, .login)
    XCTAssertEqual(job.env, [:])
    XCTAssertFalse(job.openTerminalOnStart)
    XCTAssertFalse(job.autostartOnLaunch)
    XCTAssertFalse(job.restartOnCrash)
    XCTAssertEqual(job.maxRestarts, 3)
    XCTAssertEqual(job.signals, [])
    XCTAssertEqual(job.notes, "")
    XCTAssertEqual(job.tags, [])

    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = RunStuffConfiguration(jobs: [job])
    try store.save(configuration)
    XCTAssertEqual(try store.load(), configuration)
  }

  func testDecodingJobAppliesDocumentedDefaults() throws {
    let json = """
      {
        "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "name": "API",
        "command": "make serve",
        "workingDirectory": "file:///tmp/api/",
        "colorSeed": 7
      }
      """
    let job = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
    XCTAssertEqual(job.shellMode, .login)
    XCTAssertEqual(job.env, [:])
    XCTAssertFalse(job.openTerminalOnStart)
    XCTAssertFalse(job.autostartOnLaunch)
    XCTAssertFalse(job.restartOnCrash)
    XCTAssertEqual(job.maxRestarts, 3)
    XCTAssertEqual(job.signals, [])
    XCTAssertNil(job.readyRule)
    XCTAssertEqual(job.notes, "")
    XCTAssertEqual(job.tags, [])
  }

  func testDecodingSignalRuleAppliesDocumentedDefaults() throws {
    let json = #"{"pattern":"EADDRINUSE","severity":"error","notify":true}"#
    let rule = try JSONDecoder().decode(SignalRule.self, from: Data(json.utf8))
    XCTAssertFalse(rule.isRegex)
    XCTAssertFalse(rule.caseSensitive)
  }

  func testAtomicReplacementAlwaysLeavesACompleteConfiguration() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let old = RunStuffConfiguration(jobs: [
      makeJob(name: "old", command: String(repeating: "x", count: 100_000))
    ])
    let new = RunStuffConfiguration(jobs: [
      makeJob(name: "new", command: String(repeating: "y", count: 200_000))
    ])

    try store.save(old)
    for index in 0..<20 {
      try store.save(index.isMultiple(of: 2) ? new : old)
      let loaded = try store.load()
      XCTAssertTrue(loaded == old || loaded == new)
    }
  }

  func testMalformedFileIsReportedAndPreserved() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let malformed = Data("{ definitely not JSON".utf8)
    try malformed.write(to: store.fileURL)

    XCTAssertThrowsError(try store.load())
    XCTAssertEqual(try Data(contentsOf: store.fileURL), malformed)
  }

  func testMissingFileLoadsAsEmptyConfiguration() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }

    XCTAssertEqual(try store.loadOrEmpty(), RunStuffConfiguration())
  }

  func testUnsupportedVersionAndDuplicateIDsAreRejected() throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let job = makeJob(name: "one", command: "true")

    try store.save(RunStuffConfiguration(version: 2, jobs: []))
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? ConfigStoreError, .unsupportedVersion(2))
    }

    try store.save(RunStuffConfiguration(jobs: [job, job]))
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? ConfigStoreError, .duplicateJobID(job.id))
    }
  }

  private func makeStore() throws -> (ConfigStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (ConfigStore(fileURL: directory.appendingPathComponent("config.json")), directory)
  }

  private func makeJob(name: String, command: String) -> Job {
    Job(
      name: name,
      command: command,
      workingDirectory: URL(fileURLWithPath: "/tmp"),
      colorSeed: 1
    )
  }
}
