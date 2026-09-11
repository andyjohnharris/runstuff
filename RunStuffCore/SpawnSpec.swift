/// Terminal dimensions applied with `TIOCSWINSZ`.
public struct WindowSize: Sendable, Equatable {
  public var rows: UInt16
  public var cols: UInt16

  public init(rows: UInt16, cols: UInt16) {
    self.rows = rows
    self.cols = cols
  }

  /// A sane starting size so a process spawned with no view attached does
  /// not see 0x0 and take a degraded, no-terminal path. Replaced by
  /// `TIOCSWINSZ` + SIGWINCH when a real view attaches.
  public static let `default` = WindowSize(rows: 30, cols: 120)
}

/// Everything `PTYSpawner` needs to start one RunStuff process.
public struct SpawnSpec: Sendable {
  /// `argv[0]` is resolved against `environment["PATH"]` unless it contains a slash.
  public var argv: [String]
  public var workingDirectory: String
  public var environment: [String: String]
  public var windowSize: WindowSize
  /// Absolute path of `runstuff-tty-helper`. When set (the normal case), the
  /// helper is spawned and acquires the controlling terminal before exec'ing
  /// the command. When nil, the command is spawned directly and has no
  /// controlling terminal, only for tests that want that.
  public var ttyHelperPath: String?

  public init(
    argv: [String],
    workingDirectory: String,
    environment: [String: String],
    windowSize: WindowSize = .default,
    ttyHelperPath: String? = nil
  ) {
    self.argv = argv
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.windowSize = windowSize
    self.ttyHelperPath = ttyHelperPath
  }
}
