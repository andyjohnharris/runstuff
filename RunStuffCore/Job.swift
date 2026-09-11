import Foundation

extension ShellMode: Codable, Hashable {}

public struct Job: Codable, Identifiable, Hashable, Sendable {
  public var id: UUID
  public var name: String
  public var command: String
  public var workingDirectory: URL
  public var shellMode: ShellMode
  public var env: [String: String]
  public var openTerminalOnStart: Bool
  public var autostartOnLaunch: Bool
  public var restartOnCrash: Bool
  public var maxRestarts: Int
  public var signals: [SignalRule]
  public var readyRule: ReadyRule?
  public var notifyWhenReady: Bool
  public var notifyWhenWaitingForInput: Bool
  public var notifyOnHighCPU: Bool
  public var notes: String
  public var tags: [String]
  public var colorSeed: Int

  public init(
    id: UUID = UUID(),
    name: String,
    command: String,
    workingDirectory: URL,
    shellMode: ShellMode = .login,
    env: [String: String] = [:],
    openTerminalOnStart: Bool = false,
    autostartOnLaunch: Bool = false,
    restartOnCrash: Bool = false,
    maxRestarts: Int = 3,
    signals: [SignalRule] = [],
    readyRule: ReadyRule? = nil,
    notifyWhenReady: Bool = false,
    notifyWhenWaitingForInput: Bool = false,
    notifyOnHighCPU: Bool = false,
    notes: String = "",
    tags: [String] = [],
    colorSeed: Int
  ) {
    self.id = id
    self.name = name
    self.command = command
    self.workingDirectory = workingDirectory
    self.shellMode = shellMode
    self.env = env
    self.openTerminalOnStart = openTerminalOnStart
    self.autostartOnLaunch = autostartOnLaunch
    self.restartOnCrash = restartOnCrash
    self.maxRestarts = maxRestarts
    self.signals = signals
    self.readyRule = readyRule
    self.notifyWhenReady = notifyWhenReady
    self.notifyWhenWaitingForInput = notifyWhenWaitingForInput
    self.notifyOnHighCPU = notifyOnHighCPU
    self.notes = notes
    self.tags = tags
    self.colorSeed = colorSeed
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id)
    name = try values.decode(String.self, forKey: .name)
    command = try values.decode(String.self, forKey: .command)
    workingDirectory = try values.decode(URL.self, forKey: .workingDirectory)
    shellMode = try values.decodeIfPresent(ShellMode.self, forKey: .shellMode) ?? .login
    env = try values.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
    openTerminalOnStart =
      try values.decodeIfPresent(Bool.self, forKey: .openTerminalOnStart) ?? false
    autostartOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .autostartOnLaunch) ?? false
    restartOnCrash = try values.decodeIfPresent(Bool.self, forKey: .restartOnCrash) ?? false
    maxRestarts = try values.decodeIfPresent(Int.self, forKey: .maxRestarts) ?? 3
    signals = try values.decodeIfPresent([SignalRule].self, forKey: .signals) ?? []
    readyRule = try values.decodeIfPresent(ReadyRule.self, forKey: .readyRule)
    notifyWhenReady = try values.decodeIfPresent(Bool.self, forKey: .notifyWhenReady) ?? false
    notifyWhenWaitingForInput =
      try values.decodeIfPresent(Bool.self, forKey: .notifyWhenWaitingForInput) ?? false
    notifyOnHighCPU = try values.decodeIfPresent(Bool.self, forKey: .notifyOnHighCPU) ?? false
    notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
    tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
    colorSeed = try values.decode(Int.self, forKey: .colorSeed)
  }
}

public struct SignalRule: Codable, Hashable, Sendable {
  public var pattern: String
  public var isRegex: Bool
  public var severity: Severity
  public var notify: Bool
  public var caseSensitive: Bool

  public init(
    pattern: String,
    isRegex: Bool = false,
    severity: Severity,
    notify: Bool,
    caseSensitive: Bool = false
  ) {
    self.pattern = pattern
    self.isRegex = isRegex
    self.severity = severity
    self.notify = notify
    self.caseSensitive = caseSensitive
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    pattern = try values.decode(String.self, forKey: .pattern)
    isRegex = try values.decodeIfPresent(Bool.self, forKey: .isRegex) ?? false
    severity = try values.decode(Severity.self, forKey: .severity)
    notify = try values.decode(Bool.self, forKey: .notify)
    caseSensitive = try values.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
  }
}

public enum Severity: String, Codable, Hashable, Sendable {
  case info
  case warning
  case error
}

public enum ReadyRule: Codable, Hashable, Sendable {
  case outputPattern(String)
  case port(Int)
}

public enum RunState: Codable, Hashable, Sendable {
  case idle
  case starting
  case running
  case stopping
  case exited(code: Int32)
  case signalled(Int32)
  case failedToStart(String)
}

public enum Health: Codable, Hashable, Sendable {
  case ok
  case warning(reason: String, since: Date)
  case error(reason: String, since: Date)
}
