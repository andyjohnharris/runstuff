/// A slice of raw PTY-master output. `offset` is the byte position in the job's
/// output stream since spawn, which doubles as the replay cursor.
public struct OutputChunk: Sendable {
  public let offset: UInt64
  public let bytes: [UInt8]
  public let at: ContinuousClock.Instant
}

/// Why reading the master stopped.
public enum DrainEnd: Sendable, Equatable {
  /// `read()` returned 0: no process holds the slave any more.
  case eof
  /// `read()` failed with `EIO`. Not expected on macOS; treated as EOF.
  case eio
  case error(errno: Int32)
  /// The runtime was closed while the master was still open.
  case closed
}

/// Lifecycle events from a `JobRuntime`. Output uses the `attach` stream.
public enum RuntimeEvent: Sendable {
  case exited(ExitStatus, at: ContinuousClock.Instant)
  case drainEnded(DrainEnd, at: ContinuousClock.Instant)
}

extension Duration {
  public var seconds: Double {
    let parts = components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
  }
}
