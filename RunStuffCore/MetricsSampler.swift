import Darwin
import Foundation

public struct JobMetric: Codable, Sendable, Equatable {
  public let timestamp: Date
  public let cpuPercent: Double
  public let residentBytes: UInt64
  public let isGap: Bool

  public init(timestamp: Date, cpuPercent: Double, residentBytes: UInt64, isGap: Bool = false) {
    self.timestamp = timestamp
    self.cpuPercent = cpuPercent
    self.residentBytes = residentBytes
    self.isGap = isGap
  }
}

public struct ProcessGroupResourceUsage: Sendable, Equatable {
  public let processCount: Int
  public let cpuNanoseconds: UInt64
  public let residentBytes: UInt64
}

public enum MetricsSampler {
  public static func readProcessGroup(_ pgid: pid_t) -> ProcessGroupResourceUsage {
    ProcessTable.groupMembers(pgid: pgid).reduce(
      into: ProcessGroupResourceUsage(processCount: 0, cpuNanoseconds: 0, residentBytes: 0)
    ) { total, pid in
      guard let reading = read(pid: pid) else { return }
      total = ProcessGroupResourceUsage(
        processCount: total.processCount + 1,
        cpuNanoseconds: total.cpuNanoseconds &+ reading.cpuNanoseconds,
        residentBytes: total.residentBytes &+ reading.residentBytes)
    }
  }

  private static func read(pid: pid_t) -> ProcessGroupResourceUsage? {
    var usage = rusage_info_v4()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
      }
    }
    guard result == 0 else { return nil }
    return ProcessGroupResourceUsage(
      processCount: 1,
      cpuNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
      residentBytes: usage.ri_resident_size)
  }
}
