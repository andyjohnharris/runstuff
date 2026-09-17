import Darwin
import Foundation

public struct JobSnapshot: Sendable, Equatable {
  public let job: Job
  public let state: RunState
  public let health: Health
  public let pid: pid_t?
  public let startedAt: Date?
  public let startedInstant: ContinuousClock.Instant?
  public let metric: JobMetric?
  public let metricHistory: [JobMetric]
  public let listeningPorts: [UInt16]
  public let diagnostics: CommandDiagnostics?
  public let isAdopted: Bool
  public let isReady: Bool
  public let failure: FailureDiagnostic?
  public let reportedPortConflict: FailureDiagnostic?
}

public enum SupervisorEvent: Sendable {
  case historyChanged
  case jobChanged(JobSnapshot)
  case jobExited(
    jobID: UUID, status: ExitStatus, userInitiated: Bool, failure: FailureDiagnostic?,
    reportedPortConflict: FailureDiagnostic?)
  case jobFailedToStart(jobID: UUID, message: String)
  case signalMatched(jobID: UUID, rule: SignalRule, line: String, shouldNotify: Bool)
  case restartScheduled(jobID: UUID, delay: Duration, attempt: Int)
  case restartLoopExhausted(jobID: UUID, attempts: Int)
  case readyDetected(jobID: UUID, port: UInt16?)
  case waitingForInput(jobID: UUID)
  case sustainedHighCPU(jobID: UUID, cpuPercent: Double)
  case orphaned([RuntimeRecord])
  case configurationReloaded
  case persistenceFailed(String)
}

public enum TerminalFeedEvent: Sendable {
  case reset
  case bytes([UInt8])
}

public enum SupervisorError: Error, Sendable, Equatable {
  case unknownJob(UUID)
  case alreadyRunning(UUID)
  case jobIsRunning(UUID)
  case processDidNotStop(UUID)
  case processDisappeared
  case persistence(String)
  case orphanUnavailable
  case orphanCommandChanged
}

public enum RunStuffMessage {
  public static let commandNotFound =
    "Command not found. Try switching this job to an interactive login shell."
}

