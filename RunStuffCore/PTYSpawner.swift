import Darwin
import Dispatch

/// The result of a successful spawn. The master fd belongs to whoever holds
/// this value until a `JobRuntime` takes it over.
public struct SpawnedProcess: Sendable {
  public let master: Int32
  public let pid: pid_t
  /// `st_rdev` of the slave, for checking which tty a child ended up with.
  public let slaveDevice: dev_t
  public let slavePath: String
}

public enum SpawnError: Error, Sendable, Equatable, CustomStringConvertible {
  case openpty(errno: Int32)
  case attributes(errno: Int32)
  case fileActions(errno: Int32)
  case spawn(errno: Int32)
  case executableNotFound(name: String)

  public var description: String {
    switch self {
    case .openpty(let e): return "openpty failed: \(errnoString(e))"
    case .attributes(let e): return "posix_spawnattr failed: \(errnoString(e))"
    case .fileActions(let e): return "posix_spawn_file_actions failed: \(errnoString(e))"
    case .spawn(let e): return "posix_spawn failed: \(errnoString(e))"
    case .executableNotFound(let name): return "\(name): not found on the job's PATH"
    }
  }

  public var errnoValue: Int32? {
    switch self {
    case .openpty(let e), .attributes(let e), .fileActions(let e), .spawn(let e): return e
    case .executableNotFound: return ENOENT
    }
  }
}

public func errnoString(_ code: Int32) -> String {
  if let text = strerror(code) {
    return "\(String(cString: text)) (errno \(code))"
  }
  return "errno \(code)"
}

/// RunStuff's reviewed C-interop boundary for starting a process on a PTY.
///
/// Plan §1 "Process spawn". `posix_spawn` with `POSIX_SPAWN_SETSID` so the
/// child leads its own session and process group (`pgid == pid`), and
/// `POSIX_SPAWN_CLOEXEC_DEFAULT` so only the fds named in the file actions
/// reach it. File actions open the slave on fd 0 and dup it to 1 and 2. A
/// tiny helper acquires that slave as the controlling terminal before exec.
/// Verified against xnu: file actions run
/// inside the syscall, so the child already holds the slave when
/// `posix_spawn` returns and the parent can close its own slave fd at once;
/// on any error no child exists.
public enum PTYSpawner {
  /// Serializes the whole spawn critical section: openpty through
  /// posix_spawn. macOS `openpty` (its internal `grantpt`/`ptsname`
  /// sequence) is not safe against a concurrent `posix_spawn` fork in
  /// another thread; the child's slave-open then fails and the job exits
  /// 127, or openpty itself fails with a garbage errno. A supervisor never
  /// spawns on a hot path, so serializing the syscalls costs nothing and
  /// removes the race. Draining and reaping stay fully concurrent.
  private static let allocationQueue = DispatchQueue(label: "runstuff.pty.allocation")

  public static func spawn(_ spec: SpawnSpec) throws(SpawnError) -> SpawnedProcess {
    // Resolve what to exec before touching any resource. No shared state,
    // so it stays outside the lock.
    let (path, argv) = try resolve(spec)
    let execPath: String
    let childArgv: [String]
    if let helper = spec.ttyHelperPath {
      execPath = helper
      childArgv = [helper, path] + argv.dropFirst()
    } else {
      execPath = path
      childArgv = argv
    }
    let result: Result<SpawnedProcess, SpawnError> = allocationQueue.sync {
      allocate(spec: spec, execPath: execPath, childArgv: childArgv)
    }
    switch result {
    case .success(let process): return process
    case .failure(let error): throw error
    }
  }

