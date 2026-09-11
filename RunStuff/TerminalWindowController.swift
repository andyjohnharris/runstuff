import AppKit
import Combine
import RunStuffCore
import SwiftTerm

@MainActor
final class TerminalWindowRegistry {
  private unowned let model: AppModel
  private var controllers: [UUID: TerminalWindowController] = [:]

  init(model: AppModel) {
    self.model = model
  }

  func show(jobID: UUID) {
    guard model.jobs.contains(where: { $0.job.id == jobID }) else { return }
    let controller = controllers[jobID] ?? TerminalWindowController(jobID: jobID, model: model)
    controllers[jobID] = controller
    controller.show()
  }

}

@MainActor
final class TerminalWindowController: NSWindowController, NSWindowDelegate,
  @preconcurrency TerminalViewDelegate
{
  private let jobID: UUID
  private unowned let model: AppModel
  private let terminalView: TerminalView
  private let footer = NSVisualEffectView()
  private let statusLabel = NSTextField(labelWithString: "")
  private let restartButton = NSButton(title: "Restart", target: nil, action: nil)
  private var cancellables: Set<AnyCancellable> = []
  private var outputTask: Task<Void, Never>?
  private var terminalTitle: String?

  init(jobID: UUID, model: AppModel) {
    self.jobID = jobID
    self.model = model
    terminalView = TerminalView(
      frame: .zero,
      font: .monospacedSystemFont(ofSize: model.settings.terminalFontSize, weight: .regular))

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    super.init(window: window)

    window.delegate = self
    window.isReleasedWhenClosed = false
    window.setFrameAutosaveName("RunStuff.Terminal.\(jobID.uuidString)")
    window.contentMinSize = NSSize(width: 480, height: 260)

    terminalView.translatesAutoresizingMaskIntoConstraints = false
    terminalView.terminalDelegate = self
    applyTheme(model.settings.terminalTheme)

    footer.translatesAutoresizingMaskIntoConstraints = false
    footer.material = .headerView
    footer.blendingMode = .withinWindow
    footer.state = .active

    statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    statusLabel.textColor = .labelColor
    statusLabel.lineBreakMode = .byTruncatingTail
    restartButton.bezelStyle = .rounded
    restartButton.controlSize = .small
    restartButton.target = self
    restartButton.action = #selector(restart)

    let footerStack = NSStackView(views: [statusLabel, restartButton])
    footerStack.translatesAutoresizingMaskIntoConstraints = false
    footerStack.orientation = .horizontal
    footerStack.alignment = .centerY
    footerStack.spacing = 10
    footer.addSubview(footerStack)

    let content = NSView()
    content.addSubview(terminalView)
    content.addSubview(footer)
    window.contentView = content
    NSLayoutConstraint.activate([
      terminalView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      terminalView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      terminalView.topAnchor.constraint(equalTo: content.topAnchor),
      terminalView.bottomAnchor.constraint(equalTo: footer.topAnchor),
      footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      footer.heightAnchor.constraint(equalToConstant: 38),
      footerStack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
      footerStack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
      footerStack.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
    ])

    model.$jobs.sink { [weak self] jobs in
      self?.update(using: jobs.first(where: { $0.job.id == jobID }))
    }.store(in: &cancellables)
    model.settings.$terminalFontSize.sink { [weak self] size in
      self?.terminalView.font = .monospacedSystemFont(ofSize: size, weight: .regular)
    }.store(in: &cancellables)
    model.settings.$terminalTheme.sink { [weak self] theme in
      self?.applyTheme(theme)
    }.store(in: &cancellables)
    outputTask = Task { [weak self, supervisor = model.supervisor] in
      let output = await supervisor.terminalOutput(jobID: jobID)
      for await event in output {
        guard let self else { return }
        self.receive(event)
      }
    }
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    outputTask?.cancel()
  }

  func show() {
    guard let window else { return }
    update(using: model.jobs.first(where: { $0.job.id == jobID }))
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(terminalView)
    model.terminalVisibilityChanged(jobID: jobID, visible: true)
    resizeToTerminal()
  }

  func windowWillClose(_ notification: Notification) {
    model.terminalVisibilityChanged(jobID: jobID, visible: false)
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard let cols = UInt16(exactly: newCols), let rows = UInt16(exactly: newRows) else { return }
    Task { try? await model.supervisor.resize(WindowSize(rows: rows, cols: cols), jobID: jobID) }
  }

  func setTerminalTitle(source: TerminalView, title: String) {
    terminalTitle = title
    updateWindowTitle()
  }

  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    let bytes = Array(data)
    Task { try? await model.supervisor.write(bytes, jobID: jobID) }
  }

  func scrolled(source: TerminalView, position: Double) {}

  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

  @objc private func restart() {
    model.restart(jobID)
  }

  private func receive(_ event: TerminalFeedEvent) {
    switch event {
    case .reset:
      terminalView.getTerminal().resetToInitialState()
      terminalView.needsDisplay = true
    case .bytes(let bytes):
      terminalView.feed(byteArray: bytes[...])
    }
  }

  private func update(using snapshot: JobSnapshot?) {
    guard let snapshot else { return }
    statusLabel.stringValue = statusText(snapshot.state)
    restartButton.title = snapshot.pid == nil ? "Restart" : "Restart Running Stuff"
    switch snapshot.state {
    case .starting, .stopping:
      restartButton.isEnabled = false
    default:
      restartButton.isEnabled = true
    }
    updateWindowTitle(jobName: snapshot.job.name)
  }

  private func updateWindowTitle(jobName: String? = nil) {
    let name = jobName ?? model.jobs.first(where: { $0.job.id == jobID })?.job.name ?? "Stuff"
    window?.title = terminalTitle.map { "\(name) — \($0)" } ?? name
  }

  private func resizeToTerminal() {
    let size = terminalView.getTerminal().getDims()
    sizeChanged(source: terminalView, newCols: size.cols, newRows: size.rows)
  }

  private func applyTheme(_ theme: TerminalTheme) {
    switch theme {
    case .system:
      terminalView.configureNativeColors()
    case .dark:
      terminalView.nativeForegroundColor = .white
      terminalView.nativeBackgroundColor = .black
    case .light:
      terminalView.nativeForegroundColor = .black
      terminalView.nativeBackgroundColor = .white
    }
    terminalView.needsDisplay = true
  }

  private func statusText(_ state: RunState) -> String {
    switch state {
    case .idle: "Not running"
    case .starting: "Starting…"
    case .running: "Running"
    case .stopping: "Stopping…"
    case .exited(let code): "Exited with code \(code)"
    case .signalled(let signal): "Exited after \(signalName(signal))"
    case .failedToStart(let message): message
    }
  }
}

