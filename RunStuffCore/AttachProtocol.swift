import Foundation

public enum AttachCommand: String, Codable, Sendable {
  case attach
  case list
  case start
  case stop
}

public struct AttachRequest: Codable, Sendable {
  public var command: AttachCommand
  public var job: String?

  public init(command: AttachCommand, job: String? = nil) {
    self.command = command
    self.job = job
  }
}

public struct AttachJob: Codable, Sendable {
  public var id: UUID
  public var name: String
  public var state: String

  public init(id: UUID, name: String, state: String) {
    self.id = id
    self.name = name
    self.state = state
  }
}

public struct AttachResponse: Codable, Sendable {
  public var ok: Bool
  public var message: String?
  public var jobs: [AttachJob]?

  public init(ok: Bool, message: String? = nil, jobs: [AttachJob]? = nil) {
    self.ok = ok
    self.message = message
    self.jobs = jobs
  }
}

public enum AttachStreamKind: String, Codable, Sendable {
  case ended
  case input
  case output
  case resize
}

public struct AttachStreamMessage: Codable, Sendable {
  public var kind: AttachStreamKind
  public var data: Data?
  public var rows: UInt16?
  public var cols: UInt16?

  public init(
    kind: AttachStreamKind,
    data: Data? = nil,
    rows: UInt16? = nil,
    cols: UInt16? = nil
  ) {
    self.kind = kind
    self.data = data
    self.rows = rows
    self.cols = cols
  }
}

public enum RunStuffSocket {
  public static let maximumLineBytes = 1_048_576
  public static let replayChunkBytes = 256 * 1_024

  public static var defaultPath: String {
    if let override = ProcessInfo.processInfo.environment["RUNSTUFF_SOCKET_PATH"], !override.isEmpty
    {
      return override
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/RunStuff/runstuff.sock").path
  }
}
