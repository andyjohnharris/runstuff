import AppKit
import Charts
import RunStuffCore
import SwiftUI

struct RootView: View {
  @ObservedObject var model: AppModel
  @Environment(\.openSettings) private var openSettings
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var navigationPath: [UUID] = []

  var body: some View {
    NavigationStack(path: $navigationPath) {
      VStack(spacing: 0) {
        if !model.runningJobs.isEmpty {
          runningHeader
            .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
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
      .animation(reduceMotion ? nil : RunStuffStyle.transition, value: model.runningJobs.isEmpty)
      .clipped()
      .background(RunStuffStyle.canvas)
      .navigationDestination(for: UUID.self) { id in
        if let snapshot = model.jobs.first(where: { $0.job.id == id }) {
          JobDetailView(model: model, snapshot: snapshot)
        }
      }
    }
    .toolbar(.hidden, for: .windowToolbar)
    .stuffTheme()
    .frame(width: RunStuffStyle.panelWidth, height: RunStuffStyle.panelHeight)
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
          Label("\(model.runningJobs.count) running", systemImage: "circle.fill")
            .font(RunStuffStyle.title)
            .labelStyle(RunningCountLabelStyle())
          let cpu = model.runningJobs.compactMap(\.metric?.cpuPercent).reduce(0, +)
          let memory = model.runningJobs.compactMap(\.metric?.residentBytes).reduce(0, +)
          Text(
            "CPU \(cpu, format: .number.precision(.fractionLength(0)))%  ·  \(memory.formatted(.byteCount(style: .memory)))"
          )
          .font(.caption)
          .foregroundStyle(RunStuffStyle.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(RunStuffStyle.raised, in: RoundedRectangle(cornerRadius: 7))
        }
        Spacer()
        Button("Stop All", systemImage: "stop.fill") {
          Task { await model.stopAll() }
        }
        .buttonStyle(StuffButtonStyle(tint: RunStuffStyle.coral))
        .disabled(model.runningJobs.isEmpty)
      }
      Chart {
        ForEach(model.runningJobs, id: \.job.id) { snapshot in
          ForEach(recentMetrics(snapshot), id: \.timestamp) { metric in
            if metric.isGap {
              RuleMark(x: .value("Sleep", metric.timestamp))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
            } else {
              BarMark(
                x: .value("Time", metric.timestamp),
                y: .value("CPU", metric.cpuPercent),
                width: .fixed(3),
                stacking: .standard
              )
              .foregroundStyle(RunStuffStyle.mint.gradient)
            }
          }
        }
      }
      .chartLegend(.hidden)
      .chartXScale(domain: windowEnd.addingTimeInterval(-60)...windowEnd)
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
      .frame(height: 64)
      .accessibilityLabel("CPU use over the last minute")
    }
    .padding(RunStuffStyle.inset)
    .background(
      LinearGradient(
        colors: [RunStuffStyle.raised, RunStuffStyle.surface], startPoint: .top, endPoint: .bottom))
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
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text("STUFF")
          .font(RunStuffStyle.caption)
          .tracking(1.5)
          .foregroundStyle(RunStuffStyle.secondary)
        ForEach(model.jobs, id: \.job.id) { snapshot in
          JobRow(model: model, snapshot: snapshot) {
            withAnimation(reduceMotion ? nil : RunStuffStyle.transition) {
              navigationPath.append(snapshot.job.id)
            }
          }
        }
        Button("Add Stuff", systemImage: "plus") { openEditor() }
          .frame(maxWidth: .infinity, minHeight: 40)
          .buttonStyle(.plain)
          .foregroundStyle(RunStuffStyle.secondary)
          .background(
            RoundedRectangle(cornerRadius: RunStuffStyle.radius).stroke(RunStuffStyle.border))
      }
      .padding(RunStuffStyle.inset)
    }
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
        Label("New", systemImage: "plus")
      }
      .buttonStyle(StuffButtonStyle(tint: RunStuffStyle.mint))
      .help("Add stuff")
      .keyboardShortcut("n", modifiers: .command)
      Spacer()
      Button {
        model.openHistory()
      } label: {
        Image(systemName: "clock.arrow.circlepath")
      }
      .accessibilityLabel("History")
      .help("Run history")
      Button {
        openSettings()
      } label: {
        Image(systemName: "gearshape")
      }
      .help("RunStuff settings")
      Button {
        model.quit()
      } label: {
        Image(systemName: "power")
      }
      .help("Quit RunStuff")
      .keyboardShortcut("q", modifiers: .command)
    }
    .buttonStyle(StuffButtonStyle())
    .font(.system(size: 16))
    .padding(.horizontal, 16)
    .frame(height: 58)
    .background(RunStuffStyle.surface)
  }

  private func openEditor() {
    model.showNewJobEditor()
  }
}

