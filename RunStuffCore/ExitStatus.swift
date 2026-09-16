import Darwin
import Foundation

/// How a RunStuff process ended after reaping.
///
/// Decoded by hand from the `waitpid` status word because Swift does not
/// import the `WIFEXITED` family of macros. Layout (sys/wait.h): the low
/// seven bits are zero for a normal exit, otherwise the terminating signal;
/// bit 7 is the core-dump flag; bits 8–15 carry the exit code.
public enum ExitStatus: Sendable, Equatable, CustomStringConvertible {
  case exited(code: Int32)
  case signalled(signal: Int32, coreDumped: Bool)

  public init(waitStatus status: Int32) {
    let low = status & 0x7f
    if low == 0 {
      self = .exited(code: (status >> 8) & 0xff)
    } else {
      self = .signalled(signal: low, coreDumped: (status & 0x80) != 0)
    }
  }

  public var description: String {
    switch self {
    case .exited(let code):
      return "exited(\(code))"
    case .signalled(let signal, let core):
      return "signalled(\(signalName(signal))\(core ? ", core" : ""))"
    }
  }
}

public func signalName(_ signal: Int32) -> String {
  switch signal {
  case SIGHUP: return "SIGHUP"
  case SIGINT: return "SIGINT"
  case SIGQUIT: return "SIGQUIT"
  case SIGABRT: return "SIGABRT"
  case SIGKILL: return "SIGKILL"
  case SIGSEGV: return "SIGSEGV"
  case SIGPIPE: return "SIGPIPE"
  case SIGTERM: return "SIGTERM"
  case SIGWINCH: return "SIGWINCH"
  default: return "signal \(signal)"
  }
}

public struct FailureDiagnostic: Sendable, Equatable {
  public let summary: String
  public let evidence: String
  public let conflictingPort: UInt16?

  public static func matchedLine(_ line: String) -> Self {
    portConflict(in: line)
      ?? Self(
        summary: String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
        evidence: String(line.prefix(1_000)), conflictingPort: nil)
  }

  public static func portConflict(in line: String) -> Self? {
    guard line.range(of: "address already in use", options: .caseInsensitive) != nil else {
      return nil
    }
    let patterns = [
      #"listen tcp(?:4|6)? [^\s"]*:(\d+): bind: address already in use"#,
      #"listen EADDRINUSE: address already in use [^\s]+:(\d+)(?:\s|$)"#,
      #"TCPServer#initialize': Address already in use - bind\(2\) for "[^"]+" port (\d+) \(Errno::EADDRINUSE\)"#,
    ]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
        let range = Range(match.range(at: 1), in: line),
        let port = UInt16(line[range]), port > 0
      else { continue }
      return Self(
        summary: "Could not listen on TCP port \(port): address already in use.",
        evidence: String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1_000)),
        conflictingPort: port)
    }
    return nil
  }
}