@MainActor
final class PreviewTerminalWindowController: NSWindowController, NSWindowDelegate,
  @preconcurrency TerminalViewDelegate
{
  private let job: Job
  private let supervisor: Supervisor
  private let terminalView = TerminalView(
    frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
  private let statusLabel = NSTextField(labelWithString: "Starting test run…")
  private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
  private let onClose: () -> Void
  private var runtime: JobRuntime?
  private var runTask: Task<Void, Never>?
  private var eventTask: Task<Void, Never>?
  private var closing = false

  init(job: Job, supervisor: Supervisor, onClose: @escaping () -> Void) {
    self.job = job
    self.supervisor = supervisor
    self.onClose = onClose
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    super.init(window: window)
    window.title = "\(job.name.isEmpty ? "Stuff" : job.name) — Test Run"
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 480, height: 260)

    terminalView.translatesAutoresizingMaskIntoConstraints = false
    terminalView.terminalDelegate = self
    terminalView.configureNativeColors()
    statusLabel.lineBreakMode = .byTruncatingTail
    statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    stopButton.target = self
    stopButton.action = #selector(stop)
    stopButton.controlSize = .small

    let footer = NSStackView(views: [statusLabel, stopButton])
    footer.translatesAutoresizingMaskIntoConstraints = false
    footer.orientation = .horizontal
    footer.alignment = .centerY
    footer.spacing = 10
    footer.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
    let content = NSView()
    content.addSubview(terminalView)
    content.addSubview(footer)
    window.contentView = content
    NSLayoutConstraint.activate([
      terminalView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      terminalView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      terminalView.topAnchor.constraint(equalTo: content.topAnchor),
      terminalView.bottomAnchor.constraint(equalTo: footer.topAnchor),
      footer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      footer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      footer.heightAnchor.constraint(equalToConstant: 38),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func show() {
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window?.makeFirstResponder(terminalView)
    runTask = Task { [weak self] in
      guard let self else { return }
      do {
        let runtime = try await supervisor.startPreview(job)
        guard !Task.isCancelled, !closing else {
          _ = await runtime.stop(grace: .seconds(1))
          await runtime.close()
          try? await supervisor.finishPreview(runtime)
          return
        }
        self.runtime = runtime
        self.statusLabel.stringValue = "Running without saving"
        self.resizeRuntime()
        let output = await runtime.attach(
          discardReplayAfterAttach: true, bufferingPolicy: .bufferingNewest(16))
        self.eventTask = Task { [weak self] in
          for await event in runtime.events {
            guard let self else { return }
            if case .exited(let status, _) = event {
              self.statusLabel.stringValue = status.previewDescription
              self.stopButton.isEnabled = false
              _ = await runtime.waitForDrainEnd(timeout: .seconds(1))
              await runtime.close()
              try? await supervisor.finishPreview(runtime)
              if self.runtime?.pid == runtime.pid { self.runtime = nil }
            }
          }
        }
        for await chunk in output {
          self.terminalView.feed(byteArray: chunk.bytes[...])
        }
      } catch {
        self.statusLabel.stringValue = "Could not start: \(error)"
        self.stopButton.isEnabled = false
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    closeRuntime()
    onClose()
  }

  func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
    guard let cols = UInt16(exactly: newCols), let rows = UInt16(exactly: newRows),
      let runtime
    else { return }
    Task { try? await runtime.resize(WindowSize(rows: rows, cols: cols)) }
  }

  func send(source: TerminalView, data: ArraySlice<UInt8>) {
    guard let runtime else { return }
    let bytes = Array(data)
    Task { try? await runtime.write(bytes) }
  }

  func setTerminalTitle(source: TerminalView, title: String) {}
  func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
  func scrolled(source: TerminalView, position: Double) {}
  func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

  @objc private func stop() {
    stopButton.isEnabled = false
    closeRuntime()
  }

  private func resizeRuntime() {
    let size = terminalView.getTerminal().getDims()
    sizeChanged(source: terminalView, newCols: size.cols, newRows: size.rows)
  }

  private func closeRuntime() {
    guard !closing else { return }
    closing = true
    runTask?.cancel()
    eventTask?.cancel()
    guard let runtime else { return }
    Task {
      _ = await runtime.stop(grace: .seconds(1))
      await runtime.close()
      try? await supervisor.finishPreview(runtime)
      self.runtime = nil
      self.statusLabel.stringValue = "Test run stopped"
    }
  }
}

extension ExitStatus {
  fileprivate var previewDescription: String {
    switch self {
    case .exited(let code): "Exited with code \(code)"
    case .signalled(let signal, _): "Exited after \(signalName(signal))"
    }
  }
}
