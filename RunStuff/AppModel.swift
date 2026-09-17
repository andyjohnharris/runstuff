import AppKit
import Combine
import RunStuffCore
import ServiceManagement
import Sparkle

@MainActor
final class AppModel: ObservableObject {
  @Published private(set) var jobs: [JobSnapshot] = []
  @Published var banner: String?
  @Published var editorJob: Job?
  @Published var orphans: [RuntimeRecord] = []

  let supervisor: Supervisor
  let notifications = NotificationService()
  let settings = AppSettings()
  lazy var updates = UpdateController(settings: settings)
  private let attachServer: AttachServer
  var closePanel: (() -> Void)?
  private lazy var editorWindow = JobEditorWindowController(model: self)
  private lazy var terminalWindows = TerminalWindowRegistry(model: self)
  private var previewWindows: [UUID: PreviewTerminalWindowController] = [:]
  private var visibleTerminals: Set<UUID> = []
  private var panelVisible = false
  private var workspaceCancellables: Set<AnyCancellable> = []

  init() throws {
    let fileManager = FileManager.default
    let support: URL
    let logs: URL
    if let testDirectory = ProcessInfo.processInfo.environment["RUNSTUFF_DATA_DIRECTORY"] {
      support = URL(fileURLWithPath: testDirectory, isDirectory: true)
      logs = support.appendingPathComponent("logs", isDirectory: true)
    } else {
      support = try fileManager.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      )
      .appendingPathComponent("RunStuff", isDirectory: true)
      logs = try fileManager.url(
        for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
      )
      .appendingPathComponent("RunStuff", isDirectory: true)
    }
    let configStore = ConfigStore(fileURL: support.appendingPathComponent("config.json"))
    let configuration: RunStuffConfiguration
    let startupBanner: String?
    do {
      configuration = try configStore.loadOrEmpty()
      startupBanner = nil
    } catch {
      configuration = RunStuffConfiguration()
      startupBanner = "Could not load config.json: \(error)"
    }
    guard let helper = Bundle.main.url(forAuxiliaryExecutable: "runstuff-tty-helper") else {
      throw AppStartupError.missingTTYHelper
    }
    supervisor = try Supervisor(
      configuration: configuration,
      configStore: configStore,
      runtimeRegistry: RuntimeRegistry(fileURL: support.appendingPathComponent("runtime.json")),
      ttyHelperPath: helper.path,
      spoolDirectory: logs.path)
    attachServer = AttachServer(supervisor: supervisor)
    banner = startupBanner
    notifications.errorHandler = { [weak self] message in self?.banner = message }
    notifications.actionHandler = { [weak self] jobID, action in
      guard let self else { return }
      switch action {
      case .viewOutput:
        self.openTerminal(jobID)
      case .restart:
        self.restart(jobID)
      case .checkPortOwner(let port):
        self.checkPortOwner(port)
      case .openBrowser(let port):
        if let url = URL(string: "http://localhost:\(port)") {
          NSWorkspace.shared.open(url)
        }
      }
    }
    settings.$soundsEnabled.sink { [weak notifications] enabled in
      notifications?.soundsEnabled = enabled
    }.store(in: &workspaceCancellables)
    observeSleepAndWake()
  }

  func start() {
    Task { await notifications.refreshAuthorization() }
    updates.startIfConfigured()
    do {
      try attachServer.start()
    } catch {
      banner = "Could not start the attach server: \(error)"
    }
    Task {
      jobs = await supervisor.snapshots()
      do {
        try await supervisor.startWatchingConfiguration()
      } catch {
        banner = "Could not watch the configuration: \(error.localizedDescription)"
      }
      await supervisor.startSampling()
      for job in jobs {
        await supervisor.resolveDiagnostics(jobID: job.job.id)
        if job.job.autostartOnLaunch {
          do {
            try await supervisor.start(jobID: job.job.id)
          } catch {
            banner = "Could not start \(job.job.name): \(error.localizedDescription)"
          }
        }
      }
    }
    Task {
      for await event in supervisor.events {
        await handle(event)
      }
    }
  }

  func start(_ jobID: UUID) {
    Task { await notifications.requestPermission() }
    Task {
      do {
        try await supervisor.start(jobID: jobID)
      } catch {
        banner = "Could not start Stuff: \(error.localizedDescription)"
      }
    }
  }

  func openTerminal(_ jobID: UUID) {
    terminalWindows.show(jobID: jobID)
    closePanel?()
  }

  func openExternalTerminal(_ jobID: UUID) {
    do {
      guard let executable = Bundle.main.url(forAuxiliaryExecutable: "runstuff-cli") else {
        throw AppStartupError.missingCLI
      }
      let command =
        "\(ShellMode.shellQuote(executable.path)) attach \(ShellMode.shellQuote(jobID.uuidString))"
      let script = settings.externalTerminalTemplate.replacingOccurrences(
        of: "{command}", with: command)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/zsh")
      process.arguments = ["-l", "-c", script]
      try process.run()
      closePanel?()
    } catch {
      banner = "Could not open the external terminal: \(error.localizedDescription)"
    }
  }

  @discardableResult
  func testRun(_ job: Job) -> PreviewTerminalWindowController {
    var previewJob = job
    previewJob.id = UUID()
    let id = UUID()
    let controller = PreviewTerminalWindowController(job: previewJob, supervisor: supervisor) {
      [weak self] in
      self?.previewWindows[id] = nil
      self?.updateActivationPolicy()
    }
    previewWindows[id] = controller
    updateActivationPolicy()
    controller.show()
    return controller
  }

  func checkPortOwner(_ port: UInt16) {
    guard port > 0 else { return }
    let command = """
      owners=$(/usr/sbin/lsof -nP -iTCP:\(port) -sTCP:LISTEN)
      result=$?
      printf '%s\\n' "$owners"
      if [ "$result" -eq 1 ]; then
        printf '\\nNo TCP listener is visible on port \(port). It may have exited, or its details may require additional permissions.\\n'
      elif [ "$result" -ne 0 ]; then
        printf '\\nThe owner lookup failed. See the lsof message above.\\n'
      else
        pids=$(printf '%s\\n' "$owners" | /usr/bin/awk 'NR > 1 && $2 ~ /^[0-9]+$/ && $2 > 1 {print $2}' | /usr/bin/sort -un)
        printf '\\nCopy Stop Command\\n'
        printf '%s\\n' "$pids" | while IFS= read -r owner_pid; do
          [ -n "$owner_pid" ] && printf '  PID %s: kill -TERM %s\\n' "$owner_pid" "$owner_pid"
        done
        printf '\\nThis stops the process shown. Check the owner again if you run this later.\\n'
        printf 'Nothing will be stopped or restarted here.\\n\\n'
        printf 'Enter a PID above to copy its stop command (Return to finish): '
        IFS= read -r selected_pid
        if [ -n "$selected_pid" ]; then
          if printf '%s\\n' "$pids" | /usr/bin/grep -Fxq -- "$selected_pid"; then
            if printf 'kill -TERM %s' "$selected_pid" | /usr/bin/pbcopy; then
              printf '\\nCopied: kill -TERM %s\\nReview and run it in your terminal, then restart your Stuff.\\n' "$selected_pid"
            else
              printf '\\nCould not copy the command. Your clipboard may be unavailable.\\n'
            fi
          else
            printf '\\nThat PID was not in the owner lookup. Nothing was copied.\\n'
          fi
        fi
      fi
      """
    testRun(
      Job(
        name: "TCP port \(port) — current owner", command: command,
        workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
        shellMode: .login, colorSeed: 0))
    closePanel?()
  }

  func panelVisibilityChanged(_ visible: Bool) {
    panelVisible = visible
    updateForegroundSampling()
  }

  func terminalVisibilityChanged(jobID: UUID, visible: Bool) {
    if visible {
      visibleTerminals.insert(jobID)
    } else {
      visibleTerminals.remove(jobID)
    }
    updateActivationPolicy()
    updateForegroundSampling()
  }

  private func updateActivationPolicy() {
    let policy: NSApplication.ActivationPolicy =
      visibleTerminals.isEmpty && previewWindows.isEmpty ? .accessory : .regular
    if NSApp.activationPolicy() != policy {
      NSApp.setActivationPolicy(policy)
    }
  }

  func stop(_ jobID: UUID) {
    Task {
      do {
        try await supervisor.stop(jobID: jobID)
      } catch {
        banner = "Could not stop Stuff: \(error.localizedDescription)"
      }
    }
  }

  func restart(_ jobID: UUID) {
    Task {
      do {
        try await supervisor.restart(jobID: jobID)
      } catch {
        banner = "Could not restart Stuff: \(error.localizedDescription)"
      }
    }
  }

  func stopAll() async {
    let failures = await supervisor.stopAll()
    if !failures.isEmpty {
      let names = jobs.filter { failures.contains($0.job.id) }.map(\.job.name)
      banner = "Could not stop: \(names.joined(separator: ", "))."
    }
  }

  func prepareNewJob() {
    editorJob = Job(
      name: "",
      command: "",
      workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
      colorSeed: Int.random(in: 0..<Int.max))
    closePanel?()
    NSApp.activate(ignoringOtherApps: true)
  }

  func prepareToEdit(_ job: Job) {
    editorJob = job
    closePanel?()
    NSApp.activate(ignoringOtherApps: true)
  }

  func showNewJobEditor() {
    prepareNewJob()
    editorWindow.show()
  }

  func showEditor(for job: Job) {
    prepareToEdit(job)
    editorWindow.show()
  }

  func saveEditorJob(_ job: Job) async throws {
    if await supervisor.snapshot(jobID: job.id) == nil {
      try await supervisor.add(job)
    } else {
      try await supervisor.update(job)
    }
    editorJob = nil
    await supervisor.resolveDiagnostics(jobID: job.id)
  }

  func delete(_ jobID: UUID) async {
    do {
      try await supervisor.delete(jobID: jobID)
      jobs = await supervisor.snapshots()
    } catch {
      banner = "Could not delete Stuff: \(error.localizedDescription)"
    }
  }

  func update(_ job: Job) async {
    do {
      try await supervisor.update(job)
    } catch {
      banner = "Could not update Stuff: \(error.localizedDescription)"
    }
  }

  func resolveOrphan(_ jobID: UUID, action: OrphanAction) {
    Task {
      do {
        switch action {
        case .adopt:
          try await supervisor.adoptOrphan(jobID: jobID)
        case .stop:
          try await supervisor.stopOrphan(jobID: jobID)
        case .ignore:
          try await supervisor.ignoreOrphan(jobID: jobID)
        }
        orphans.removeAll { $0.jobID == jobID }
        if orphans.isEmpty { banner = nil }
      } catch {
        banner = "Could not resolve the previous process: \(error)"
      }
    }
  }

  func quit() {
    let running = runningJobs
    if running.isEmpty {
      NSApp.terminate(nil)
      return
    }
    let alert = NSAlert()
    alert.messageText = "Stop running stuff and quit?"
    alert.informativeText = running.map { $0.job.name }.joined(separator: ", ")
    alert.addButton(withTitle: "Stop All and Quit")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Task {
      let failures = await supervisor.stopAll()
      if failures.isEmpty {
        NSApp.terminate(nil)
      } else {
        let names = running.filter { failures.contains($0.job.id) }.map(\.job.name)
        banner =
          "RunStuff is still open because these could not be stopped: \(names.joined(separator: ", "))."
      }
    }
  }

  var runningJobs: [JobSnapshot] {
    jobs.filter { $0.pid != nil }
  }

  private func updateForegroundSampling() {
    let foreground = panelVisible || !visibleTerminals.isEmpty
    Task { await supervisor.setForegroundSampling(foreground) }
  }

  private func observeSleepAndWake() {
    let center = NSWorkspace.shared.notificationCenter
    center.publisher(for: NSWorkspace.willSleepNotification).sink { [weak self] _ in
      guard let self else { return }
      Task { await self.supervisor.setSleeping(true) }
    }.store(in: &workspaceCancellables)
    center.publisher(for: NSWorkspace.didWakeNotification).sink { [weak self] _ in
      guard let self else { return }
      Task { await self.supervisor.setSleeping(false) }
    }.store(in: &workspaceCancellables)
  }

  private func handle(_ event: SupervisorEvent) async {
    switch event {
    case .jobChanged(let snapshot):
      if case .starting = snapshot.state {
        if snapshot.job.openTerminalOnStart {
          openTerminal(snapshot.job.id)
        }
      }
      if let index = jobs.firstIndex(where: { $0.job.id == snapshot.job.id }) {
        jobs[index] = snapshot
      } else {
        jobs.append(snapshot)
      }
      jobs.sort { $0.job.name.localizedCaseInsensitiveCompare($1.job.name) == .orderedAscending }
    case .jobExited(let jobID, let status, let userInitiated, let failure, let reportedPortConflict):
      guard !userInitiated, let name = jobs.first(where: { $0.job.id == jobID })?.job.name else {
        return
      }
      Task {
        await notifications.jobExited(
          jobID: jobID, name: name, status: status, failure: failure,
          reportedPortConflict: reportedPortConflict)
      }
    case .jobFailedToStart(let jobID, let message):
      let name = jobs.first(where: { $0.job.id == jobID })?.job.name ?? "Stuff"
      Task { await notifications.failedToStart(jobID: jobID, name: name, message: message) }
    case .signalMatched(let jobID, let rule, let line, let shouldNotify):
      if shouldNotify {
        let name = jobs.first(where: { $0.job.id == jobID })?.job.name ?? "Stuff"
        Task { await notifications.signalMatched(jobID: jobID, name: name, rule: rule, line: line) }
      }
    case .readyDetected(let jobID, let port):
      if let job = jobs.first(where: { $0.job.id == jobID })?.job,
        job.notifyWhenReady
      {
        Task { await notifications.ready(jobID: jobID, name: job.name, port: port) }
      }
    case .waitingForInput(let jobID):
      let name = jobs.first(where: { $0.job.id == jobID })?.job.name ?? "Stuff"
      Task { await notifications.waitingForInput(jobID: jobID, name: name) }
    case .sustainedHighCPU(let jobID, let cpuPercent):
      let name = jobs.first(where: { $0.job.id == jobID })?.job.name ?? "Stuff"
      Task {
        await notifications.sustainedHighCPU(
          jobID: jobID, name: name, cpuPercent: cpuPercent)
      }
    case .restartScheduled(let jobID, _, let attempt):
      let name = jobs.first(where: { $0.job.id == jobID })?.job.name ?? "Stuff"
      Task { await notifications.restarting(jobID: jobID, name: name, attempt: attempt) }
    case .restartLoopExhausted(let jobID, let attempts):
      let name = jobs.first(where: { $0.job.id == jobID })?.job.name ?? "Stuff"
      Task {
        await notifications.restartLoopExhausted(jobID: jobID, name: name, attempts: attempts)
      }
    case .orphaned(let records):
      orphans = records
      banner =
        "\(records.count) process\(records.count == 1 ? "" : "es") from a previous session are still running."
    case .configurationReloaded:
      jobs = await supervisor.snapshots()
    case .persistenceFailed(let message):
      banner = "Could not reload config.json: \(message)"
    }
  }
}

