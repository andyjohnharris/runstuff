import Darwin
import Dispatch

/// Production runtime for one spawned process and its PTY. Owns the master fd, the drain, exit
/// detection and reaping, and the group/session kill path. Plan §1.
///
/// Isolation: the actor runs on its own `DispatchSerialQueue`, which is also
/// the queue of the read source, so the drain handler enters the actor
/// synchronously with `assumeIsolated`. Reaping runs on a separate queue so
/// the blocking `waitpid` cannot stall the drain.
///
/// Two independent end signals: `.exited` (the direct child was reaped) and
/// `.drainEnded` (no process holds the slave). Either may come first and
/// neither is inferred from the other.
public actor JobRuntime {
  public nonisolated let unownedExecutor: UnownedSerialExecutor

  public nonisolated let pid: pid_t
  /// Equal to `pid`: the child leads its own process group.
  public nonisolated var pgid: pid_t { pid }
  /// Equal to `pid`: the child leads its own session.
  public nonisolated var sid: pid_t { pid }
  public nonisolated let slaveDevice: dev_t
  public nonisolated let slavePath: String
  public nonisolated let spawnedAt: ContinuousClock.Instant
  public nonisolated let events: AsyncStream<RuntimeEvent>

  private let queue: DispatchSerialQueue
  /// One shared serial queue reaps every job, so N blocking `waitpid` calls
  /// cannot each pin a thread from the global pool (thread explosion at 40
  /// jobs). `waitpid` returns promptly once `NOTE_EXIT` has fired, so
  /// serialising reaps across jobs adds only microseconds.
  private static let reapQueue = DispatchQueue(label: "runstuff.reap")
  private let master: Int32
  private let spool: OutputSpool
  private let eventContinuation: AsyncStream<RuntimeEvent>.Continuation

  private var readSource: DispatchSourceRead?
  private var processSource: DispatchSourceProcess?
  private var readBuffer = [UInt8](repeating: 0, count: 65536)

  private var subscribers: [Int: AsyncStream<OutputChunk>.Continuation] = [:]
  private var nextSubscriberID = 0

  private var lastWindowSize: WindowSize
  public private(set) var exitStatus: ExitStatus?
  public private(set) var exitedAt: ContinuousClock.Instant?
  public private(set) var drainEnd: DrainEnd?
  public private(set) var drainEndedAt: ContinuousClock.Instant?
  private var masterClosed = false
  /// Diagnostic: read-source handler invocations after the drain ended.
  /// Must stay 0; a level-triggered EOF would otherwise spin.
  public private(set) var handlerCallsAfterDrainEnd = 0

  // MARK: Start

  /// Spawns and installs both sources before returning. From here the
  /// master is drained whether or not anyone attaches.
  public static func start(_ spec: SpawnSpec, spoolDirectory: String) throws -> JobRuntime {
    let spool = try OutputSpool(directory: spoolDirectory)
    let process: SpawnedProcess
    do {
      process = try PTYSpawner.spawn(spec)
    } catch {
      spool.close()
      throw error
    }
    let queue = DispatchSerialQueue(label: "runstuff.job.\(process.pid)")
    let runtime = JobRuntime(
      process: process, queue: queue, spool: spool, initialSize: spec.windowSize)
    // Runs on the actor's queue, so isolation can be assumed inside.
    queue.sync {
      runtime.assumeIsolated { isolated in
        isolated.installSources()
      }
    }
    return runtime
  }

  private init(
    process: SpawnedProcess, queue: DispatchSerialQueue, spool: OutputSpool, initialSize: WindowSize
  ) {
    self.queue = queue
    self.unownedExecutor = queue.asUnownedSerialExecutor()
    self.pid = process.pid
    self.master = process.master
    self.slaveDevice = process.slaveDevice
    self.slavePath = process.slavePath
    self.spool = spool
    self.lastWindowSize = initialSize
    self.spawnedAt = .now
    let (stream, continuation) = AsyncStream.makeStream(
      of: RuntimeEvent.self, bufferingPolicy: .unbounded)
    self.events = stream
    self.eventContinuation = continuation
  }

  private func installSources() {
    let read = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
    read.setEventHandler { [self] in
      self.assumeIsolated { isolated in
        isolated.drain()
      }
    }
    let fd = master
    read.setCancelHandler { [self] in
      // libdispatch: the fd may only be closed once cancellation has
      // completed, which is here.
      Darwin.close(fd)
      self.assumeIsolated { isolated in
        isolated.masterClosed = true
        isolated.finishIfComplete()
      }
    }
    readSource = read
    read.resume()

    let process = DispatchSource.makeProcessSource(
      identifier: pid, eventMask: .exit, queue: Self.reapQueue)
    let childPID = pid
    process.setEventHandler { @Sendable [self, weak process] in
      // NOTE_EXIT fires before the child is marked a zombie, so a
      // WNOHANG here could return 0. Blocking is correct: the child is
      // exiting and the kernel wakes this waiter as soon as it is
      // reapable. Nothing else in this process reaps.
      var status: Int32 = 0
      var rc: pid_t
      repeat {
        rc = waitpid(childPID, &status, 0)
      } while rc == -1 && errno == EINTR
      let at = ContinuousClock.now
      let result: ExitStatus? = rc == childPID ? ExitStatus(waitStatus: status) : nil
      process?.cancel()
      Task { await self.recordExit(result, at: at) }
    }
    processSource = process
    process.resume()
  }

  // MARK: Drain

  private func drain() {
    if drainEnd != nil {
      handlerCallsAfterDrainEnd += 1
      return
    }
    while true {
      let n = readBuffer.withUnsafeMutableBytes { raw in
        Darwin.read(master, raw.baseAddress, raw.count)
      }
      if n > 0 {
        deliver(Array(readBuffer[0..<Int(n)]))
        continue
      }
      if n == 0 {
        endDrain(.eof)
        return
      }
      let e = errno
      switch e {
      case EAGAIN: return
      case EINTR: continue
      case EIO:
        endDrain(.eio)
        return
      default:
        endDrain(.error(errno: e))
        return
      }
    }
  }

  private func deliver(_ bytes: [UInt8]) {
    let at = ContinuousClock.now
    let chunk = OutputChunk(offset: spool.length, bytes: bytes, at: at)
    spool.append(bytes, at: at)
    for continuation in subscribers.values {
      continuation.yield(chunk)
    }
  }

  private func endDrain(_ reason: DrainEnd) {
    guard drainEnd == nil else { return }
    let at = ContinuousClock.now
    drainEnd = reason
    drainEndedAt = at
    for continuation in subscribers.values { continuation.finish() }
    subscribers.removeAll()
    eventContinuation.yield(.drainEnded(reason, at: at))
    readSource?.cancel()
    readSource = nil
  }

  private func recordExit(_ status: ExitStatus?, at: ContinuousClock.Instant) {
    guard exitStatus == nil else { return }
    // nil means waitpid returned ECHILD: something else reaped the pid.
    // Report it as an exit we could not decode rather than hang.
    let resolved = status ?? .exited(code: -1)
    exitStatus = resolved
    exitedAt = at
    eventContinuation.yield(.exited(resolved, at: at))
    processSource = nil
    finishIfComplete()
  }

  private func finishIfComplete() {
    if exitStatus != nil && drainEnd != nil && masterClosed {
      eventContinuation.finish()
    }
  }

  // MARK: Consumers

  /// Replays everything spooled so far, then streams live chunks. Safe to
  /// call at any time, including after the drain ended.
  public func attach(
    discardReplayAfterAttach: Bool = false,
    bufferingPolicy: AsyncStream<OutputChunk>.Continuation.BufferingPolicy = .unbounded
  ) -> AsyncStream<OutputChunk> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: OutputChunk.self, bufferingPolicy: bufferingPolicy)
    var offset: UInt64 = 0
    let replayAt = ContinuousClock.now
    while offset < spool.length {
      let want = Int(min(UInt64(1 << 20), spool.length - offset))
      let bytes = spool.read(offset: offset, count: want)
      if bytes.isEmpty { break }
      continuation.yield(OutputChunk(offset: offset, bytes: bytes, at: replayAt))
      offset += UInt64(bytes.count)
    }
    if discardReplayAfterAttach {
      spool.stopRetaining()
    }
    if drainEnd != nil {
      continuation.finish()
      return stream
    }
    let id = nextSubscriberID
    nextSubscriberID += 1
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      guard let self else { return }
      Task { await self.removeSubscriber(id) }
    }
    return stream
  }

  private func removeSubscriber(_ id: Int) {
    subscribers[id] = nil
  }

  /// Arrival records of every read so far: proves draining happened while
  /// nobody was attached.
  public func chunkRecords() -> [(offset: UInt64, count: Int, at: ContinuousClock.Instant)] {
    spool.chunks.map { ($0.offset, $0.count, $0.at) }
  }

  public func spooledLength() -> UInt64 { spool.length }

  // MARK: Control

  public enum RuntimeError: Error, Sendable, Equatable {
    case write(errno: Int32)
    case ioctl(errno: Int32)
    case masterClosed
  }

  /// Writes to the master; what a terminal would send as keyboard input.
  public func write(_ bytes: [UInt8]) throws(RuntimeError) {
    guard drainEnd == nil else { throw RuntimeError.masterClosed }
    var offset = 0
    while offset < bytes.count {
      let n = bytes[offset...].withUnsafeBytes { raw in
        Darwin.write(master, raw.baseAddress, raw.count)
      }
      if n >= 0 {
        offset += Int(n)
        continue
      }
      let e = errno
      if e == EAGAIN || e == EINTR {
        usleep(1000)
        continue
      }
      throw RuntimeError.write(errno: e)
    }
  }

  /// `TIOCSWINSZ` on the master, then a belt-and-braces SIGWINCH to the
  /// tty's current foreground process group. The ioctl already asks the
  /// kernel to signal that group when the size changes.
  ///
  /// No-op when the size is unchanged, matching the kernel's own
  /// suppression. The signal targets `tcgetpgrp(master)`, the group the tty
  /// actually foregrounds, not the job's static pgid: job control can move
  /// the foreground command into its own group, and a shell-launched job's
  /// controlling-terminal setup does not always let the kernel's automatic
  /// delivery reach it. `tcgetpgrp` gives the correct target in every case.
  public func resize(_ size: WindowSize) throws(RuntimeError) {
    guard drainEnd == nil else { throw RuntimeError.masterClosed }
    guard size != lastWindowSize else { return }
    lastWindowSize = size
    var ws = winsize(ws_row: size.rows, ws_col: size.cols, ws_xpixel: 0, ws_ypixel: 0)
    guard ioctl(master, TIOCSWINSZ, &ws) == 0 else {
      throw RuntimeError.ioctl(errno: errno)
    }
    let foreground = tcgetpgrp(master)
    if foreground > 0 { _ = killProcessGroup(foreground, SIGWINCH) }
  }

  /// The tty's current foreground process group (`tcgetpgrp`), or -1 if the
  /// master has no controlling foreground group. Diagnostic.
  public func foregroundGroup() -> pid_t {
    tcgetpgrp(master)
  }

  public enum SignalOutcome: Sendable, Equatable {
    case delivered
    /// `ESRCH`: no process left in the group.
    case groupGone
    case failed(errno: Int32)
  }

  /// `kill(-pgid, sig)`: the fast path that reaches every process still in
  /// the job's process group.
  public func signalGroup(_ sig: Int32) -> SignalOutcome {
    if killProcessGroup(pgid, sig) == 0 { return .delivered }
    let e = errno
    return e == ESRCH ? .groupGone : .failed(errno: e)
  }

  /// Never pass zero to a negated `kill`: `kill(-0, sig)` is `kill(0, sig)`
  /// and would signal RunStuff's own process group.
  @discardableResult
  private func killProcessGroup(_ group: pid_t, _ sig: Int32) -> Int32 {
    guard group > 0 else {
      assertionFailure("negated kill with non-positive pgid \(group)")
      errno = EINVAL
      return -1
    }
    return kill(-group, sig)
  }

  /// Signals every live process in the job's session individually. Catches
  /// what job control moved out of the process group.
  @discardableResult
  public func signalSession(_ sig: Int32) -> [pid_t] {
    let members = ProcessTable.sessionMembers(sid: sid)
    for member in members { _ = kill(member, sig) }
    return members
  }

  public struct StopReport: Sendable {
    public var leaderExit: ExitStatus?
    public var escalatedToKill = false
    /// Session members found outside the job's process group when TERM
    /// was sent: the ones `kill(-pgid)` alone would have missed.
    public var outsideGroupAtTerm: [pid_t] = []
    /// Session members still alive after the grace period.
    public var survivorsAtGrace: [pid_t] = []
    /// Session members still alive when stop() gave up, if any.
    public var remaining: [pid_t] = []
    public var sessionClearedAfter: Duration?
  }

  /// SIGTERM to the group and the session, wait up to `grace`, then SIGKILL
  /// to whatever is left. Returns once the session is empty and the leader
  /// is reaped, or after `killTimeout` past escalation.
  public func stop(grace: Duration, killTimeout: Duration = .seconds(5)) async -> StopReport {
    var report = StopReport()
    let start = ContinuousClock.now

    _ = signalGroup(SIGTERM)
    let membersAtTerm = signalSession(SIGTERM)
    report.outsideGroupAtTerm = membersAtTerm.filter { member in
      ProcessTable.info(pid: member)?.pgid != pgid
    }

    // Wait for the leader to exit and the session to empty, up to grace.
    while ContinuousClock.now - start < grace {
      if exitStatus != nil && ProcessTable.sessionMembers(sid: sid).isEmpty { break }
      try? await Task.sleep(for: .milliseconds(25))
    }

    var survivors = ProcessTable.sessionMembers(sid: sid)
    if exitStatus == nil || !survivors.isEmpty {
      report.survivorsAtGrace = survivors
      report.escalatedToKill = true
      _ = signalGroup(SIGKILL)
      signalSession(SIGKILL)
      let killStart = ContinuousClock.now
      while ContinuousClock.now - killStart < killTimeout {
        survivors = ProcessTable.sessionMembers(sid: sid)
        if exitStatus != nil && survivors.isEmpty { break }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
    survivors = ProcessTable.sessionMembers(sid: sid)
    report.remaining = survivors
    if survivors.isEmpty { report.sessionClearedAfter = ContinuousClock.now - start }
    report.leaderExit = exitStatus
    return report
  }

  /// Waits for the direct child to be reaped.
  public func waitForExit(timeout: Duration) async -> ExitStatus? {
    let start = ContinuousClock.now
    while exitStatus == nil {
      if ContinuousClock.now - start >= timeout { return nil }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return exitStatus
  }

  /// Waits for the master to reach EOF and be closed.
  public func waitForDrainEnd(timeout: Duration) async -> DrainEnd? {
    let start = ContinuousClock.now
    while drainEnd == nil || !masterClosed {
      if ContinuousClock.now - start >= timeout { return drainEnd }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return drainEnd
  }

  /// Cancels the sources, closes the master, removes the spool. Waits until
  /// the master is really closed so an fd census afterwards is accurate.
  public func close() async {
    if drainEnd == nil {
      endDrain(.closed)
    }
    processSource?.cancel()
    processSource = nil
    while !masterClosed {
      try? await Task.sleep(for: .milliseconds(5))
    }
    spool.close()
    eventContinuation.finish()
  }
}
