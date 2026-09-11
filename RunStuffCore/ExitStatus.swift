import Darwin

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
