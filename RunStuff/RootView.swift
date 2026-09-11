import AppKit
import Charts
import RunStuffCore
import SwiftTerm
import SwiftUI

struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @State private var navigationPath: [UUID] = []

  var body: some View {
    NavigationStack(path: $navigationPath) {
      VStack(spacing: 0) {
        if !model.runningJobs.isEmpty {
          runningHeader
          Divider()
        }
        if let banner = model.banner {
          bannerView(banner)
          Divider()
        }
        if model.jobs.isEmpty {
          emptyState
        } else {
          jobList
        }
        Divider()
        actionBar
      }
      .navigationDestination(for: UUID.self) { id in
        if let snapshot = model.jobs.first(where: { $0.job.id == id }) {
          JobDetailView(model: model, snapshot: snapshot)
        }
      }
    }
    .frame(width: 380, height: 500)
    .onChange(of: model.jobs) { _, jobs in
      guard let requested = ProcessInfo.processInfo.environment["RUNSTUFF_SCREENSHOT_DETAIL"],
        navigationPath.isEmpty
      else { return }
      let jobID =
        UUID(uuidString: requested).flatMap { requestedID in
          jobs.first(where: { $0.job.id == requestedID })?.job.id
        } ?? jobs.first?.job.id
      guard let jobID else { return }
      navigationPath = [jobID]
    }
    .sheet(
      isPresented: Binding(
        get: { !model.orphans.isEmpty },
        set: { _ in })
    ) {
      OrphanRecoveryView(model: model)
    }
  }

  private var runningHeader: some View {
    let windowEnd = Date()
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(model.runningJobs.count) running")
            .font(.system(size: 22, weight: .semibold))
          let cpu = model.runningJobs.compactMap(\.metric?.cpuPercent).reduce(0, +)
          let memory = model.runningJobs.compactMap(\.metric?.residentBytes).reduce(0, +)
          Text(
            "CPU \(cpu, format: .number.precision(.fractionLength(0)))%  ·  \(memory.formatted(.byteCount(style: .memory)))"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Stop All", systemImage: "stop.fill") {
          Task { await model.stopAll() }
        }
        .buttonStyle(.bordered)
      }
      Chart {
        ForEach(model.runningJobs, id: \.job.id) { snapshot in
          ForEach(recentMetrics(snapshot), id: \.timestamp) { metric in
            if metric.isGap {
              RuleMark(x: .value("Sleep", metric.timestamp))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else {
              AreaMark(
                x: .value("Time", metric.timestamp),
                y: .value("CPU", metric.cpuPercent),
                stacking: .standard
              )
              .foregroundStyle(by: .value("Stuff", snapshot.job.name))
            }
          }
        }
      }
      .chartForegroundStyleScale(
        domain: model.runningJobs.map(\.job.name),
        range: model.runningJobs.map { jobColor($0.job.colorSeed) }
      )
      .chartLegend(.hidden)
      .chartXScale(domain: windowEnd.addingTimeInterval(-60)...windowEnd)
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .frame(height: 64)
      .accessibilityLabel("CPU use over the last minute")
    }
    .padding(16)
  }

  private func recentMetrics(_ snapshot: JobSnapshot) -> [JobMetric] {
    let cutoff = Date().addingTimeInterval(-60)
    return snapshot.metricHistory.filter { $0.timestamp >= cutoff }
  }

  private func bannerView(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
      Text(message)
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        model.banner = nil
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
    }
    .padding(10)
    .background(Color.orange.opacity(0.1))
  }

  private var jobList: some View {
    List(model.jobs, id: \.job.id) { snapshot in
      NavigationLink(value: snapshot.job.id) {
        JobRow(model: model, snapshot: snapshot)
      }
    }
    .listStyle(.plain)
    .accessibilityLabel("Stuff")
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(systemName: "terminal")
        .font(.system(size: 38, weight: .light))
        .foregroundStyle(.secondary)
      Text("Nothing running yet.")
        .font(.headline)
      Text("Add a dev server or another long-running command.")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("Add Stuff", systemImage: "plus") {
        openEditor()
      }
      .buttonStyle(.borderedProminent)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }

  private var actionBar: some View {
    HStack {
      Button {
        openEditor()
      } label: {
        Image(systemName: "plus")
      }
      .help("Add stuff")
      .keyboardShortcut("n", modifiers: .command)
      Spacer()
      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape")
      }
      .help("RunStuff settings")
      Spacer()
      Button {
        model.quit()
      } label: {
        Image(systemName: "power")
      }
      .help("Quit RunStuff")
      .keyboardShortcut("q", modifiers: .command)
    }
    .buttonStyle(.plain)
    .font(.system(size: 16))
    .padding(.horizontal, 16)
    .frame(height: 42)
  }

  private func openEditor() {
    model.prepareNewJob()
    openWindow(id: "editor")
  }
}

