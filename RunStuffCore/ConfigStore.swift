import Dispatch
import Foundation

public struct RunStuffConfiguration: Codable, Hashable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var jobs: [Job]

  public init(version: Int = Self.currentVersion, jobs: [Job] = []) {
    self.version = version
    self.jobs = jobs
  }
}

public enum ConfigStoreError: Error, Sendable, Equatable {
  case unsupportedVersion(Int)
  case duplicateJobID(UUID)
}

public struct ConfigStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public func load() throws -> RunStuffConfiguration {
    let data = try Data(contentsOf: fileURL)
    let configuration = try JSONDecoder().decode(RunStuffConfiguration.self, from: data)
    guard configuration.version == RunStuffConfiguration.currentVersion else {
      throw ConfigStoreError.unsupportedVersion(configuration.version)
    }
    var jobIDs: Set<UUID> = []
    for job in configuration.jobs where !jobIDs.insert(job.id).inserted {
      throw ConfigStoreError.duplicateJobID(job.id)
    }
    return configuration
  }

  public func loadOrEmpty() throws -> RunStuffConfiguration {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return RunStuffConfiguration()
    }
    return try load()
  }

  public func save(_ configuration: RunStuffConfiguration) throws {
    let fileManager = FileManager.default
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(configuration)
    let temporaryURL = directory.appendingPathComponent(
      ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")

    do {
      try data.write(to: temporaryURL, options: .withoutOverwriting)
      if fileManager.fileExists(atPath: fileURL.path) {
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: fileURL)
      }
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw error
    }
  }
}

public enum ConfigurationWatchEvent: Sendable {
  case loaded(RunStuffConfiguration)
  case invalid(String)
}

/// Watches the configuration's parent directory because atomic replacement
/// renames `config.json` and invalidates a vnode source attached to the file.
public actor ConfigurationWatcher {
  public nonisolated let events: AsyncStream<ConfigurationWatchEvent>

  private let store: ConfigStore
  private let eventContinuation: AsyncStream<ConfigurationWatchEvent>.Continuation
  private var source: DispatchSourceFileSystemObject?
  private var reloadTask: Task<Void, Never>?

  public init(store: ConfigStore) {
    self.store = store
    let (stream, continuation) = AsyncStream.makeStream(
      of: ConfigurationWatchEvent.self, bufferingPolicy: .bufferingNewest(1))
    events = stream
    eventContinuation = continuation
  }

  deinit {
    reloadTask?.cancel()
    source?.cancel()
    eventContinuation.finish()
  }

  public func start() throws {
    guard source == nil else { return }
    let directory = store.fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC)
    guard descriptor >= 0 else {
      throw CocoaError(.fileReadUnknown)
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename],
      queue: DispatchQueue(label: "runstuff.config-watch"))
    source.setEventHandler { [weak self] in
      guard let self else { return }
      Task { await self.scheduleReload() }
    }
    source.setCancelHandler {
      close(descriptor)
    }
    self.source = source
    source.resume()
  }

  public func stop() {
    reloadTask?.cancel()
    reloadTask = nil
    source?.cancel()
    source = nil
  }

  private func scheduleReload() {
    reloadTask?.cancel()
    reloadTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled, let self else { return }
      await self.reload()
    }
  }

  private func reload() {
    do {
      eventContinuation.yield(.loaded(try store.load()))
    } catch {
      eventContinuation.yield(.invalid(String(describing: error)))
    }
  }
}