  /// The serialized critical section. Runs under `allocationQueue`.
  private static func allocate(
    spec: SpawnSpec, execPath: String, childArgv: [String]
  ) -> Result<SpawnedProcess, SpawnError> {
    var master: Int32 = -1
    var slave: Int32 = -1
    var ws = winsize(
      ws_row: spec.windowSize.rows, ws_col: spec.windowSize.cols, ws_xpixel: 0, ws_ypixel: 0)
    // Retry a few times: macOS openpty can still fail intermittently under
    // rapid allocation with an unreliable errno.
    var attempts = 0
    while true {
      if openpty(&master, &slave, nil, nil, &ws) == 0 { break }
      let e = errno
      attempts += 1
      if attempts >= 5 { return .failure(.openpty(errno: e)) }
      usleep(2000)
    }
    _ = fcntl(master, F_SETFD, FD_CLOEXEC)
    _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
    // The slave is closed on every path out of this function. The
    // master is closed only on failure.
    defer { close(slave) }

    var slaveNameBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard ttyname_r(slave, &slaveNameBuffer, slaveNameBuffer.count) == 0 else {
      let e = errno
      close(master)
      return .failure(.openpty(errno: e))
    }
    let slavePath = String(
      decoding: slaveNameBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    var slaveStat = stat()
    guard fstat(slave, &slaveStat) == 0 else {
      let e = errno
      close(master)
      return .failure(.openpty(errno: e))
    }

    var attr: posix_spawnattr_t? = nil
    var rc = posix_spawnattr_init(&attr)
    guard rc == 0 else {
      close(master)
      return .failure(.attributes(errno: rc))
    }
    defer { posix_spawnattr_destroy(&attr) }

    // The flags parameter is `short`; the constants import as Int32.
    let flags =
      POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_SETSIGMASK
    rc = posix_spawnattr_setflags(&attr, Int16(flags))
    guard rc == 0 else {
      close(master)
      return .failure(.attributes(errno: rc))
    }
    // Reset every disposition to default and unblock everything, so a
    // supervisor that ignores SIGPIPE or SIGINT does not pass that on.
    var allSignals = sigset_t()
    sigfillset(&allSignals)
    rc = posix_spawnattr_setsigdefault(&attr, &allSignals)
    guard rc == 0 else {
      close(master)
      return .failure(.attributes(errno: rc))
    }
    var noSignals = sigset_t()
    sigemptyset(&noSignals)
    rc = posix_spawnattr_setsigmask(&attr, &noSignals)
    guard rc == 0 else {
      close(master)
      return .failure(.attributes(errno: rc))
    }

    var actions: posix_spawn_file_actions_t? = nil
    rc = posix_spawn_file_actions_init(&actions)
    guard rc == 0 else {
      close(master)
      return .failure(.fileActions(errno: rc))
    }
    defer { posix_spawn_file_actions_destroy(&actions) }

    // Open by path in the child rather than dup2 from the parent's fd.
    // The helper receives this fresh fd as stdin and uses TIOCSCTTY before
    // replacing itself with the real command.
    rc = posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
    if rc == 0 { rc = posix_spawn_file_actions_adddup2(&actions, 0, 1) }
    if rc == 0 { rc = posix_spawn_file_actions_adddup2(&actions, 0, 2) }
    if rc == 0 { rc = posix_spawn_file_actions_addchdir_np(&actions, spec.workingDirectory) }
    guard rc == 0 else {
      close(master)
      return .failure(.fileActions(errno: rc))
    }

    let cArgv = CStringArray(childArgv)
    let cEnvp = CStringArray(spec.environment.map { "\($0.key)=\($0.value)" }.sorted())
    var pid: pid_t = 0
    rc = posix_spawn(&pid, execPath, &actions, &attr, cArgv.pointers, cEnvp.pointers)
    guard rc == 0 else {
      close(master)
      return .failure(.spawn(errno: rc))
    }

    // Parent side of the master: non-blocking so the drain loop can read
    // until EAGAIN, and close-on-exec so no later spawn inherits it.
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    _ = fcntl(master, F_SETFD, FD_CLOEXEC)

    return .success(
      SpawnedProcess(
        master: master, pid: pid, slaveDevice: slaveStat.st_rdev, slavePath: slavePath))
  }

  /// Resolves `argv[0]` against the job's own `PATH`; `posix_spawn` does no
  /// search of its own, and searching the supervisor's `PATH` would be the
  /// wrong environment.
  private static func resolve(_ spec: SpawnSpec) throws(SpawnError) -> (String, [String]) {
    guard let first = spec.argv.first else {
      throw SpawnError.executableNotFound(name: "")
    }
    let jobPath = spec.environment["PATH"] ?? ""
    guard let resolved = SpawnEnvironment.resolveExecutable(first, path: jobPath) else {
      throw SpawnError.executableNotFound(name: first)
    }
    return (resolved, spec.argv)
  }
}

/// Owns a NULL-terminated `char *[]` for the lifetime of a spawn call.
private final class CStringArray {
  let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
  private let count: Int

  init(_ strings: [String]) {
    count = strings.count
    pointers = .allocate(capacity: count + 1)
    for (index, string) in strings.enumerated() {
      pointers[index] = strdup(string)
    }
    pointers[count] = nil
  }

  deinit {
    for index in 0..<count { free(pointers[index]) }
    pointers.deallocate()
  }
}
