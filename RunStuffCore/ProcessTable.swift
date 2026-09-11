import Darwin

/// Read-only process-table queries RunStuff and its fixture harness need: who is in a
/// session, what a pid's group and tty are, and which fds this process holds.
public enum ProcessTable {
  public struct Info: Sendable, Equatable {
    public let pid: pid_t
    public let ppid: pid_t
    public let pgid: pid_t
    /// Controlling tty device, or 0 / NODEV when none.
    public let ttyDevice: dev_t
    /// Foreground process group of the controlling tty.
    public let ttyForegroundGroup: pid_t
    public let isZombie: Bool
    public let startTime: timeval

    public static func == (lhs: Info, rhs: Info) -> Bool {
      lhs.pid == rhs.pid && lhs.startTime.tv_sec == rhs.startTime.tv_sec
        && lhs.startTime.tv_usec == rhs.startTime.tv_usec
    }
  }

  /// `sysctl {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid}`. Includes zombies.
  public static func info(pid: pid_t) -> Info? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var proc = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let rc = sysctl(&mib, UInt32(mib.count), &proc, &size, nil, 0)
    guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
    guard proc.kp_proc.p_pid == pid else { return nil }
    return Info(
      pid: proc.kp_proc.p_pid,
      ppid: proc.kp_eproc.e_ppid,
      pgid: proc.kp_eproc.e_pgid,
      ttyDevice: proc.kp_eproc.e_tdev,
      ttyForegroundGroup: proc.kp_eproc.e_tpgid,
      isZombie: Int32(proc.kp_proc.p_stat) == zombieState,
      startTime: proc.kp_proc.p_un.__p_starttime)
  }

  /// `SZOMB` from sys/proc.h.
  public static let zombieState: Int32 = 5

  /// Every pid in the system, via `proc_listallpids`.
  public static func allPIDs() -> [pid_t] {
    var capacity = 4096
    while true {
      var buffer = [pid_t](repeating: 0, count: capacity)
      let bytes = buffer.withUnsafeMutableBytes { raw in
        proc_listallpids(raw.baseAddress, Int32(raw.count))
      }
      guard bytes > 0 else { return [] }
      let count = Int(bytes)
      if count < capacity {
        return Array(buffer[0..<count]).filter { $0 > 0 }
      }
      capacity *= 2
    }
  }

  /// Live (non-zombie) processes whose session id is `sid`. `getsid` fails
  /// with ESRCH for zombies, so they are excluded.
  public static func sessionMembers(sid: pid_t) -> [pid_t] {
    allPIDs().filter { pid in getsid(pid) == sid }
  }

  /// Live processes whose process group is `pgid`, via
  /// `sysctl {CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid}`. Zombies filtered.
  public static func groupMembers(pgid: pid_t) -> [pid_t] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
    // Leave room for processes that appear between the two calls.
    let capacity = size / MemoryLayout<kinfo_proc>.stride + 16
    var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
    size = capacity * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
    let count = size / MemoryLayout<kinfo_proc>.stride
    return buffer[0..<count]
      .filter { Int32($0.kp_proc.p_stat) != zombieState }
      .map { $0.kp_proc.p_pid }
  }

  public static func listeningPorts(pgid: pid_t) -> [UInt16] {
    Array(Set(groupMembers(pgid: pgid).flatMap(listeningPorts(pid:)))).sorted()
  }

  private static func listeningPorts(pid: pid_t) -> [UInt16] {
    let estimatedBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard estimatedBytes > 0 else { return [] }
    var capacity = Int(estimatedBytes) / MemoryLayout<proc_fdinfo>.stride + 32

    while capacity <= 65_536 {
      var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
      let bufferBytes = descriptors.count * MemoryLayout<proc_fdinfo>.stride
      let returnedBytes = descriptors.withUnsafeMutableBytes { buffer in
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
      }
      guard returnedBytes >= 0 else { return [] }
      if Int(returnedBytes) == bufferBytes {
        capacity *= 2
        continue
      }

      let count = Int(returnedBytes) / MemoryLayout<proc_fdinfo>.stride
      return descriptors.prefix(count).compactMap { descriptor in
        guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return nil }
        var socketInfo = socket_fdinfo()
        let size = MemoryLayout<socket_fdinfo>.size
        let bytes = proc_pidfdinfo(
          pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, Int32(size))
        guard bytes == size,
          socketInfo.psi.soi_kind == SOCKINFO_TCP,
          socketInfo.psi.soi_protocol == IPPROTO_TCP,
          socketInfo.psi.soi_proto.pri_tcp.tcpsi_state == TCPS_LISTEN
        else { return nil }
        return UInt16(
          bigEndian: UInt16(
            truncatingIfNeeded:
              socketInfo.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))
      }
    }
    return []
  }

  /// True if `kill(pid, 0)` says the process exists (zombies count).
  public static func exists(pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }

  /// The calling process's open file descriptors, by probing `F_GETFD`.
  public static func openFileDescriptors() -> [Int32] {
    var limit = rlimit()
    getrlimit(RLIMIT_NOFILE, &limit)
    let upper = Int32(min(limit.rlim_cur, 65536))
    return (0..<upper).filter { fcntl($0, F_GETFD) != -1 }
  }

  /// Binds `127.0.0.1:0`, reads back the port, closes the socket. Small
  /// race with other processes; fine for a fixture.
  public static func freeLoopbackPort() -> UInt16? {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return nil }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { return nil }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let got = withUnsafeMutablePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        getsockname(sock, sa, &len)
      }
    }
    guard got == 0 else { return nil }
    return UInt16(bigEndian: addr.sin_port)
  }

  /// Result of one TCP connect attempt to loopback.
  public enum ConnectResult: Sendable, Equatable {
    case connected
    case refused
    case failed(errno: Int32)
  }

  public static func connectLoopback(port: UInt16) -> ConnectResult {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    guard sock >= 0 else { return .failed(errno: errno) }
    defer { close(sock) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    let rc = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        connect(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if rc == 0 { return .connected }
    let e = errno
    return e == ECONNREFUSED ? .refused : .failed(errno: e)
  }
}
