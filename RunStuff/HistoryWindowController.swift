import AppKit
import Charts
import RunStuffCore
import SwiftTerm
import SwiftUI

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
  private unowned let model: AppModel
  private(set) var isOpen = false

  init(model: AppModel) {
    self.model = model
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    super.init(window: window)
    window.title = "Run History"
    window.delegate = self
    window.isReleasedWhenClosed = false
    window.contentMinSize = NSSize(width: 720, height: 440)
    window.setFrameAutosaveName("RunStuff.History")
    window.contentView = NSHostingView(rootView: HistoryView(model: model))
  }

  required init?(coder: NSCoder) { nil }

  func show() {
    isOpen = true
    model.updateActivationPolicy()
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  func windowWillClose(_ notification: Notification) {
    isOpen = false
    model.updateActivationPolicy()
  }
}

private struct HistoryView: View {
  @ObservedObject var model: AppModel
  @State private var selectedRunID: UUID?

  private var filteredRuns: [JobRunRecord] {
    guard let filter = model.historyJobFilter else { return model.history }
    return model.history.filter { $0.jobID == filter }
  }

  private var filterJobs: [(id: UUID, name: String, deleted: Bool)] {
    let current = Dictionary(uniqueKeysWithValues: model.jobs.map { ($0.job.id, $0.job.name) })
    let grouped = Dictionary(grouping: model.history, by: \.jobID)
    var choices = current.map { (id: $0.key, name: $0.value, deleted: false) }
    choices += grouped.compactMap { id, runs in
      guard current[id] == nil else { return nil }
      guard let run = runs.first else { return nil }
      return (id: id, name: run.name, deleted: true)
    }
    return choices.sorted {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        Picker("Stuff", selection: $model.historyJobFilter) {
          Text("All Stuff").tag(UUID?.none)
          ForEach(filterJobs, id: \.id) { job in
            Text(job.deleted ? "\(job.name) — Deleted Stuff" : job.name).tag(Optional(job.id))
          }
        }
        .padding(12)
        Divider()
        if filteredRuns.isEmpty {
          ContentUnavailableView(
            "No Runs", systemImage: "clock.arrow.circlepath",
            description: Text(
              model.historyJobFilter == nil
                ? "Completed runs will appear here." : "This Stuff has no completed runs."))
        } else {
          List(filteredRuns, selection: $selectedRunID) { run in
            HistoryRow(run: run, deleted: !model.jobs.contains { $0.job.id == run.jobID })
              .tag(run.id)
          }
          .listStyle(.plain)
          .scrollContentBackground(.hidden)
        }
      }
      .background(RunStuffStyle.canvas)
      .navigationSplitViewColumnWidth(min: 260, ideal: 320)
    } detail: {
      if let run = filteredRuns.first(where: { $0.id == selectedRunID }) {
        RunHistoryDetail(
          run: run, deleted: !model.jobs.contains { $0.job.id == run.jobID },
          settings: model.settings, checkPortOwner: model.checkPortOwner
        )
        .id(run.id)
      } else {
        ContentUnavailableView(
          "Select a Run", systemImage: "terminal",
          description: Text("Choose a completed run to inspect its details and output."))
      }
    }
    .onAppear { resetSelection() }
    .onChange(of: model.historyJobFilter) { resetSelection() }
    .onChange(of: model.history) { resetSelectionIfNeeded() }
    .stuffTheme()
  }

  private func resetSelection() {
    selectedRunID = filteredRuns.first?.id
  }

  private func resetSelectionIfNeeded() {
    guard filteredRuns.contains(where: { $0.id == selectedRunID }) else {
      resetSelection()
      return
    }
  }
}

private struct HistoryRow: View {
  let run: JobRunRecord
  let deleted: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(run.name).font(RunStuffStyle.heading).lineLimit(1)
      if deleted {
        Text("Deleted Stuff").font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
      }
      Text(run.command).font(RunStuffStyle.code).foregroundStyle(RunStuffStyle.secondary).lineLimit(
        1)
      Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
        .font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
      HStack {
        Text(run.outcome)
          .foregroundStyle(
            run.outcome == "Exit 0"
              ? RunStuffStyle.mint
              : run.outcome == "Stopped" ? RunStuffStyle.secondary : RunStuffStyle.coral)
        Spacer()
        Text(
          Duration.seconds(run.endedAt.timeIntervalSince(run.startedAt)),
          format: .time(pattern: .minuteSecond))
      }
      .font(RunStuffStyle.caption)
    }
    .padding(.vertical, 5)
  }
}

