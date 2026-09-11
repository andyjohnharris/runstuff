import Foundation
import RunStuffCore

private enum AttachServerError: Error, CustomStringConvertible {
  case ambiguous(String)
  case notFound

  var description: String {
    switch self {
    case .ambiguous(let name):
      "More than one Stuff is named ‘\(name)’; use its UUID instead"
    case .notFound:
      "Stuff not found"
    }
  }
}

/// App-side owner of the local attach socket. Blocking socket calls stay on
/// detached worker tasks; all process state remains isolated to Supervisor.
@MainActor
final class AttachServer {
  private nonisolated let supervisor: Supervisor
  private let path: String
  private var listener: UnixSocketListener?

  init(supervisor: Supervisor, path: String = RunStuffSocket.defaultPath) {
    self.supervisor = supervisor
    self.path = path
  }

  deinit {
    listener?.close()
  }

  func start() throws {
    let listener = try UnixSocketListener(path: path)
    self.listener = listener
    Task.detached(priority: .userInitiated) { [weak self] in
      while true {
        do {
          let connection = try listener.accept()
          guard let self else {
            connection.close()
            return
          }
          Task.detached(priority: .userInitiated) { [weak self] in
            await self?.handle(connection)
          }
        } catch {
          return
        }
      }
    }
  }

  func stop() {
    let listener = self.listener
    self.listener = nil
    listener?.close()
  }

  private nonisolated func handle(_ connection: UnixSocketConnection) async {
    do {
      guard let line = try connection.readLine() else { return }
      let request = try JSONDecoder().decode(AttachRequest.self, from: line)
      switch request.command {
      case .list:
        let jobs = await supervisor.snapshots().map {
          AttachJob(id: $0.job.id, name: $0.job.name, state: String(describing: $0.state))
        }
        try connection.writeLine(AttachResponse(ok: true, jobs: jobs))
      case .start:
        let snapshot = try await resolve(request.job)
        try await supervisor.start(jobID: snapshot.job.id)
        let updated = await supervisor.snapshot(jobID: snapshot.job.id)
        if case .failedToStart(let message) = updated?.state {
          try connection.writeLine(AttachResponse(ok: false, message: message))
        } else {
          try connection.writeLine(
            AttachResponse(ok: true, message: "Started \(snapshot.job.name)"))
        }
      case .stop:
        let snapshot = try await resolve(request.job)
        try await supervisor.stop(jobID: snapshot.job.id)
        try connection.writeLine(AttachResponse(ok: true, message: "Stopped \(snapshot.job.name)"))
      case .attach:
        let snapshot = try await resolve(request.job)
        do {
          try await attach(snapshot, connection: connection)
        } catch {
          connection.close()
          return
        }
      }
    } catch {
      try? connection.writeLine(AttachResponse(ok: false, message: String(describing: error)))
    }
    connection.close()
  }

  private nonisolated func resolve(_ identifier: String?) async throws -> JobSnapshot {
    guard let identifier, !identifier.isEmpty else { throw AttachServerError.notFound }
    let snapshots = await supervisor.snapshots()
    if let id = UUID(uuidString: identifier),
      let snapshot = snapshots.first(where: { $0.job.id == id })
    {
      return snapshot
    }
    let matches = snapshots.filter {
      $0.job.name.compare(identifier, options: .caseInsensitive) == .orderedSame
    }
    guard !matches.isEmpty else { throw AttachServerError.notFound }
    guard matches.count == 1 else { throw AttachServerError.ambiguous(identifier) }
    return matches[0]
  }

  private nonisolated func attach(
    _ snapshot: JobSnapshot, connection: UnixSocketConnection
  ) async throws {
    guard !snapshot.isAdopted else {
      try connection.writeLine(
        AttachResponse(
          ok: false,
          message: "Output is unavailable for Stuff adopted after RunStuff restarted"))
      return
    }
    guard snapshot.pid != nil else {
      try connection.writeLine(
        AttachResponse(ok: false, message: "\(snapshot.job.name) is not running"))
      return
    }
    try connection.writeLine(AttachResponse(ok: true, message: "Attached to \(snapshot.job.name)"))
    let output = await supervisor.terminalSessionOutput(jobID: snapshot.job.id)
    let outputTask = Task {
      do {
        for await event in output {
          guard case .bytes(let bytes) = event else { continue }
          try connection.writeLine(
            AttachStreamMessage(kind: .output, data: Data(bytes)))
        }
        try connection.writeLine(AttachStreamMessage(kind: .ended))
        connection.close()
      } catch {
        connection.close()
      }
    }
    defer { outputTask.cancel() }

    while let line = try connection.readLine() {
      let message = try JSONDecoder().decode(AttachStreamMessage.self, from: line)
      switch message.kind {
      case .ended:
        break
      case .input:
        if let data = message.data {
          try await supervisor.write(Array(data), jobID: snapshot.job.id)
        }
      case .resize:
        if let rows = message.rows, let cols = message.cols {
          try await supervisor.resize(WindowSize(rows: rows, cols: cols), jobID: snapshot.job.id)
        }
      case .output:
        break
      }
    }
  }
}