private struct JobRow: View {
  @ObservedObject var model: AppModel
  let snapshot: JobSnapshot
  @State private var isHovered = false

  var body: some View {
    HStack(spacing: 10) {
      HealthMark(
        health: snapshot.health,
        running: snapshot.pid != nil,
        runningColor: jobColor(snapshot.job.colorSeed))
      VStack(alignment: .leading, spacing: 3) {
        Text(snapshot.job.name)
          .font(.system(size: 13, weight: .medium))
        Text(snapshot.job.command)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if let port = snapshot.listeningPorts.first {
        Text(verbatim: ":\(port)")
          .font(.caption.monospacedDigit())
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .background(.secondary.opacity(0.12), in: Capsule())
      }
      Spacer()
      Text(snapshot.isReady ? "Ready" : snapshot.state.label)
        .font(.caption)
        .foregroundStyle(.secondary)
      if let startedInstant = snapshot.startedInstant, snapshot.pid != nil {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          Text(elapsed(since: startedInstant))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      if snapshot.pid == nil {
        Button("Start", systemImage: "play.fill") { model.start(snapshot.job.id) }
          .labelStyle(.iconOnly)
          .help("Start \(snapshot.job.name)")
      } else if isHovered {
        Button("Stop", systemImage: "stop.fill") { model.stop(snapshot.job.id) }
          .labelStyle(.iconOnly)
          .help("Stop \(snapshot.job.name)")
        if !snapshot.isAdopted {
          Button("Restart", systemImage: "arrow.clockwise") { model.restart(snapshot.job.id) }
            .labelStyle(.iconOnly)
            .help("Restart \(snapshot.job.name)")
        }
      }
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 5)
    .overlay(alignment: .bottomLeading) {
      if isHovered, snapshot.metricHistory.count > 1 {
        Chart(snapshot.metricHistory.suffix(30), id: \.timestamp) { metric in
          if !metric.isGap {
            LineMark(
              x: .value("Time", metric.timestamp),
              y: .value("CPU", metric.cpuPercent)
            )
            .foregroundStyle(jobColor(snapshot.job.colorSeed))
          }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(width: 72, height: 16)
        .offset(x: 19, y: 5)
        .accessibilityHidden(true)
      }
    }
    .onHover { isHovered = $0 }
    .buttonStyle(.plain)
    .accessibilityElement(children: .contain)
  }
}

private struct HealthMark: View {
  let health: Health
  let running: Bool
  let runningColor: SwiftUI.Color

  var body: some View {
    Group {
      switch health {
      case .error:
        Circle().fill(Color.red).frame(width: 9, height: 9)
      case .warning:
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 9))
          .foregroundStyle(.orange)
      case .ok:
        Circle()
          .fill(running ? runningColor : Color.clear)
          .stroke(running ? runningColor : Color.secondary, lineWidth: 1.2)
          .frame(width: 9, height: 9)
      }
    }
    .accessibilityHidden(true)
  }
}

private struct JobDetailView: View {
  @ObservedObject var model: AppModel
  let snapshot: JobSnapshot
  @Environment(\.openWindow) private var openWindow
  @State private var confirmsDelete = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          HealthMark(
            health: snapshot.health,
            running: snapshot.pid != nil,
            runningColor: jobColor(snapshot.job.colorSeed))
          Text(snapshot.state.label)
            .foregroundStyle(.secondary)
          Spacer()
          if let pid = snapshot.pid {
            Text(verbatim: "PID \(pid)").monospacedDigit().foregroundStyle(.secondary)
          }
        }
        if case .warning(let reason, _) = snapshot.health {
          healthReason(reason, color: .orange)
        } else if case .error(let reason, _) = snapshot.health {
          healthReason(reason, color: .red)
        }
        detail("Command", snapshot.job.command)
        detail("Folder", snapshot.job.workingDirectory.path)
        detail("Shell", snapshot.job.shellMode.flagDescription)
        if !snapshot.listeningPorts.isEmpty {
          detail("Ports", snapshot.listeningPorts.map { ":\($0)" }.joined(separator: ", "))
        }

