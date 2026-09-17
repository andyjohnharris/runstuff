import Foundation

public struct JobRunRecord: Identifiable, Codable, Sendable, Equatable {
  public static let maximumOutputBytes = 256 * 1024

  public let id: UUID
  public let jobID: UUID
  public let name: String
  public let command: String
  public let workingDirectory: String
  public let shellMode: String
  public let startedAt: Date
  public let endedAt: Date
  public let outcome: String
  public let failureSummary: String?
  public let failureEvidence: String?
  public let conflictingPort: UInt16?
  public let exitStatus: String?
  public let resolvedExecutable: String?
  public let executableVersion: String?
  public let metrics: [JobMetric]?
  public let rawOutput: Data
  public let outputTruncated: Bool
  public let isRecovered: Bool

  public init(
    id: UUID = UUID(), jobID: UUID, name: String, command: String,
    workingDirectory: String, shellMode: String, startedAt: Date, endedAt: Date,
    outcome: String, failureSummary: String? = nil, failureEvidence: String? = nil,
    rawOutput: Data, outputTruncated: Bool, isRecovered: Bool = false,
    conflictingPort: UInt16? = nil, exitStatus: String? = nil,
    resolvedExecutable: String? = nil, executableVersion: String? = nil,
    metrics: [JobMetric]? = nil
  ) {
    self.id = id
    self.jobID = jobID
    self.name = name
    self.command = command
    self.workingDirectory = workingDirectory
    self.shellMode = shellMode
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.outcome = outcome
    self.failureSummary = failureSummary
    self.failureEvidence = failureEvidence
    self.conflictingPort = conflictingPort
    self.exitStatus = exitStatus
    self.resolvedExecutable = resolvedExecutable
    self.executableVersion = executableVersion
    self.metrics = metrics
    self.rawOutput = rawOutput
    self.outputTruncated = outputTruncated
    self.isRecovered = isRecovered
  }
}

struct RunHistoryStore: Sendable {
  let directory: URL

  init(configURL: URL) {
    directory = configURL.deletingLastPathComponent().appendingPathComponent(
      "history", isDirectory: true)
  }

  func load() -> (records: [JobRunRecord], errors: [String]) {
    guard FileManager.default.fileExists(atPath: directory.path) else { return ([], []) }
    do {
      let urls = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
      var records: [JobRunRecord] = []
      var errors: [String] = []
      for url in urls where url.pathExtension == "json" {
        do {
          records.append(try JSONDecoder().decode(JobRunRecord.self, from: Data(contentsOf: url)))
        } catch {
          errors.append("Could not read run history \(url.lastPathComponent): \(error)")
        }
      }
      return (records, errors)
    } catch {
      return ([], ["Could not read run history: \(error)"])
    }
  }

  func save(_ record: JobRunRecord) throws {
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let destination = directory.appendingPathComponent(record.id.uuidString).appendingPathExtension(
      "json")
    let temporary = directory.appendingPathComponent(".\(record.id.uuidString).tmp")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try encoder.encode(record).write(to: temporary, options: .withoutOverwriting)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      try FileManager.default.moveItem(at: temporary, to: destination)
    } catch {
      try? FileManager.default.removeItem(at: temporary)
      throw error
    }
  }
}
