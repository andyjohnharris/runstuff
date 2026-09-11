/// How RunStuff turns a job's command line into an argv. Plan §1, "The PATH problem".
public enum ShellMode: String, Sendable, CaseIterable {
  /// `$SHELL -l -c <command>`. Sources `.zprofile`/`.zshenv`.
  case login
  /// `$SHELL -l -i -c <command>`. Also sources `.zshrc`, where nvm lives.
  case interactiveLogin
  /// The argv is executed as given, with `argv[0]` resolved against the
  /// job's own `PATH`. No shell.
  case direct

  /// Builds the argv the spawner executes.
  ///
  /// - Parameters:
  ///   - command: the job's argv. Shell modes join it with single-quoting
  ///     into one command string; direct mode uses it as is.
  ///   - shell: absolute path of the login shell, normally `$SHELL`.
  public func argv(command: [String], shell: String) -> [String] {
    switch self {
    case .login:
      return [shell, "-l", "-c", Self.neutralizeColumns(Self.joinForShell(command))]
    case .interactiveLogin:
      return [shell, "-l", "-i", "-c", Self.neutralizeColumns(Self.joinForShell(command))]
    case .direct:
      return command
    }
  }

  /// Builds the argv from a command string the user typed. Shell modes
  /// pass it through untouched; direct mode splits on whitespace.
  public func argv(commandLine: String, shell: String) -> [String] {
    switch self {
    case .login:
      return [shell, "-l", "-c", Self.neutralizeColumns(commandLine)]
    case .interactiveLogin:
      return [shell, "-l", "-i", "-c", Self.neutralizeColumns(commandLine)]
    case .direct:
      return commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }
  }

  /// Prefixes `unset COLUMNS LINES;` so the ioctl remains the only source of
  /// terminal size. Runs after the shell has sourced its rc files, so it
  /// also clears a value the user exported there. See `jobDefaults`.
  public static func neutralizeColumns(_ command: String) -> String {
    "unset COLUMNS LINES; " + command
  }

  /// Joins words into one shell command, single-quoting any word that needs it.
  public static func joinForShell(_ words: [String]) -> String {
    words.map(shellQuote).joined(separator: " ")
  }

  public static func shellQuote(_ word: String) -> String {
    let safe = word.allSatisfy { ch in
      ch.isLetter || ch.isNumber || "-_./=:@%+,".contains(ch)
    }
    if safe && !word.isEmpty { return word }
    return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  public var flagDescription: String {
    switch self {
    case .login: return "-l -c"
    case .interactiveLogin: return "-l -i -c"
    case .direct: return "direct"
    }
  }
}

extension String {
  fileprivate func replacingOccurrences(of target: String, with replacement: String) -> String {
    var result = ""
    var remainder = self[...]
    while let range = remainder.range(of: target) {
      result += remainder[..<range.lowerBound]
      result += replacement
      remainder = remainder[range.upperBound...]
    }
    result += remainder
    return result
  }
}

extension Substring {
  fileprivate func range(of target: String) -> Range<Index>? {
    guard !target.isEmpty else { return nil }
    var index = startIndex
    while index < endIndex {
      if self[index...].hasPrefix(target) {
        return index..<self.index(index, offsetBy: target.count)
      }
      index = self.index(after: index)
    }
    return nil
  }
}