enum OrphanAction {
  case adopt
  case stop
  case ignore
}

enum AppStartupError: Error {
  case missingTTYHelper
  case missingCLI
}

enum ExternalTerminalPreset: String, CaseIterable {
  case ghostty
  case iTerm2
  case wezTerm
  case terminal
  case custom

  var label: String {
    switch self {
    case .ghostty: "Ghostty"
    case .iTerm2: "iTerm2"
    case .wezTerm: "WezTerm"
    case .terminal: "Terminal"
    case .custom: "Custom"
    }
  }

  var template: String {
    switch self {
    case .ghostty:
      "if command -v ghostty >/dev/null; then ghostty -e {command}; else open -na Ghostty --args -e {command}; fi"
    case .iTerm2:
      "osascript -e \"tell application \\\"iTerm\\\" to create window with default profile command \\\"{command}\\\"\" -e \"tell application \\\"iTerm\\\" to activate\""
    case .wezTerm:
      "if command -v wezterm >/dev/null; then wezterm start -- {command}; else open -na WezTerm --args start -- {command}; fi"
    case .terminal:
      "osascript -e \"tell application \\\"Terminal\\\" to do script \\\"{command}\\\"\" -e \"tell application \\\"Terminal\\\" to activate\""
    case .custom:
      "{command}"
    }
  }
}