private struct JobRow: View {
  @ObservedObject var model: AppModel
  let snapshot: JobSnapshot
  var showDetail: () -> Void
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    HStack(spacing: 10) {
      Button(action: showDetail) {
        HStack(spacing: 12) {
          Image(systemName: snapshot.pid != nil ? "waveform.path" : "moon")
            .font(.system(size: 20))
            .foregroundStyle(snapshot.pid != nil ? RunStuffStyle.mint : RunStuffStyle.secondary)
            .frame(width: 38, height: 38)
            .background(
              (snapshot.pid != nil ? RunStuffStyle.mint : RunStuffStyle.secondary).opacity(0.10),
              in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay(alignment: .bottomTrailing) {
              if snapshot.reportedPortConflict != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                  .foregroundStyle(RunStuffStyle.coral)
              } else {
                HealthMark(
                  health: snapshot.health, running: snapshot.pid != nil,
                  runningColor: RunStuffStyle.mint)
              }
            }
          VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.job.name)
              .font(RunStuffStyle.heading)
              .lineLimit(1)
            if let diagnostic = snapshot.failure ?? snapshot.reportedPortConflict {
              Text(diagnostic.summary)
                .font(RunStuffStyle.caption)
                .foregroundStyle(RunStuffStyle.coral)
                .lineLimit(3)
                .help(diagnostic.summary)
            } else if case .error(let reason, _) = snapshot.health {
              Text(reason)
                .font(RunStuffStyle.caption)
                .foregroundStyle(RunStuffStyle.coral)
                .lineLimit(2)
                .help(reason)
            } else {
              Text(snapshot.job.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          if let port = snapshot.listeningPorts.first {
            Text(verbatim: ":\(port)")
              .font(.caption.monospacedDigit())
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(.secondary.opacity(0.12), in: Capsule())
          }
          Spacer()
          VStack(alignment: .trailing, spacing: 4) {
            Text(
              snapshot.reportedPortConflict != nil
                ? "Check output" : snapshot.isReady ? "Ready" : snapshot.state.label
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let startedInstant = snapshot.startedInstant, snapshot.pid != nil {
              TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(elapsed(since: startedInstant))
                  .font(.caption.monospacedDigit())
                  .foregroundStyle(.secondary)
              }
            }
          }
          .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if snapshot.pid == nil {
        Button("Start", systemImage: "play.fill") { model.start(snapshot.job.id) }
          .labelStyle(.iconOnly)
          .help("Start \(snapshot.job.name)")
      } else {
        Button("View Output", systemImage: "terminal") { model.openTerminal(snapshot.job.id) }
          .labelStyle(.iconOnly)
          .buttonStyle(StuffButtonStyle(tint: RunStuffStyle.mint))
          .disabled(snapshot.isAdopted)
          .help(
            snapshot.isAdopted
              ? "Output is unavailable for a process adopted after RunStuff quit"
              : "View output for \(snapshot.job.name)")
        Button("Stop", systemImage: "stop.fill") { model.stop(snapshot.job.id) }
          .labelStyle(.iconOnly)
          .help("Stop \(snapshot.job.name)")
      }
      Button(action: showDetail) {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Details for \(snapshot.job.name)")
    }
    .padding(12)
    .background(
      isHovered ? RunStuffStyle.raised : RunStuffStyle.surface,
      in: RoundedRectangle(cornerRadius: RunStuffStyle.radius)
    )
    .overlay(
      RoundedRectangle(cornerRadius: RunStuffStyle.radius).stroke(
        snapshot.pid != nil ? RunStuffStyle.mint.opacity(0.25) : RunStuffStyle.border)
    )
    .animation(reduceMotion ? nil : RunStuffStyle.feedback, value: isHovered)
    .onHover { isHovered = $0 }
    .buttonStyle(
      StuffButtonStyle(tint: snapshot.pid != nil ? RunStuffStyle.coral : RunStuffStyle.secondary)
    )
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
  @State private var confirmsDelete = false
  @State private var showsPATH = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if snapshot.pid != nil, let failure = snapshot.failure ?? snapshot.reportedPortConflict {
            StuffCard {
              VStack(alignment: .leading, spacing: 10) {
                Label(failure.summary, systemImage: "exclamationmark.triangle.fill")
                  .foregroundStyle(RunStuffStyle.coral)
                  .fixedSize(horizontal: false, vertical: true)
                if snapshot.failure == nil {
                  Text("Reported in output. The command exited with code 0.")
                    .font(RunStuffStyle.caption)
                    .foregroundStyle(RunStuffStyle.secondary)
                }
                Text(failure.evidence)
                  .font(RunStuffStyle.code)
                  .foregroundStyle(RunStuffStyle.secondary)
                  .textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
                HStack {
                  if let port = failure.conflictingPort {
                    Button("Check Port Owner") { model.checkPortOwner(port) }
                  }
                  Button("View Output") { model.openTerminal(snapshot.job.id) }
                }
                .buttonStyle(StuffButtonStyle(tint: RunStuffStyle.mint))
              }
              .padding(12)
            }
          } else if snapshot.pid != nil, case .warning(let reason, _) = snapshot.health {
            healthReason(reason, color: .orange)
          } else if snapshot.pid != nil, case .error(let reason, _) = snapshot.health {
            healthReason(reason, color: .red)
          }
          StuffCard {
            detail("Command", snapshot.job.command)
            Divider()
            detail("Folder", snapshot.job.workingDirectory.path)
            Divider()
            detail("Shell", snapshot.job.shellMode.flagDescription)
            if !snapshot.listeningPorts.isEmpty {
              Divider()
              detail("Ports", snapshot.listeningPorts.map { ":\($0)" }.joined(separator: ", "))
            }
          }

          if snapshot.pid != nil {
            metricCharts
          }

          if snapshot.pid != nil {
            StuffCard {
              detail("Executable", snapshot.diagnostics?.resolvedExecutable ?? "Unavailable")
              Divider()
              detail(
                "Version",
                snapshot.diagnostics?.versionTimedOut == true
                  ? "Probe timed out" : snapshot.diagnostics?.executableVersion ?? "Unavailable")
              Divider()
              DisclosureGroup("PATH", isExpanded: $showsPATH) {
                Text(snapshot.diagnostics?.effectivePATH ?? "Resolving…")
                  .font(RunStuffStyle.code)
                  .foregroundStyle(RunStuffStyle.secondary)
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
                  .padding(.top, 8)
              }
              .padding(12)
              .animation(reduceMotion ? nil : RunStuffStyle.transition, value: showsPATH)
            }
          }

          HStack {
            Button("Edit", systemImage: "pencil") {
              model.showEditor(for: snapshot.job)
            }
            Button("Reveal", systemImage: "folder") {
              NSWorkspace.shared.activateFileViewerSelecting([snapshot.job.workingDirectory])
            }
            Button("Copy", systemImage: "square.on.square") {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(snapshot.job.command, forType: .string)
            }
            if snapshot.pid != nil {
              Button("Terminal", systemImage: "arrow.up.forward.square") {
                model.openExternalTerminal(snapshot.job.id)
              }
              .disabled(snapshot.isAdopted)
              .help("Open in external terminal")
            }
          }
          .labelStyle(StuffActionLabelStyle())
          .buttonStyle(StuffButtonStyle())
          if snapshot.pid != nil, let port = snapshot.listeningPorts.first {
            Button {
              if let url = URL(string: "http://localhost:\(port)") {
                NSWorkspace.shared.open(url)
              }
            } label: {
              Text(verbatim: "Open localhost:\(port)")
            }
          }

          toggles
        }
        .padding(16)
      }
      Divider()
      footer
    }
    .background(RunStuffStyle.canvas)
    .navigationBarBackButtonHidden()
    .task {
      await model.supervisor.acknowledgeWarning(jobID: snapshot.job.id)
      await model.supervisor.resolveDiagnostics(jobID: snapshot.job.id)
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Button {
        withAnimation(reduceMotion ? nil : RunStuffStyle.transition) { dismiss() }
      } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 13, weight: .semibold))
      }
      .buttonStyle(StuffButtonStyle())
      .help("Back to all Stuff")
      .keyboardShortcut("[", modifiers: .command)
      .accessibilityLabel("Back")
      VStack(alignment: .leading, spacing: 5) {
        Text(snapshot.job.name)
          .font(RunStuffStyle.heading)
          .lineLimit(1)
        HStack(spacing: 6) {
          if snapshot.pid == nil && !lifecycleBusy {
            Text("Not running")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            if snapshot.reportedPortConflict != nil {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(RunStuffStyle.coral)
            } else {
              HealthMark(
                health: snapshot.health,
                running: snapshot.pid != nil,
                runningColor: RunStuffStyle.mint)
            }
            Text(
              snapshot.reportedPortConflict != nil
                ? "Check output · \(snapshot.state.label)" : snapshot.state.label
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let pid = snapshot.pid {
              Text(verbatim: "PID \(pid)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      Spacer()
      Button {
        snapshot.pid == nil ? model.start(snapshot.job.id) : model.stop(snapshot.job.id)
      } label: {
        Image(systemName: snapshot.pid == nil ? "play.fill" : "stop.fill")
      }
      .buttonStyle(
        StuffButtonStyle(tint: snapshot.pid == nil ? RunStuffStyle.mint : RunStuffStyle.coral)
      )
      .help(snapshot.pid == nil ? "Start \(snapshot.job.name)" : "Stop \(snapshot.job.name)")
      .disabled(lifecycleBusy)
    }
    .padding(.horizontal, 16)
    .frame(height: 74)
    .background(RunStuffStyle.surface)
  }

  private var lifecycleBusy: Bool {
    switch snapshot.state {
    case .starting, .stopping: true
    default: false
    }
  }

  private var footer: some View {
    HStack {
      Button {
        if snapshot.pid == nil {
          model.start(snapshot.job.id)
        } else {
          model.restart(snapshot.job.id)
        }
      } label: {
        Label(
          snapshot.pid == nil ? "Start" : "Restart",
          systemImage: snapshot.pid == nil ? "play.fill" : "arrow.clockwise")
      }
      .buttonStyle(StuffButtonStyle(tint: RunStuffStyle.mint))
      .disabled(snapshot.isAdopted || lifecycleBusy)
      .help(snapshot.pid == nil ? "Start \(snapshot.job.name)" : "Restart \(snapshot.job.name)")
      Spacer()
      Button {
        model.openHistory(jobID: snapshot.job.id)
      } label: {
        Image(systemName: "clock.arrow.circlepath")
      }
      .accessibilityLabel("History")
      .help("Run history for \(snapshot.job.name)")
      if snapshot.pid != nil {
        Button {
          model.openTerminal(snapshot.job.id)
        } label: {
          Image(systemName: "terminal")
        }
        .accessibilityLabel("View Output")
        .disabled(snapshot.isAdopted)
        .help(snapshot.isAdopted ? "Output is unavailable for an adopted process" : "View output")
      }
      Button(role: .destructive) {
        confirmsDelete = true
      } label: {
        Image(systemName: "trash")
      }
      .buttonStyle(StuffButtonStyle(tint: RunStuffStyle.coral))
      .disabled(snapshot.pid != nil)
      .help("Delete \(snapshot.job.name)")
      .confirmationDialog("Delete \(snapshot.job.name)?", isPresented: $confirmsDelete) {
        Button("Delete", role: .destructive) {
          Task { await model.delete(snapshot.job.id) }
        }
      }
    }
    .buttonStyle(StuffButtonStyle())
    .font(.system(size: 16))
    .padding(.horizontal, 16)
    .frame(height: 58)
    .background(RunStuffStyle.surface)
  }

  private var metricCharts: some View {
    let metrics = downsample(snapshot.metricHistory, maximumCount: 30)
    return HStack(spacing: 10) {
      StuffCard {
        HStack {
          Text("CPU").font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
          Spacer()
          Text(snapshot.metric.map { String(format: "%.1f%%", $0.cpuPercent) } ?? "—")
            .font(RunStuffStyle.code).foregroundStyle(RunStuffStyle.mint)
        }
        .padding(12)
        Chart(metrics, id: \.timestamp) { metric in
          if metric.isGap {
            RuleMark(x: .value("Sleep", metric.timestamp))
              .foregroundStyle(.secondary.opacity(0.5))
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
          } else {
            BarMark(
              x: .value("Time", metric.timestamp),
              y: .value("CPU", metric.cpuPercent),
              width: .fixed(3)
            )
            .foregroundStyle(RunStuffStyle.mint.gradient)
          }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 40)
        .padding(12)
      }

      StuffCard {
        HStack {
          Text("MEMORY").font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
          Spacer()
          Text(snapshot.metric?.residentBytes.formatted(.byteCount(style: .memory)) ?? "—")
            .font(RunStuffStyle.code).foregroundStyle(RunStuffStyle.blue)
        }
        .padding(12)
        Chart(metrics, id: \.timestamp) { metric in
          if metric.isGap {
            RuleMark(x: .value("Sleep", metric.timestamp))
              .foregroundStyle(.secondary.opacity(0.5))
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
          } else {
            BarMark(
              x: .value("Time", metric.timestamp),
              y: .value("Bytes", metric.residentBytes),
              width: .fixed(3)
            )
            .foregroundStyle(RunStuffStyle.blue.gradient)
          }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 40)
        .padding(12)
      }
    }
  }

  private var toggles: some View {
    StuffCard {
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
    HStack {
      Text(title)
      Spacer()
      Toggle(
        title,
        isOn: Binding(
          get: { snapshot.job[keyPath: keyPath] },
          set: { value in
            var job = snapshot.job
            job[keyPath: keyPath] = value
            Task { await model.update(job) }
          })
      )
      .labelsHidden()
    }
    .padding(12)
    .frame(maxWidth: .infinity)
    .overlay(alignment: .bottom) { Divider().padding(.horizontal, 12) }
  }

  private func detail(_ label: String, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 16) {
      Text(label).foregroundStyle(RunStuffStyle.secondary)
      Spacer(minLength: 0)
      Text(value).font(RunStuffStyle.code).textSelection(.enabled)
        .multilineTextAlignment(.trailing)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(12)
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

private func elapsed(since start: ContinuousClock.Instant) -> String {
  let seconds = max(0, Int((ContinuousClock.now - start).seconds))
  if seconds < 60 { return "\(seconds)s" }
  if seconds < 3_600 { return "\(seconds / 60)m" }
  return "\(seconds / 3_600)h \((seconds % 3_600) / 60)m"
}

func downsample(_ metrics: [JobMetric], maximumCount: Int) -> [JobMetric] {
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
  @ObservedObject var notifications: NotificationService
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Form {
      Section("Notifications") {
        Text(notifications.permissionSummary)
          .font(RunStuffStyle.caption)
          .foregroundStyle(RunStuffStyle.secondary)
        HStack {
          if notifications.authorizationStatus == .notDetermined {
            Button("Enable Notifications") { Task { await notifications.requestPermission() } }
          }
          Button("Notification Settings…") {
            if let url = URL(
              string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            {
              NSWorkspace.shared.open(url)
            }
          }
        }
      }
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
    .stuffTheme()
    .task { await notifications.refreshAuthorization() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await notifications.refreshAuthorization() } }
    }
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
    .stuffTheme()
    .interactiveDismissDisabled()
  }
}