private struct RunHistoryDetail: View {
  let run: JobRunRecord
  let deleted: Bool
  @ObservedObject var settings: AppSettings
  let checkPortOwner: (UInt16) -> Void

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(run.name).font(RunStuffStyle.title)
              Text(deleted ? "Deleted Stuff" : "Saved Stuff")
                .font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
            }
            Spacer()
            Text(run.outcome).font(RunStuffStyle.heading)
          }
          StuffCard {
            value("Command", run.command)
            Divider()
            value("Folder", run.workingDirectory)
            Divider()
            value("Shell", run.shellMode)
            Divider()
            value("Started", run.startedAt.formatted(date: .long, time: .standard))
            Divider()
            value("Ended", run.endedAt.formatted(date: .long, time: .standard))
            Divider()
            value(
              "Duration",
              Duration.seconds(run.endedAt.timeIntervalSince(run.startedAt)).formatted(
                .time(pattern: .hourMinuteSecond)))
            Divider()
            value("Outcome", run.outcome)
            if let status = run.exitStatus {
              Divider()
              value("Exit status", status)
            }
            if let executable = run.resolvedExecutable {
              Divider()
              value("Executable", executable)
            }
            if let version = run.executableVersion {
              Divider()
              value("Version", version)
            }
          }
          if let summary = run.failureSummary {
            StuffCard {
              value("Reported issue", summary)
              if let evidence = run.failureEvidence {
                Divider()
                value("Evidence", evidence)
              }
              if let port = run.conflictingPort {
                Button("Check Port Owner") { checkPortOwner(port) }
                  .buttonStyle(StuffButtonStyle(tint: RunStuffStyle.mint))
                  .padding(12)
              }
            }
          }
          if let metrics = run.metrics, !metrics.isEmpty {
            let samples = downsample(metrics, maximumCount: 120)
            historyChart("Recorded CPU (%)", samples: samples, color: RunStuffStyle.mint) {
              $0.cpuPercent
            }
            historyChart("Recorded memory (MiB)", samples: samples, color: RunStuffStyle.blue) {
              Double($0.residentBytes) / 1_048_576
            }
          }
          if run.isRecovered {
            Text("Recovered process. Earlier output and the final exit status are unavailable.")
              .font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
          }
        }
        .padding(16)
      }
      .frame(maxHeight: 390)
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        Text("TERMINAL OUTPUT").font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
        if run.outputTruncated {
          Label(
            "Earlier output omitted. Up to the newest 256 KiB is retained.", systemImage: "scissors"
          )
          .font(RunStuffStyle.caption).foregroundStyle(.orange)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
      if run.rawOutput.isEmpty {
        ContentUnavailableView(
          "No Output", systemImage: "terminal",
          description: Text(
            run.isRecovered
              ? "Output was unavailable for this recovered run."
              : "This run produced no terminal output."))
      } else {
        ReadOnlyTerminal(run: run, theme: settings.terminalTheme)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(RunStuffStyle.canvas)
  }

  private func value(_ label: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(label).font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
        .frame(width: 88, alignment: .leading)
      Text(text).font(RunStuffStyle.code).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }.padding(12)
  }

  private func historyChart(
    _ title: String, samples: [JobMetric], color: SwiftUI.Color,
    value: @escaping (JobMetric) -> Double
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(RunStuffStyle.caption).foregroundStyle(RunStuffStyle.secondary)
      Chart(samples, id: \.timestamp) { sample in
        if sample.isGap {
          RuleMark(x: .value("Sampling gap", sample.timestamp))
            .foregroundStyle(.secondary).lineStyle(StrokeStyle(dash: [2, 2]))
        } else {
          PointMark(x: .value("Time", sample.timestamp), y: .value(title, value(sample)))
            .foregroundStyle(color)
        }
      }
      .chartYScale(domain: 0...max(1, samples.filter { !$0.isGap }.map(value).max() ?? 0))
      .frame(height: 100)
    }
  }
}

private struct ReadOnlyTerminal: NSViewRepresentable {
  let run: JobRunRecord
  let theme: TerminalTheme

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> TerminalView {
    let view = TerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    view.terminalDelegate = context.coordinator
    feed(view, context.coordinator)
    return view
  }

  func updateNSView(_ view: TerminalView, context: Context) {
    feed(view, context.coordinator)
  }

  private func feed(_ view: TerminalView, _ coordinator: Coordinator) {
    switch theme {
    case .system: view.configureNativeColors()
    case .dark:
      view.nativeForegroundColor = .white
      view.nativeBackgroundColor = .black
    case .light:
      view.nativeForegroundColor = .black
      view.nativeBackgroundColor = .white
    }
    guard coordinator.runID != run.id else { return }
    coordinator.runID = run.id
    view.getTerminal().resetToInitialState()
    let bytes = [UInt8](run.rawOutput)
    view.feed(byteArray: bytes[...])
  }

  final class Coordinator: NSObject, TerminalViewDelegate {
    var runID: UUID?
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
  }
}