@MainActor
final class AppSettings: ObservableObject {
  @Published var terminalFontSize: Double {
    didSet { defaults.set(terminalFontSize, forKey: "terminalFontSize") }
  }
  @Published var soundsEnabled: Bool {
    didSet { defaults.set(soundsEnabled, forKey: "soundsEnabled") }
  }
  @Published var terminalTheme: TerminalTheme {
    didSet { defaults.set(terminalTheme.rawValue, forKey: "terminalTheme") }
  }
  @Published var externalTerminalPreset: ExternalTerminalPreset {
    didSet { defaults.set(externalTerminalPreset.rawValue, forKey: "externalTerminalPreset") }
  }
  @Published var externalTerminalTemplate: String {
    didSet { defaults.set(externalTerminalTemplate, forKey: "externalTerminalTemplate") }
  }
  @Published var updateFeedURL: String {
    didSet { defaults.set(updateFeedURL, forKey: "updateFeedURL") }
  }
  @Published private(set) var launchAtLogin: Bool
  @Published private(set) var errorMessage: String?
  @Published private(set) var cliStatus: String?

  private let defaults = UserDefaults.standard

  init() {
    let savedSize = defaults.double(forKey: "terminalFontSize")
    terminalFontSize = savedSize == 0 ? 13 : savedSize
    soundsEnabled = defaults.object(forKey: "soundsEnabled") as? Bool ?? true
    terminalTheme =
      TerminalTheme(rawValue: defaults.string(forKey: "terminalTheme") ?? "") ?? .system
    externalTerminalPreset =
      ExternalTerminalPreset(rawValue: defaults.string(forKey: "externalTerminalPreset") ?? "")
      ?? .ghostty
    externalTerminalTemplate =
      defaults.string(forKey: "externalTerminalTemplate")
      ?? ExternalTerminalPreset.ghostty.template
    updateFeedURL = defaults.string(forKey: "updateFeedURL") ?? ""
    launchAtLogin = SMAppService.mainApp.status == .enabled
  }