        if let metric = snapshot.metric {
          HStack {
            Label(
              "\(metric.cpuPercent, format: .number.precision(.fractionLength(1)))%",
              systemImage: "cpu")
            Label(
              metric.residentBytes.formatted(.byteCount(style: .memory)), systemImage: "memorychip")
          }
          .font(.caption)
        }

        metricCharts

        detail("Executable", snapshot.diagnostics?.resolvedExecutable ?? "Unavailable")
        detail(
          "Version",
          snapshot.diagnostics?.versionTimedOut == true
            ? "Probe timed out" : snapshot.diagnostics?.executableVersion ?? "Unavailable")
        detail("PATH", snapshot.diagnostics?.effectivePATH ?? "Resolving…")

        outputTail

        HStack {
          Button("View Output") { model.openTerminal(snapshot.job.id) }
            .disabled(snapshot.isAdopted)
            .help(
              snapshot.isAdopted
                ? "Output is unavailable for a process adopted after RunStuff quit" : "")
          Button("External Terminal") { model.openExternalTerminal(snapshot.job.id) }
            .disabled(snapshot.pid == nil || snapshot.isAdopted)
          Button(snapshot.pid == nil ? "Start" : "Stop") {
            snapshot.pid == nil ? model.start(snapshot.job.id) : model.stop(snapshot.job.id)
          }
          .buttonStyle(.borderedProminent)
          Button("Restart") { model.restart(snapshot.job.id) }
            .disabled(snapshot.pid == nil || snapshot.isAdopted)
        }
        HStack {
          Button("Edit") {
            model.prepareToEdit(snapshot.job)
            openWindow(id: "editor")
          }
          Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([snapshot.job.workingDirectory])
          }
          Button("Copy Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snapshot.job.command, forType: .string)
          }
          if let port = snapshot.listeningPorts.first {
            Button {
              if let url = URL(string: "http://localhost:\(port)") {
                NSWorkspace.shared.open(url)
              }
            } label: {
              Text(verbatim: "Open localhost:\(port)")
            }
          }
        }
        .buttonStyle(.link)

        toggles

        Button("Delete", role: .destructive) { confirmsDelete = true }
          .disabled(snapshot.pid != nil)
          .confirmationDialog("Delete \(snapshot.job.name)?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) {
              Task { await model.delete(snapshot.job.id) }
            }
          }
      }
      .padding(16)
    }
    .navigationTitle(snapshot.job.name)
    .task {
      await model.supervisor.acknowledgeWarning(jobID: snapshot.job.id)
      await model.supervisor.resolveDiagnostics(jobID: snapshot.job.id)
    }
  }

  private var outputTail: some View {
    let lines = model.output[snapshot.job.id, default: []].suffix(6)
    let placeholder =
      snapshot.isAdopted
      ? "Output is unavailable for an adopted process." : "No output yet"
    return Group {
      if lines.isEmpty {
        Text(placeholder)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
          .padding(8)
      } else {
        OutputTailView(bytes: lines.flatMap(\.raw))
          .frame(height: 86)
      }
    }
    .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
  }

  private var metricCharts: some View {
    let metrics = downsample(snapshot.metricHistory, maximumCount: 300)
    return VStack(alignment: .leading, spacing: 6) {
      if metrics.count > 1 {
        Text("CPU").font(.caption).foregroundStyle(.secondary)
        Chart(metrics, id: \.timestamp) { metric in
          if metric.isGap {
            RuleMark(x: .value("Sleep", metric.timestamp))
              .foregroundStyle(.secondary.opacity(0.5))
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
          } else {
            LineMark(
              x: .value("Time", metric.timestamp),
              y: .value("CPU", metric.cpuPercent)
            )
            .foregroundStyle(jobColor(snapshot.job.colorSeed))
          }
        }
        .chartXAxis(.hidden)
        .frame(height: 40)

        Text("Memory").font(.caption).foregroundStyle(.secondary)
        Chart(metrics, id: \.timestamp) { metric in
          if metric.isGap {
            RuleMark(x: .value("Sleep", metric.timestamp))
              .foregroundStyle(.secondary.opacity(0.5))
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
          } else {
            LineMark(
              x: .value("Time", metric.timestamp),
              y: .value("Bytes", metric.residentBytes)
            )
            .foregroundStyle(jobColor(snapshot.job.colorSeed))
          }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 34)
      }
    }
    .accessibilityLabel("Resource use for this run")
  }

  private var toggles: some View {
    VStack(alignment: .leading) {
      jobToggle("Open terminal on start", keyPath: \.openTerminalOnStart)
      jobToggle("Start when RunStuff launches", keyPath: \.autostartOnLaunch)
      jobToggle("Restart if it crashes", keyPath: \.restartOnCrash)
      if snapshot.job.readyRule != nil {
        jobToggle("Notify when ready", keyPath: \.notifyWhenReady)
      }
      jobToggle("Notify when waiting for input", keyPath: \.notifyWhenWaitingForInput)
      jobToggle("Notify after two minutes of high CPU", keyPath: \.notifyOnHighCPU)
    }
    .toggleStyle(.switch)
    .controlSize(.small)
  }

  private func jobToggle(_ title: String, keyPath: WritableKeyPath<Job, Bool>) -> some View {
    Toggle(
      title,
      isOn: Binding(
        get: { snapshot.job[keyPath: keyPath] },
        set: { value in
          var job = snapshot.job
          job[keyPath: keyPath] = value
          Task { await model.update(job) }
        }))
  }

  private func detail(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
    }
  }

  private func healthReason(_ reason: String, color: SwiftUI.Color) -> some View {
    Text(reason)
      .font(.caption)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(8)
      .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
  }
}

