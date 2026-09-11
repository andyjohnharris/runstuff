import Darwin
import Foundation

public struct RuntimeRecord: Codable, Equatable, Sendable {
  public let jobID: UUID
  public let pid: pid_t
  public let pgid: pid_t
  public let sid: pid_t
  public let startSeconds: Int64
  public let startMicroseconds: Int32
  public let commandFingerprint: UInt64
  public let recoveryJob: Job?

  public init(
    job: Job, runtime: JobRuntime, process: ProcessTable.Info, includeRecoveryJob: Bool = false
  ) {
    jobID = job.id
    pid = runtime.pid
    pgid = runtime.pgid
    sid = runtime.sid
    startSeconds = Int64(process.startTime.tv_sec)
    startMicroseconds = process.startTime.tv_usec
    commandFingerprint = Self.fingerprint(job.command)
    recoveryJob = includeRecoveryJob ? job : nil
  }

  public func matchesCurrentProcess() -> Bool {
    guard let process = ProcessTable.info(pid: pid) else { return false }
    return Int64(process.startTime.tv_sec) == startSeconds
      && process.startTime.tv_usec == startMicroseconds
      && getsid(pid) == sid
  }

  public static func fingerprint(_ command: String) -> UInt64 {
    command.utf8.reduce(14_695_981_039_346_656_037) { hash, byte in
      (hash ^ UInt64(byte)) &* 1_099_511_628_211
    }
  }
}

public struct RuntimeRegistry: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> [RuntimeRecord] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    return try JSONDecoder().decode([RuntimeRecord].self, from: Data(contentsOf: fileURL))
  }

  @discardableResult
  public func reconcile() throws -> [RuntimeRecord] {
    let live = try load().filter { $0.matchesCurrentProcess() }
    try save(live)
    return live
  }

  public func save(_ records: [RuntimeRecord]) throws {
    let directory = fileURL.deletingLastPathComponent()
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let temporaryURL = directory.appendingPathComponent(".runtime.\(UUID().uuidString).tmp")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      try encoder.encode(records).write(to: temporaryURL, options: .withoutOverwriting)
      if fileManager.fileExists(atPath: fileURL.path) {
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: fileURL)
      }
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }
  }
}