  func selectTerminalPreset(_ preset: ExternalTerminalPreset) {
    externalTerminalPreset = preset
    if preset != .custom { externalTerminalTemplate = preset.template }
  }

  func installCLI() {
    let alert = NSAlert()
    alert.messageText = "Install the runstuff command?"
    alert.informativeText =
      "RunStuff will create /usr/local/bin/runstuff as a symbolic link to the command inside this app. Existing files are never replaced."
    alert.addButton(withTitle: "Install")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    do {
      guard let source = Bundle.main.url(forAuxiliaryExecutable: "runstuff-cli") else {
        throw AppStartupError.missingCLI
      }
      let destination = URL(fileURLWithPath: "/usr/local/bin/runstuff")
      let fileManager = FileManager.default
      let destinationExists =
        fileManager.fileExists(atPath: destination.path)
        || (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) != nil
      guard !destinationExists else {
        cliStatus = "A file already exists at /usr/local/bin/runstuff."
        return
      }
      let binDirectory = destination.deletingLastPathComponent()
      let canInstallDirectly =
        fileManager.fileExists(atPath: binDirectory.path)
        ? fileManager.isWritableFile(atPath: binDirectory.path)
        : fileManager.isWritableFile(atPath: binDirectory.deletingLastPathComponent().path)
      if canInstallDirectly {
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)
      } else {
        let command =
          "/bin/mkdir -p /usr/local/bin && /bin/ln -s \(ShellMode.shellQuote(source.path)) /usr/local/bin/runstuff"
        let escapedCommand =
          command
          .replacingOccurrences(of: "\\", with: "\\\\")
          .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [
          "-e", "do shell script \"\(escapedCommand)\" with administrator privileges",
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteNoPermission) }
      }
      cliStatus = "Installed /usr/local/bin/runstuff"
    } catch {
      cliStatus = "Could not install the command: \(error.localizedDescription)"
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      launchAtLogin = enabled
      errorMessage = nil
    } catch {
      launchAtLogin = SMAppService.mainApp.status == .enabled
      errorMessage = "Could not update launch at login: \(error.localizedDescription)"
    }
  }
}

@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
  private let settings: AppSettings
  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
  @Published private(set) var status: String?
  private var started = false

  init(settings: AppSettings) {
    self.settings = settings
  }

  func startIfConfigured() {
    guard !started, feedURLString(for: controller.updater) != nil else { return }
    controller.startUpdater()
    started = true
  }

  func checkForUpdates() {
    startIfConfigured()
    guard started else {
      status = "Enter an HTTPS appcast URL first."
      return
    }
    status = nil
    controller.checkForUpdates(nil)
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    let value = settings.updateFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: value), url.scheme == "https" else { return nil }
    return value
  }
}

enum TerminalTheme: String, CaseIterable {
  case system
  case dark
  case light

  var label: String { rawValue.capitalized }
}