extension RunState {
  fileprivate var label: String {
    switch self {
    case .idle: "Stopped"
    case .starting: "Starting"
    case .running: "Running"
    case .stopping: "Stopping"
    case .exited(let code): code == 0 ? "Finished" : "Exit \(code)"
    case .signalled(let signal): signalName(signal)
    case .failedToStart: "Failed"
    }
  }
}

private func jobColor(_ seed: Int) -> SwiftUI.Color {
  SwiftUI.Color(hue: Double(seed.magnitude % 360) / 360, saturation: 0.62, brightness: 0.82)
}

private func elapsed(since start: ContinuousClock.Instant) -> String {
  let seconds = max(0, Int((ContinuousClock.now - start).seconds))
  if seconds < 60 { return "\(seconds)s" }
  if seconds < 3_600 { return "\(seconds / 60)m" }
  return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
}

private struct OutputTailView: NSViewRepresentable {
  let bytes: [UInt8]

  func makeNSView(context: Context) -> TerminalView {
    let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 11, weight: .regular))
    view.configureNativeColors()
    return view
  }

  func updateNSView(_ view: TerminalView, context: Context) {
    view.getTerminal().resetToInitialState()
    view.feed(byteArray: bytes[...])
  }
}

private func downsample(_ metrics: [JobMetric], maximumCount: Int) -> [JobMetric] {
  guard metrics.count > maximumCount else { return metrics }
  let bucketSize = Int(ceil(Double(metrics.count) / Double(maximumCount)))
  return stride(from: 0, to: metrics.count, by: bucketSize).map { start in
    let end = min(start + bucketSize, metrics.count)
    let bucket = metrics[start..<end]
    return bucket.first(where: \.isGap) ?? bucket[bucket.index(before: bucket.endIndex)]
  }
}