public actor Supervisor {
  public nonisolated let events: AsyncStream<SupervisorEvent>

  private struct Entry {
    struct RunCapture {
      let job: Job
      let startedAt: Date
      var rawOutput = Data()
      var outputTruncated = false
      var isRecovered = false
    }

    var job: Job
    var state: RunState = .idle
    var health: Health = .ok
    var runtime: JobRuntime?
    var adopted: RuntimeRecord?
    var output = OutputBuffer()
    var startedAt: Date?
    var startedInstant: ContinuousClock.Instant?
    var stopRequested = false
    var exitStatus: ExitStatus?
    var exitUserInitiated = false
    var portConflict: FailureDiagnostic?
    var failure: FailureDiagnostic?
    var drainSeen = false
    var outputStreamEnded = false
    var metric: JobMetric?
    var metricHistory: [JobMetric] = []
    var listeningPorts: [UInt16] = []
    var diagnostics: CommandDiagnostics?
    var previousReading: (reading: ProcessGroupResourceUsage, instant: ContinuousClock.Instant)?
    var lastSignalAt: Date?
    var lastNotificationByRule: [Int: Date] = [:]
    var restartTimes: [ContinuousClock.Instant] = []
    var restartPending = false
    var restartToken: UUID?
    var readyDetected = false
    var highCPUDetector = SustainedHighCPUDetector()
    var nextOutputOffset: UInt64 = 0
    var runCapture: RunCapture?

    var activePID: pid_t? { runtime?.pid ?? adopted?.pid }
    var activePGID: pid_t? { runtime?.pgid ?? adopted?.pgid }

    var snapshot: JobSnapshot {
      JobSnapshot(
        job: job,
        state: state,
        health: health,
        pid: activePID,
        startedAt: startedAt,
        startedInstant: startedInstant,
        metric: metric,
        metricHistory: metricHistory,
        listeningPorts: listeningPorts,
        diagnostics: diagnostics,
        isAdopted: adopted != nil,
        isReady: readyDetected,
        failure: failure,
        reportedPortConflict: runtime == nil && exitStatus != nil && !exitUserInitiated
          ? portConflict : nil)
    }
  }

  private let configStore: ConfigStore
  private let runtimeRegistry: RuntimeRegistry
  private let ttyHelperPath: String
  private let spoolDirectory: String
  private let historyStore: RunHistoryStore
  private let eventContinuation: AsyncStream<SupervisorEvent>.Continuation
  private var entries: [UUID: Entry]
  private var runtimeRecords: [RuntimeRecord]
  private var history: [JobRunRecord]
  private var metricsTask: Task<Void, Never>?
  private var configurationWatcher: ConfigurationWatcher?
  private var configurationTask: Task<Void, Never>?
  private var foregroundSampling = false
  private var sleeping = false
  private var terminalFeeds: [UUID: [UUID: AsyncStream<TerminalFeedEvent>.Continuation]] = [:]
  private var terminalSessionFeeds: [UUID: [UUID: AsyncStream<TerminalFeedEvent>.Continuation]] =
    [:]
  private var portProbeTasks: [UUID: Task<Void, Never>] = [:]
  private var orphanMonitorTasks: [UUID: Task<Void, Never>] = [:]
  private var promptDetectionTasks: [UUID: Task<Void, Never>] = [:]

  public init(
    configuration: RunStuffConfiguration,
    configStore: ConfigStore,
    runtimeRegistry: RuntimeRegistry,
    ttyHelperPath: String,
    spoolDirectory: String
  ) throws {
    self.configStore = configStore
    self.runtimeRegistry = runtimeRegistry
    self.ttyHelperPath = ttyHelperPath
    self.spoolDirectory = spoolDirectory
    historyStore = RunHistoryStore(configURL: configStore.fileURL)
    let loadedHistory = historyStore.load()
    history = loadedHistory.records
    entries = Dictionary(uniqueKeysWithValues: configuration.jobs.map { ($0.id, Entry(job: $0)) })
    let (stream, continuation) = AsyncStream.makeStream(
      of: SupervisorEvent.self, bufferingPolicy: .bufferingNewest(1024))
    events = stream
    eventContinuation = continuation
    for message in loadedHistory.errors {
      continuation.yield(.persistenceFailed(message))
    }

    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: spoolDirectory), withIntermediateDirectories: true)
    runtimeRecords = try runtimeRegistry.reconcile()
    for record in runtimeRecords where entries[record.jobID] == nil {
      if let job = record.recoveryJob { entries[job.id] = Entry(job: job) }
    }
    if !runtimeRecords.isEmpty {
      continuation.yield(.orphaned(runtimeRecords))
    }
  }

  deinit {
    metricsTask?.cancel()
    configurationTask?.cancel()
    portProbeTasks.values.forEach { $0.cancel() }
    orphanMonitorTasks.values.forEach { $0.cancel() }
    promptDetectionTasks.values.forEach { $0.cancel() }
    for feeds in terminalFeeds.values {
      feeds.values.forEach { $0.finish() }
    }
    for feeds in terminalSessionFeeds.values {
      feeds.values.forEach { $0.finish() }
    }
    eventContinuation.finish()
  }

  public func startWatchingConfiguration() async throws {
    guard configurationWatcher == nil else { return }
    let watcher = ConfigurationWatcher(store: configStore)
    try await watcher.start()
    configurationWatcher = watcher
    configurationTask = Task { [weak self] in
      for await event in watcher.events {
        guard let self else { return }
        await self.received(event)
      }
    }
  }

  public func startSampling() {
    guard metricsTask == nil else { return }
    metricsTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.sampleMetrics()
        let interval = await self.foregroundSampling ? Duration.seconds(2) : .seconds(15)
        try? await Task.sleep(for: interval)
      }
    }
  }

  public func setForegroundSampling(_ foreground: Bool) {
    guard foregroundSampling != foreground else { return }
    foregroundSampling = foreground
    metricsTask?.cancel()
    metricsTask = nil
    startSampling()
  }

  public func setSleeping(_ sleeping: Bool) {
    guard self.sleeping != sleeping else { return }
    self.sleeping = sleeping
    metricsTask?.cancel()
    metricsTask = nil
    if sleeping { return }
    let timestamp = Date()
    for id in entries.keys where entries[id]?.activePID != nil {
      entries[id]?.previousReading = nil
      entries[id]?.metricHistory.append(
        JobMetric(timestamp: timestamp, cpuPercent: 0, residentBytes: 0, isGap: true))
      publish(id)
      if let pid = entries[id]?.activePID {
        startPortProbing(jobID: id, pid: pid)
      }
    }
    startSampling()
  }

  public func snapshots() -> [JobSnapshot] {
    entries.values.map(\.snapshot).sorted {
      $0.job.name.localizedCaseInsensitiveCompare($1.job.name) == .orderedAscending
    }
  }

  public func runHistory() -> [JobRunRecord] {
    history.sorted { $0.endedAt > $1.endedAt }
  }

  public func snapshot(jobID: UUID) -> JobSnapshot? {
    entries[jobID]?.snapshot
  }

  public func output(jobID: UUID) -> [OutputLine] {
    entries[jobID]?.output.lines ?? []
  }

  public func terminalOutput(jobID: UUID) -> AsyncStream<TerminalFeedEvent> {
    makeTerminalOutput(jobID: jobID, finishesOnExit: false)
  }

  public func terminalSessionOutput(jobID: UUID) -> AsyncStream<TerminalFeedEvent> {
    makeTerminalOutput(jobID: jobID, finishesOnExit: true)
  }

  private func makeTerminalOutput(
    jobID: UUID, finishesOnExit: Bool
  ) -> AsyncStream<TerminalFeedEvent> {
    let feedID = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: TerminalFeedEvent.self, bufferingPolicy: .bufferingNewest(128))
    continuation.yield(.reset)
    var replay: [UInt8] = []
    if entries[jobID]?.output.hasEvictedLines == true {
      replay.append(contentsOf: "\r\n… earlier output discarded …\r\n".utf8)
    }
    for line in entries[jobID]?.output.lines ?? [] {
      replay.append(contentsOf: line.raw)
    }
    if let pending = entries[jobID]?.output.pendingBytes, !pending.isEmpty {
      replay.append(contentsOf: pending)
    }
    for start in stride(from: 0, to: replay.count, by: RunStuffSocket.replayChunkBytes) {
      continuation.yield(
        .bytes(
          Array(replay[start..<min(start + RunStuffSocket.replayChunkBytes, replay.count)])))
    }
    if finishesOnExit, entries[jobID]?.activePID == nil {
      continuation.finish()
      return stream
    }
    if finishesOnExit {
      terminalSessionFeeds[jobID, default: [:]][feedID] = continuation
    } else {
      terminalFeeds[jobID, default: [:]][feedID] = continuation
    }
    continuation.onTermination = { [weak self] _ in
      Task {
        await self?.removeTerminalFeed(
          feedID, jobID: jobID, finishesOnExit: finishesOnExit)
      }
    }
    return stream
  }

  public func resolveDiagnostics(jobID: UUID) async {
    guard let job = entries[jobID]?.job else { return }
    let diagnostics = try? await CommandDiagnosticsResolver.resolve(job: job)
    guard entries[jobID]?.job == job else { return }
    entries[jobID]?.diagnostics = diagnostics
    publish(jobID)
  }

  public func add(_ job: Job) throws {
    let previous = entries[job.id]
    entries[job.id] = Entry(job: job)
    do {
      try saveConfiguration()
    } catch {
      entries[job.id] = previous
      throw error
    }
    publish(job.id)
  }

  public func update(_ job: Job) throws {
    guard var entry = entries[job.id] else { throw SupervisorError.unknownJob(job.id) }
    let previous = entry
    entry.job = job
    entry.diagnostics = nil
    entries[job.id] = entry
    do {
      try saveConfiguration()
    } catch {
      entries[job.id] = previous
      throw error
    }
    publish(job.id)
  }

  public func delete(jobID: UUID) throws {
    guard let entry = entries[jobID] else { throw SupervisorError.unknownJob(jobID) }
    guard entry.activePID == nil else { throw SupervisorError.jobIsRunning(jobID) }
    entries[jobID] = nil
    do {
      try saveConfiguration()
    } catch {
      entries[jobID] = entry
      throw error
    }
  }

  public func start(jobID: UUID) async throws {
    guard var entry = entries[jobID] else { throw SupervisorError.unknownJob(jobID) }
    guard entry.activePID == nil else { throw SupervisorError.alreadyRunning(jobID) }
    guard !runtimeRecords.contains(where: { $0.jobID == jobID }) else {
      throw SupervisorError.orphanUnavailable
    }

    entry.state = .starting
    entry.health = .ok
    entry.output = OutputBuffer()
    entry.stopRequested = false
    entry.exitStatus = nil
    entry.exitUserInitiated = false
    entry.portConflict = nil
    entry.failure = nil
    entry.drainSeen = false
    entry.outputStreamEnded = false
    entry.metric = nil
    entry.metricHistory = []
    entry.listeningPorts = []
    entry.previousReading = nil
    entry.lastSignalAt = nil
    entry.lastNotificationByRule = [:]
    entry.restartPending = false
    entry.restartToken = nil
    entry.readyDetected = false
    entry.highCPUDetector = SustainedHighCPUDetector()
    entry.nextOutputOffset = 0
    entry.runCapture = Entry.RunCapture(job: entry.job, startedAt: Date())
    entries[jobID] = entry
    terminalFeeds[jobID]?.values.forEach { $0.yield(.reset) }
    publish(jobID)

    let runtime: JobRuntime
    do {
      let spec = try spawnSpec(for: entry.job)
      runtime = try JobRuntime.start(spec, spoolDirectory: spoolDirectory)
    } catch let error as SpawnError {
      let message =
        error.errnoValue == ENOENT
        ? RunStuffMessage.commandNotFound : String(describing: error)
      setFailedToStart(jobID: jobID, message: message)
      archiveFailedStart(jobID: jobID, message: message)
      return
    } catch {
      setFailedToStart(jobID: jobID, message: String(describing: error))
      archiveFailedStart(jobID: jobID, message: String(describing: error))
      return
    }

    if let process = ProcessTable.info(pid: runtime.pid) {
      let record = RuntimeRecord(job: entry.job, runtime: runtime, process: process)
      do {
        runtimeRecords.removeAll { $0.jobID == jobID }
        runtimeRecords.append(record)
        try runtimeRegistry.save(runtimeRecords)
      } catch {
        _ = await runtime.stop(grace: .zero)
        await runtime.close()
        setFailedToStart(jobID: jobID, message: "Could not persist runtime state: \(error)")
        archiveFailedStart(jobID: jobID, message: "Could not persist runtime state: \(error)")
        throw SupervisorError.persistence(String(describing: error))
      }
    } else if await runtime.exitStatus == nil {
      _ = await runtime.stop(grace: .zero)
      await runtime.close()
      setFailedToStart(
        jobID: jobID, message: "Started process disappeared before it could be supervised")
      archiveFailedStart(
        jobID: jobID, message: "Started process disappeared before it could be supervised")
      throw SupervisorError.processDisappeared
    }

    entry = entries[jobID] ?? entry
    entry.runtime = runtime
    entry.adopted = nil
    entry.state = .running
    entry.startedAt = Date()
    entry.startedInstant = .now
    entries[jobID] = entry
    publish(jobID)

    let output = await runtime.attach(
      discardReplayAfterAttach: true, bufferingPolicy: .bufferingNewest(128))
    let pid = runtime.pid
    Task { [weak self] in
      for await chunk in output {
        await self?.received(chunk, jobID: jobID, pid: pid)
      }
      await self?.outputEnded(jobID: jobID, pid: pid)
    }
    Task { [weak self] in
      for await event in runtime.events {
        await self?.received(event, jobID: jobID, pid: pid)
      }
    }
    sampleMetrics()
    startPortProbing(jobID: jobID, pid: pid)
  }

  /// Starts an editor test run without adding the job to configuration.
  public func startPreview(_ job: Job) async throws -> JobRuntime {
    let runtime = try JobRuntime.start(try spawnSpec(for: job), spoolDirectory: spoolDirectory)
    guard let process = ProcessTable.info(pid: runtime.pid) else {
      _ = await runtime.stop(grace: .zero)
      await runtime.close()
      throw SupervisorError.processDisappeared
    }
    runtimeRecords.append(
      RuntimeRecord(job: job, runtime: runtime, process: process, includeRecoveryJob: true))
    do {
      try runtimeRegistry.save(runtimeRecords)
    } catch {
      runtimeRecords.removeAll { $0.pid == runtime.pid }
      _ = await runtime.stop(grace: .zero)
      await runtime.close()
      throw SupervisorError.persistence(String(describing: error))
    }
    return runtime
  }

  public func finishPreview(_ runtime: JobRuntime) throws {
    runtimeRecords.removeAll { $0.pid == runtime.pid }
    try runtimeRegistry.save(runtimeRecords)
  }

  public func stop(jobID: UUID, grace: Duration = .seconds(5)) async throws {
    guard var entry = entries[jobID] else { throw SupervisorError.unknownJob(jobID) }
    guard entry.activePID != nil else { return }
    entry.stopRequested = true
    entry.state = .stopping
    entries[jobID] = entry
    publish(jobID)
    if let runtime = entry.runtime {
      let report = await runtime.stop(grace: grace)
      guard report.leaderExit != nil, report.remaining.isEmpty else {
        throw SupervisorError.processDidNotStop(jobID)
      }
      try await waitForCompletion(jobID: jobID, pid: runtime.pid)
    } else if let record = entry.adopted {
      try await stopOrphanSession(record, grace: grace)
      finishAdopted(jobID: jobID, record: record)
    }
  }

  @discardableResult
  public func stopAll(grace: Duration = .seconds(5)) async -> [UUID] {
    let running = entries.compactMap { id, entry -> (UUID, JobRuntime)? in
      guard let runtime = entry.runtime else { return nil }
      return (id, runtime)
    }
    for (id, _) in running {
      entries[id]?.stopRequested = true
      entries[id]?.state = .stopping
      publish(id)
    }
    var failures = await withTaskGroup(of: (UUID, Bool).self, returning: [UUID].self) { group in
      for (id, runtime) in running {
        group.addTask {
          let report = await runtime.stop(grace: grace)
          return (id, report.leaderExit != nil && report.remaining.isEmpty)
        }
      }
      var failed: [UUID] = []
      for await (id, stopped) in group where !stopped { failed.append(id) }
      return failed
    }
    for (id, runtime) in running where !failures.contains(id) {
      do {
        try await waitForCompletion(jobID: id, pid: runtime.pid)
      } catch {
        failures.append(id)
      }
    }
    let adoptedIDs = entries.compactMap { id, entry in entry.adopted == nil ? nil : id }
    for id in adoptedIDs {
      do {
        try await stop(jobID: id, grace: grace)
      } catch {
        failures.append(id)
      }
    }
    return failures
  }

  public func restart(jobID: UUID, grace: Duration = .seconds(5)) async throws {
    try await stop(jobID: jobID, grace: grace)
    try await start(jobID: jobID)
  }

  private func waitForCompletion(jobID: UUID, pid: pid_t) async throws {
    // Stop All and Quit must not exit the app before final output is archived.
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while entries[jobID]?.runtime?.pid == pid {
      guard ContinuousClock.now < deadline else {
        throw SupervisorError.processDidNotStop(jobID)
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  public func write(_ bytes: [UInt8], jobID: UUID) async throws {
    guard let runtime = entries[jobID]?.runtime else { throw SupervisorError.unknownJob(jobID) }
    try await runtime.write(bytes)
  }

  public func resize(_ size: WindowSize, jobID: UUID) async throws {
    guard let runtime = entries[jobID]?.runtime else { throw SupervisorError.unknownJob(jobID) }
    try await runtime.resize(size)
  }

  public func adoptOrphan(jobID: UUID) throws {
    guard let record = runtimeRecords.first(where: { $0.jobID == jobID }),
      record.matchesCurrentProcess(),
      var entry = entries[jobID]
    else { throw SupervisorError.orphanUnavailable }
    guard RuntimeRecord.fingerprint(entry.job.command) == record.commandFingerprint else {
      throw SupervisorError.orphanCommandChanged
    }
    guard entry.activePID == nil else { throw SupervisorError.alreadyRunning(jobID) }
    entry.adopted = record
    entry.state = .running
    entry.health = .ok
    entry.stopRequested = false
    entry.exitStatus = nil
    entry.failure = nil
    entry.portConflict = nil
    entry.startedAt = nil
    entry.startedInstant = nil
    entry.metric = nil
    entry.metricHistory = []
    entry.runCapture = Entry.RunCapture(
      job: entry.job,
      startedAt: Date(
        timeIntervalSince1970: Double(record.startSeconds)
          + Double(record.startMicroseconds) / 1_000_000),
      isRecovered: true)
    entry.listeningPorts = ProcessTable.listeningPorts(pgid: record.pgid)
    entries[jobID] = entry
    publish(jobID)
    startPortProbing(jobID: jobID, pid: record.pid)
    monitorOrphan(jobID: jobID, record: record)
  }

  public func stopOrphan(jobID: UUID, grace: Duration = .seconds(5)) async throws {
    guard let record = runtimeRecords.first(where: { $0.jobID == jobID }) else {
      throw SupervisorError.orphanUnavailable
    }
    try await stopOrphanSession(record, grace: grace)
    finishAdopted(jobID: jobID, record: record)
  }

  public func ignoreOrphan(jobID: UUID) throws {
    guard runtimeRecords.contains(where: { $0.jobID == jobID }) else {
      throw SupervisorError.orphanUnavailable
    }
    runtimeRecords.removeAll { $0.jobID == jobID }
    try runtimeRegistry.save(runtimeRecords)
  }

  public func acknowledgeWarning(jobID: UUID) {
    guard case .warning = entries[jobID]?.health else { return }
    entries[jobID]?.health = .ok
    publish(jobID)
  }

  private func received(_ event: ConfigurationWatchEvent) {
    switch event {
    case .loaded(let configuration):
      apply(configuration)
    case .invalid(let message):
      eventContinuation.yield(.persistenceFailed(message))
    }
  }

  private func apply(_ configuration: RunStuffConfiguration) {
    let configuredIDs = Set(configuration.jobs.map(\.id))
    for job in configuration.jobs {
      if var entry = entries[job.id] {
        entry.job = job
        entries[job.id] = entry
      } else {
        entries[job.id] = Entry(job: job)
      }
      publish(job.id)
    }
    for id in Array(entries.keys) where !configuredIDs.contains(id) && entries[id]?.activePID == nil
    {
      entries[id] = nil
    }
    eventContinuation.yield(.configurationReloaded)
  }

  private func received(_ chunk: OutputChunk, jobID: UUID, pid: pid_t) {
    guard var entry = entries[jobID], entry.runtime?.pid == pid else { return }
    let previousHealth = entry.health
    let wasReady = entry.readyDetected
    if chunk.offset != entry.nextOutputOffset {
      entry.output.discardEarlierOutput()
    }
    entry.nextOutputOffset = chunk.offset + UInt64(chunk.bytes.count)
    promptDetectionTasks[jobID]?.cancel()
    promptDetectionTasks[jobID] = nil
    if case .warning(let reason, _) = entry.health, reason == "Waiting for input" {
      entry.health = .ok
    }
    let oldSequence = entry.output.lines.last?.sequence
    entry.output.append(chunk.bytes, at: Date())
    let newLines = entry.output.lines.filter { line in
      guard let oldSequence else { return true }
      return line.sequence > oldSequence
    }
    for line in newLines {
      entry.portConflict = entry.portConflict ?? FailureDiagnostic.portConflict(in: line.stripped)
      applySignalRules(to: line, entry: &entry, jobID: jobID)
      applyOutputReadyRule(to: line, entry: &entry, jobID: jobID)
    }
    schedulePromptDetection(entry: &entry, jobID: jobID, pid: pid)
    entries[jobID] = entry
    terminalFeeds[jobID]?.values.forEach { $0.yield(.bytes(chunk.bytes)) }
    terminalSessionFeeds[jobID]?.values.forEach { $0.yield(.bytes(chunk.bytes)) }
    if entry.health != previousHealth || entry.readyDetected != wasReady { publish(jobID) }
  }

  private func schedulePromptDetection(entry: inout Entry, jobID: UUID, pid: pid_t) {
    guard entry.job.notifyWhenWaitingForInput,
      isPromptLike(entry.output.pendingStrippedText)
    else { return }
    promptDetectionTasks[jobID] = Task { [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled, let self else { return }
      await self.detectWaitingForInput(jobID: jobID, pid: pid)
    }
  }

  private func detectWaitingForInput(jobID: UUID, pid: pid_t) {
    promptDetectionTasks[jobID] = nil
    guard var entry = entries[jobID], entry.runtime?.pid == pid,
      entry.job.notifyWhenWaitingForInput,
      isPromptLike(entry.output.pendingStrippedText)
    else { return }
    entry.health = .warning(reason: "Waiting for input", since: Date())
    entries[jobID] = entry
    publish(jobID)
    eventContinuation.yield(.waitingForInput(jobID: jobID))
  }

  private func removeTerminalFeed(_ feedID: UUID, jobID: UUID, finishesOnExit: Bool) {
    if finishesOnExit {
      terminalSessionFeeds[jobID]?[feedID] = nil
      if terminalSessionFeeds[jobID]?.isEmpty == true {
        terminalSessionFeeds[jobID] = nil
      }
    } else {
      terminalFeeds[jobID]?[feedID] = nil
      if terminalFeeds[jobID]?.isEmpty == true {
        terminalFeeds[jobID] = nil
      }
    }
  }

  private func applySignalRules(to line: OutputLine, entry: inout Entry, jobID: UUID) {
    for (index, rule) in entry.job.signals.enumerated() where rule.matches(line.stripped) {
      let now = Date()
      entry.lastSignalAt = now
      switch rule.severity {
      case .info:
        break
      case .warning:
        if case .error = entry.health { break }
        entry.health = .warning(
          reason: FailureDiagnostic.matchedLine(line.stripped).summary, since: now)
      case .error:
        entry.failure = entry.failure ?? FailureDiagnostic.matchedLine(line.stripped)
        entry.health = .error(reason: entry.failure?.summary ?? rule.pattern, since: now)
      }
      let lastNotification = entry.lastNotificationByRule[index] ?? .distantPast
      let shouldNotify = rule.notify && now.timeIntervalSince(lastNotification) >= 60
      if shouldNotify { entry.lastNotificationByRule[index] = now }
      eventContinuation.yield(
        .signalMatched(
          jobID: jobID, rule: rule, line: line.stripped, shouldNotify: shouldNotify))
    }
  }

  private func received(_ event: RuntimeEvent, jobID: UUID, pid: pid_t) async {
    guard var entry = entries[jobID], entry.runtime?.pid == pid else { return }
    switch event {
    case .exited(let status, _):
      entry.exitStatus = status
      entry.exitUserInitiated = entry.stopRequested
      switch status {
      case .exited(let code) where code == 127 && !entry.stopRequested:
        entry.state = .failedToStart(RunStuffMessage.commandNotFound)
        entry.health = .error(reason: "Command not found", since: Date())
        entry.failure = FailureDiagnostic(
          summary: RunStuffMessage.commandNotFound,
          evidence: RunStuffMessage.commandNotFound, conflictingPort: nil)
        entry.restartPending = entry.job.restartOnCrash
      case .exited(let code):
        entry.state = .exited(code: code)
        if code != 0 && !entry.stopRequested {
          entry.health = .error(reason: "Exited with code \(code)", since: Date())
          entry.restartPending = entry.job.restartOnCrash
        }
      case .signalled(let signal, _):
        entry.state = .signalled(signal)
        if !entry.stopRequested {
          entry.health = .error(reason: "Crashed (\(signalName(signal)))", since: Date())
          entry.restartPending = entry.job.restartOnCrash
        }
      }
    case .drainEnded:
      entry.drainSeen = true
    }
    entries[jobID] = entry
    publish(jobID)
    await completeIfFinished(jobID: jobID, pid: pid)
  }

  private func outputEnded(jobID: UUID, pid: pid_t) async {
    guard var entry = entries[jobID], entry.runtime?.pid == pid else { return }
    let lastSequence = entry.output.lines.last?.sequence
    entry.output.finish(at: Date())
    if let line = entry.output.lines.last, line.sequence != lastSequence {
      entry.portConflict = entry.portConflict ?? FailureDiagnostic.portConflict(in: line.stripped)
      applySignalRules(to: line, entry: &entry, jobID: jobID)
    }
    entry.outputStreamEnded = true
    entries[jobID] = entry
    await completeIfFinished(jobID: jobID, pid: pid)
  }

  private func completeIfFinished(jobID: UUID, pid: pid_t) async {
    guard let pending = entries[jobID], pending.runtime?.pid == pid,
      let status = pending.exitStatus, pending.drainSeen, pending.outputStreamEnded,
      let runtime = pending.runtime
    else { return }
    let output = await runtime.historyOutput()
    guard var entry = entries[jobID], entry.runtime?.pid == pid else { return }
    entry.runCapture?.rawOutput = output.data
    entry.runCapture?.outputTruncated = output.truncated
    if !entry.exitUserInitiated {
      if status != .exited(code: 0) { entry.failure = entry.portConflict ?? entry.failure }
      if let failure = entry.failure {
        entry.health = .error(reason: failure.summary, since: Date())
      }
    }
    archive(
      entry: &entry,
      outcome: outcome(
        status: status, stopped: entry.exitUserInitiated,
        failedToStart: ifFailedToStart(entry.state)))
    entry.runtime = nil
    entry.previousReading = nil
    entry.listeningPorts = []
    entries[jobID] = entry
    portProbeTasks[jobID]?.cancel()
    portProbeTasks[jobID] = nil
    promptDetectionTasks[jobID]?.cancel()
    promptDetectionTasks[jobID] = nil
    terminalSessionFeeds[jobID]?.values.forEach { $0.finish() }
    terminalSessionFeeds[jobID] = nil
    runtimeRecords.removeAll { $0.jobID == jobID && $0.pid == pid }
    do {
      try runtimeRegistry.save(runtimeRecords)
    } catch {
      eventContinuation.yield(.persistenceFailed(String(describing: error)))
    }
    publish(jobID)
    eventContinuation.yield(
      .jobExited(
        jobID: jobID, status: status, userInitiated: entry.exitUserInitiated,
        failure: entry.failure,
        reportedPortConflict: entry.portConflict
      ))
    await runtime.close()
    scheduleCrashRestartIfNeeded(jobID: jobID)
  }

  private func scheduleCrashRestartIfNeeded(jobID: UUID) {
    guard var entry = entries[jobID], entry.restartPending else { return }
    entry.restartPending = false
    let now = ContinuousClock.now
    entry.restartTimes.removeAll { now - $0 >= .seconds(60) }
    guard entry.restartTimes.count < entry.job.maxRestarts else {
      entry.health = .error(
        reason: "Restart loop: gave up after \(entry.job.maxRestarts) restarts",
        since: Date())
      entries[jobID] = entry
      publish(jobID)
      eventContinuation.yield(
        .restartLoopExhausted(jobID: jobID, attempts: entry.job.maxRestarts))
      return
    }
    let attempt = entry.restartTimes.count + 1
    let delay = Duration.seconds(1 << min(entry.restartTimes.count, 2))
    let token = UUID()
    entry.restartTimes.append(now)
    entry.restartToken = token
    entry.health = .warning(reason: "Restarting after crash", since: Date())
    entries[jobID] = entry
    eventContinuation.yield(.restartScheduled(jobID: jobID, delay: delay, attempt: attempt))
    publish(jobID)
    Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      await self.restartAfterCrash(jobID: jobID, token: token)
    }
  }

  private func restartAfterCrash(jobID: UUID, token: UUID) async {
    guard let entry = entries[jobID], entry.runtime == nil, entry.job.restartOnCrash,
      entry.restartToken == token
    else { return }
    do {
      try await start(jobID: jobID)
    } catch {
      setFailedToStart(jobID: jobID, message: String(describing: error))
    }
  }

  private func setFailedToStart(jobID: UUID, message: String) {
    entries[jobID]?.state = .failedToStart(message)
    entries[jobID]?.health = .error(reason: message, since: Date())
    eventContinuation.yield(.jobFailedToStart(jobID: jobID, message: message))
    publish(jobID)
  }

  private func ifFailedToStart(_ state: RunState) -> Bool {
    if case .failedToStart = state { return true }
    return false
  }

  private func outcome(status: ExitStatus, stopped: Bool, failedToStart: Bool) -> String {
    if stopped { return "Stopped" }
    if failedToStart { return "Failed to start" }
    switch status {
    case .exited(let code): return "Exit \(code)"
    case .signalled(let signal, _): return "Signal \(signal)"
    }
  }

  private func archiveFailedStart(jobID: UUID, message: String) {
    guard var entry = entries[jobID], entry.runCapture != nil else { return }
    let diagnostic = FailureDiagnostic(summary: message, evidence: message, conflictingPort: nil)
    entry.failure = diagnostic
    archive(entry: &entry, outcome: "Failed to start")
    entries[jobID] = entry
  }

  private func archive(entry: inout Entry, outcome: String) {
    guard let capture = entry.runCapture else { return }
    entry.runCapture = nil
    let failure = entry.failure ?? entry.portConflict
    let diagnostics = entry.job == capture.job ? entry.diagnostics : nil
    let record = JobRunRecord(
      jobID: capture.job.id, name: capture.job.name, command: capture.job.command,
      workingDirectory: capture.job.workingDirectory.path,
      shellMode: capture.job.shellMode.rawValue, startedAt: capture.startedAt, endedAt: Date(),
      outcome: outcome, failureSummary: failure?.summary, failureEvidence: failure?.evidence,
      rawOutput: capture.rawOutput,
      outputTruncated: capture.outputTruncated, isRecovered: capture.isRecovered,
      conflictingPort: failure?.conflictingPort, exitStatus: entry.exitStatus?.description,
      resolvedExecutable: diagnostics?.resolvedExecutable,
      executableVersion: diagnostics?.executableVersion, metrics: entry.metricHistory)
    history.append(record)
    eventContinuation.yield(.historyChanged)
    do {
      try historyStore.save(record)
    } catch {
      eventContinuation.yield(.persistenceFailed("Could not save run history: \(error)"))
    }
  }

  private func sampleMetrics() {
    guard !sleeping else { return }
    let now = ContinuousClock.now
    let timestamp = Date()
    for id in entries.keys {
      guard var entry = entries[id], let pgid = entry.activePGID else { continue }
      let reading = MetricsSampler.readProcessGroup(pgid)
      let cpuPercent: Double
      if let previous = entry.previousReading {
        let elapsed = (now - previous.instant).seconds
        let delta =
          reading.cpuNanoseconds >= previous.reading.cpuNanoseconds
          ? reading.cpuNanoseconds - previous.reading.cpuNanoseconds : 0
        let used = Double(delta) / 1e9
        cpuPercent = elapsed > 0 ? used / elapsed * 100 : 0
      } else {
        cpuPercent = 0
      }
      entry.metric = JobMetric(
        timestamp: timestamp, cpuPercent: cpuPercent, residentBytes: reading.residentBytes)
      if let metric = entry.metric {
        entry.metricHistory.append(metric)
        if entry.metricHistory.count > 10_000 {
          entry.metricHistory.removeFirst(entry.metricHistory.count - 10_000)
        }
      }
      entry.listeningPorts = ProcessTable.listeningPorts(pgid: pgid)
      applyPortReadyRule(entry: &entry, jobID: id)
      if entry.job.notifyOnHighCPU,
        entry.highCPUDetector.observe(cpuPercent: cpuPercent, at: now)
      {
        entry.health = .warning(reason: "Sustained high CPU", since: timestamp)
        eventContinuation.yield(.sustainedHighCPU(jobID: id, cpuPercent: cpuPercent))
      } else if case .warning(let reason, _) = entry.health,
        reason == "Sustained high CPU", cpuPercent <= 80
      {
        entry.health = .ok
      }
      entry.previousReading = (reading, now)
      if case .warning = entry.health,
        let lastSignalAt = entry.lastSignalAt,
        timestamp.timeIntervalSince(lastSignalAt) >= 600
      {
        entry.health = .ok
      }
      entries[id] = entry
      publish(id)
    }
  }

  private func startPortProbing(jobID: UUID, pid: pid_t) {
    portProbeTasks[jobID]?.cancel()
    portProbeTasks[jobID] = Task { [weak self] in
      for _ in 0..<15 {
        guard !Task.isCancelled, let self else { return }
        await self.probePorts(jobID: jobID, pid: pid)
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }

  private func probePorts(jobID: UUID, pid: pid_t) {
    guard var entry = entries[jobID], entry.activePID == pid, let pgid = entry.activePGID else {
      return
    }
    let ports = ProcessTable.listeningPorts(pgid: pgid)
    guard ports != entry.listeningPorts else { return }
    entry.listeningPorts = ports
    applyPortReadyRule(entry: &entry, jobID: jobID)
    entries[jobID] = entry
    publish(jobID)
  }

  private func monitorOrphan(jobID: UUID, record: RuntimeRecord) {
    orphanMonitorTasks[jobID]?.cancel()
    orphanMonitorTasks[jobID] = Task { [weak self] in
      while !Task.isCancelled && !ProcessTable.sessionMembers(sid: record.sid).isEmpty {
        try? await Task.sleep(for: .seconds(1))
      }
      guard !Task.isCancelled, let self else { return }
      await self.finishAdopted(jobID: jobID, record: record)
    }
  }

  private func stopOrphanSession(_ record: RuntimeRecord, grace: Duration) async throws {
    guard record.matchesCurrentProcess(), ProcessTable.info(pid: record.pid)?.pgid == record.pgid
    else { throw SupervisorError.orphanUnavailable }
    guard record.sid > 0 else { return }

    var knownMembers = Dictionary(
      uniqueKeysWithValues: ProcessTable.sessionMembers(sid: record.sid).compactMap { pid in
        ProcessTable.info(pid: pid).map { (pid, $0) }
      })
    if record.pgid > 0 { _ = kill(-record.pgid, SIGTERM) }
    for (pid, identity) in knownMembers
    where ProcessTable.info(pid: pid) == identity && getsid(pid) == record.sid {
      _ = kill(pid, SIGTERM)
    }
    let deadline = ContinuousClock.now.advanced(by: grace)
    while ContinuousClock.now < deadline && !ProcessTable.sessionMembers(sid: record.sid).isEmpty {
      try? await Task.sleep(for: .milliseconds(25))
    }

    let killDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while ContinuousClock.now < killDeadline {
      let members = ProcessTable.sessionMembers(sid: record.sid)
      if members.isEmpty { return }

      let hasKnownMember = members.contains { pid in
        knownMembers[pid].map { ProcessTable.info(pid: pid) == $0 } ?? false
      }
      guard hasKnownMember else { throw SupervisorError.processDidNotStop(record.jobID) }

      for pid in members {
        if let identity = ProcessTable.info(pid: pid) { knownMembers[pid] = identity }
      }
      for (pid, identity) in knownMembers
      where ProcessTable.info(pid: pid) == identity && getsid(pid) == record.sid {
        _ = kill(pid, SIGKILL)
      }
      try? await Task.sleep(for: .milliseconds(25))
    }
    throw SupervisorError.processDidNotStop(record.jobID)
  }

  private func finishAdopted(jobID: UUID, record: RuntimeRecord) {
    orphanMonitorTasks[jobID]?.cancel()
    orphanMonitorTasks[jobID] = nil
    portProbeTasks[jobID]?.cancel()
    portProbeTasks[jobID] = nil
    if var entry = entries[jobID], entry.adopted == record {
      archive(entry: &entry, outcome: entry.stopRequested ? "Stopped" : "Outcome unavailable")
      entry.adopted = nil
      entry.state = .idle
      entry.metric = nil
      entry.listeningPorts = []
      entries[jobID] = entry
      publish(jobID)
    }
    runtimeRecords.removeAll { $0 == record }
    do {
      try runtimeRegistry.save(runtimeRecords)
    } catch {
      eventContinuation.yield(.persistenceFailed(String(describing: error)))
    }
  }

  private func applyOutputReadyRule(to line: OutputLine, entry: inout Entry, jobID: UUID) {
    guard !entry.readyDetected,
      case .outputPattern(let pattern) = entry.job.readyRule,
      line.stripped.localizedCaseInsensitiveContains(pattern)
    else { return }
    entry.readyDetected = true
    eventContinuation.yield(.readyDetected(jobID: jobID, port: entry.listeningPorts.first))
  }

  private func applyPortReadyRule(entry: inout Entry, jobID: UUID) {
    guard !entry.readyDetected,
      case .port(let port) = entry.job.readyRule,
      let expected = UInt16(exactly: port),
      entry.listeningPorts.contains(expected)
    else { return }
    entry.readyDetected = true
    eventContinuation.yield(.readyDetected(jobID: jobID, port: expected))
  }

  private func saveConfiguration() throws {
    do {
      try configStore.save(RunStuffConfiguration(jobs: entries.values.map(\.job)))
    } catch {
      throw SupervisorError.persistence(String(describing: error))
    }
  }

  private func spawnSpec(for job: Job) throws -> SpawnSpec {
    let jobEnvironment = try KeychainEnvironment.resolve(job.env)
    let environment = SpawnEnvironment.layered(
      SpawnEnvironment.launchdLikeBase(),
      SpawnEnvironment.jobDefaults(jobID: job.id.uuidString, windowSize: .default),
      jobEnvironment)
    let shell = environment["SHELL"] ?? "/bin/zsh"
    return SpawnSpec(
      argv: job.shellMode.argv(commandLine: job.command, shell: shell),
      workingDirectory: job.workingDirectory.path,
      environment: environment,
      ttyHelperPath: ttyHelperPath)
  }

  private func publish(_ jobID: UUID) {
    guard let snapshot = entries[jobID]?.snapshot else { return }
    eventContinuation.yield(.jobChanged(snapshot))
  }
}

struct SustainedHighCPUDetector {
  private var highSince: ContinuousClock.Instant?
  private var notified = false

  mutating func observe(
    cpuPercent: Double,
    at now: ContinuousClock.Instant,
    duration: Duration = .seconds(120)
  ) -> Bool {
    guard !notified else { return false }
    guard cpuPercent > 80 else {
      highSince = nil
      return false
    }
    guard let highSince else {
      self.highSince = now
      return false
    }
    guard now - highSince >= duration else { return false }
    notified = true
    return true
  }
}

func isPromptLike(_ text: String) -> Bool {
  guard !text.isEmpty else { return false }
  return text.hasSuffix("? ") || text.hasSuffix(": ") || text.hasSuffix("> ")
    || text.lowercased().hasSuffix("[y/n] ")
}

extension SignalRule {
  fileprivate func matches(_ text: String) -> Bool {
    let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
    if isRegex {
      var regexOptions: NSRegularExpression.Options = []
      if !caseSensitive { regexOptions.insert(.caseInsensitive) }
      guard let expression = try? NSRegularExpression(pattern: pattern, options: regexOptions)
      else {
        return false
      }
      return expression.firstMatch(
        in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    return text.range(of: pattern, options: options) != nil
  }
}
