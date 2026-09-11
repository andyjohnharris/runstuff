import AppKit
import Combine
import RunStuffCore
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
  private let model: AppModel
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let panel: RunStuffPanel
  private var cancellables: Set<AnyCancellable> = []

  init(model: AppModel) {
    self.model = model
    panel = RunStuffPanel(
      contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    super.init()

    panel.level = .popUpMenu
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.hasShadow = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

    let material = NSVisualEffectView()
    material.material = .popover
    material.blendingMode = .behindWindow
    material.state = .active
    material.wantsLayer = true
    material.layer?.cornerRadius = 12
    material.layer?.masksToBounds = true
    let hosting = NSHostingView(rootView: RootView(model: model))
    hosting.translatesAutoresizingMaskIntoConstraints = false
    material.addSubview(hosting)
    NSLayoutConstraint.activate([
      hosting.leadingAnchor.constraint(equalTo: material.leadingAnchor),
      hosting.trailingAnchor.constraint(equalTo: material.trailingAnchor),
      hosting.topAnchor.constraint(equalTo: material.topAnchor),
      hosting.bottomAnchor.constraint(equalTo: material.bottomAnchor),
    ])
    panel.contentView = material
    panel.onResignKey = { [weak panel] in panel?.orderOut(nil) }

    if let button = statusItem.button {
      button.target = self
      button.action = #selector(togglePanel)
      button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }
    model.closePanel = { [weak model, weak panel] in
      panel?.orderOut(nil)
      model?.panelVisibilityChanged(false)
    }
    model.$jobs.combineLatest(model.$orphans).sink { [weak self] jobs, orphans in
      self?.updateIcon(jobs, hasOrphans: !orphans.isEmpty)
    }.store(in: &cancellables)
  }

  @objc private func togglePanel() {
    if panel.isVisible {
      panel.orderOut(nil)
      model.panelVisibilityChanged(false)
      return
    }
    guard let button = statusItem.button, let window = button.window else { return }
    let buttonFrame = window.convertToScreen(button.frame)
    let screen = window.screen ?? NSScreen.main
    var origin = NSPoint(
      x: buttonFrame.midX - panel.frame.width / 2,
      y: buttonFrame.minY - panel.frame.height - 6)
    if let visible = screen?.visibleFrame {
      origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
    }
    panel.setFrameOrigin(origin)
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    model.panelVisibilityChanged(true)
  }

  func showPanel() {
    guard !panel.isVisible else { return }
    togglePanel()
  }

  func capturePanel(to path: String) {
    guard let view = panel.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
  }

  func captureEditor(to path: String) {
    model.prepareNewJob()
    let view = NSHostingView(rootView: JobEditorHost(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 560, height: 820)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
  }

  func captureSettings(to path: String) {
    let view = NSHostingView(
      rootView: SettingsView(settings: model.settings, updates: model.updates))
    view.frame = NSRect(x: 0, y: 0, width: 540, height: 520)
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
  }

  func captureRecovery(to path: String) {
    let view = NSHostingView(rootView: OrphanRecoveryView(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 560, height: max(180, 110 + model.orphans.count * 60))
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
  }

  private func updateIcon(_ jobs: [JobSnapshot], hasOrphans: Bool) {
    let running = jobs.filter { $0.pid != nil }
    let health: StatusHealth
    if hasOrphans || jobs.contains(where: { if case .error = $0.health { true } else { false } }) {
      health = .error
    } else if jobs.contains(where: { if case .warning = $0.health { true } else { false } }) {
      health = .warning
    } else {
      health = .normal
    }
    let renderer = ImageRenderer(content: StatusIconView(count: running.count, health: health))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    statusItem.button?.image = renderer.nsImage
    statusItem.button?.image?.isTemplate = health == .normal
    statusItem.button?.toolTip = running.isEmpty ? "RunStuff" : "\(running.count) running"
  }
}

private final class RunStuffPanel: NSPanel {
  var onResignKey: (() -> Void)?

  override var canBecomeKey: Bool { true }

  override func resignKey() {
    super.resignKey()
    onResignKey?()
  }
}

private enum StatusHealth {
  case normal
  case warning
  case error
}

private struct StatusIconView: View {
  let count: Int
  let health: StatusHealth

  var body: some View {
    HStack(spacing: 2) {
      Image(systemName: count == 0 ? "terminal" : "terminal.fill")
        .font(.system(size: 14, weight: .semibold))
      if count > 0 {
        Text("\(count)")
          .font(.system(size: 9, weight: .bold, design: .rounded))
      }
      switch health {
      case .normal:
        EmptyView()
      case .warning:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 7))
          .foregroundStyle(Color(nsColor: .systemOrange))
      case .error:
        Circle()
          .fill(Color(nsColor: .systemRed))
          .frame(width: 6, height: 6)
      }
    }
    .frame(height: 18)
  }
}