struct SettingsView: View {
  @ObservedObject var settings: AppSettings
  @ObservedObject var updates: UpdateController

  var body: some View {
    Form {
      Toggle(
        "Launch RunStuff at login",
        isOn: Binding(
          get: { settings.launchAtLogin },
          set: { settings.setLaunchAtLogin($0) }))
      Toggle("Play sounds for errors", isOn: $settings.soundsEnabled)
      Picker("Terminal theme", selection: $settings.terminalTheme) {
        ForEach(TerminalTheme.allCases, id: \.self) { theme in
          Text(theme.label).tag(theme)
        }
      }
      Picker(
        "External terminal",
        selection: Binding(
          get: { settings.externalTerminalPreset },
          set: { settings.selectTerminalPreset($0) })
      ) {
        ForEach(ExternalTerminalPreset.allCases, id: \.self) { preset in
          Text(preset.label).tag(preset)
        }
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("Launch template").font(.caption)
        TextEditor(text: $settings.externalTerminalTemplate)
          .font(.system(.caption, design: .monospaced))
          .frame(height: 48)
          .padding(4)
          .background(.background)
          .clipShape(RoundedRectangle(cornerRadius: 5))
          .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
      }
      Text("Use {command} where the bundled runstuff attach command should go.")
        .font(.caption)
        .foregroundStyle(.secondary)
      HStack {
        Button("Install Command-Line Tool…") { settings.installCLI() }
        if let status = settings.cliStatus {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
      }
      VStack(alignment: .leading, spacing: 5) {
        Text("Update appcast URL").font(.caption)
        TextField(
          "Update appcast URL",
          text: $settings.updateFeedURL,
          prompt: Text("https://example.com/appcast.xml")
        )
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
      }
      HStack {
        Button("Check for Updates…") { updates.checkForUpdates() }
        if let status = updates.status {
          Text(status).font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack {
        Text("Terminal font size")
        Slider(value: $settings.terminalFontSize, in: 9...24, step: 1)
        Text("\(Int(settings.terminalFontSize)) pt")
          .monospacedDigit()
          .frame(width: 42, alignment: .trailing)
      }
      if let error = settings.errorMessage {
        Text(error).foregroundStyle(.red)
      }
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 540, height: 520)
  }
}

struct OrphanRecoveryView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(
        "Processes from a previous RunStuff session are still running",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.headline)
      Text(
        "Adopt keeps lifecycle control, metrics and detected ports. The old terminal output cannot be recovered."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      ForEach(model.orphans, id: \.jobID) { record in
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(
              model.jobs.first(where: { $0.job.id == record.jobID })?.job.name ?? "Unknown Stuff"
            )
            .font(.headline)
            Text(verbatim: "PID \(record.pid)")
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Ignore") { model.resolveOrphan(record.jobID, action: .ignore) }
          Button("Stop") { model.resolveOrphan(record.jobID, action: .stop) }
          Button("Adopt") { model.resolveOrphan(record.jobID, action: .adopt) }
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(24)
    .frame(width: 560)
    .interactiveDismissDisabled()
  }
}
