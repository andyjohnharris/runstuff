import AppKit
import RunStuffCore
import SwiftUI

struct JobEditorHost: View {
  @ObservedObject var model: AppModel

  var body: some View {
    if let job = model.editorJob {
      JobEditorView(model: model, original: job)
        .id(job.id)
    } else {
      ContentUnavailableView("No Stuff Selected", systemImage: "terminal")
    }
  }
}

private struct JobEditorView: View {
  @ObservedObject var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var job: Job
  @State private var errorMessage: String?
  @State private var newEnvironmentKey = ""
  @State private var newEnvironmentValue = ""
  @State private var commandSuggestions: [String] = []

  init(model: AppModel, original: Job) {
    self.model = model
    _job = State(initialValue: original)
  }

  var body: some View {
    VStack(spacing: 0) {
      Form {
        Section("Stuff") {
          TextField("Name", text: $job.name)
          HStack {
            TextField(
              "Folder",
              text: Binding(
                get: { job.workingDirectory.path },
                set: { job.workingDirectory = URL(fileURLWithPath: $0) }))
            Button("Choose…") { chooseFolder() }
            if !recentFolders.isEmpty {
              Menu("Recent") {
                ForEach(recentFolders, id: \.path) { folder in
                  Button(folder.path) { selectFolder(folder) }
                }
              }
            }
          }
          .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first, folderHasDirectoryResource(folder) else { return false }
            selectFolder(folder)
            return true
          }
          TextField("Command", text: $job.command, axis: .vertical)
            .font(.system(.body, design: .monospaced))
            .lineLimit(2...5)
          if !commandSuggestions.isEmpty {
            Menu("Suggested Commands") {
              ForEach(commandSuggestions, id: \.self) { command in
                Button(command) { job.command = command }
              }
            }
          }
          Picker("Shell", selection: $job.shellMode) {
            ForEach(ShellMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          if let warning = shellWarning {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section("Environment") {
          ForEach(job.env.keys.sorted(), id: \.self) { key in
            HStack {
              Text(key).font(.system(.body, design: .monospaced))
              TextField(
                "Value",
                text: Binding(
                  get: { job.env[key, default: ""] },
                  set: { job.env[key] = $0 }))
              Button {
                job.env[key] = nil
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.plain)
            }
          }
          HStack {
            TextField("Name", text: $newEnvironmentKey)
              .font(.system(.body, design: .monospaced))
            TextField("Value", text: $newEnvironmentValue)
            Button("Add") { addEnvironmentValue() }
              .disabled(newEnvironmentKey.isEmpty)
          }
          Text(
            "Use ${keychain:name} to read a generic-password item in the dev.runstuff.environment service when this Stuff starts."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }

        Section("Behaviour") {
          Toggle("Open terminal on start", isOn: $job.openTerminalOnStart)
          Toggle("Start when RunStuff launches", isOn: $job.autostartOnLaunch)
          Toggle("Restart if it crashes", isOn: $job.restartOnCrash)
          if job.restartOnCrash {
            Stepper("Maximum restarts: \(job.maxRestarts)", value: $job.maxRestarts, in: 0...10)
          }
          Picker("Ready when", selection: readyRuleKind) {
            Text("Not configured").tag(ReadyRuleKind.none)
            Text("Output contains text").tag(ReadyRuleKind.output)
            Text("Port is listening").tag(ReadyRuleKind.port)
          }
          if case .outputPattern(let pattern) = job.readyRule {
            TextField(
              "Ready text",
              text: Binding(
                get: { pattern },
                set: { job.readyRule = .outputPattern($0) }))
          } else if case .port(let port) = job.readyRule {
            TextField(
              "Port",
              text: Binding(
                get: { String(port) },
                set: { job.readyRule = .port(Int($0) ?? 0) }))
          }
          if job.readyRule != nil {
            Toggle("Notify when ready", isOn: $job.notifyWhenReady)
          }
          Toggle("Notify when waiting for input", isOn: $job.notifyWhenWaitingForInput)
          Text("Prompt detection is a best-effort guess and is off by default.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Toggle("Notify after two minutes of high CPU", isOn: $job.notifyOnHighCPU)
        }

        Section("Signal Rules") {
          if job.signals.isEmpty {
            Text("No output patterns configured.")
              .foregroundStyle(.secondary)
          }
          ForEach(job.signals.indices, id: \.self) { index in
            VStack(alignment: .leading) {
              HStack {
                TextField("Pattern", text: $job.signals[index].pattern)
                Picker("", selection: $job.signals[index].severity) {
                  Text("Info").tag(Severity.info)
                  Text("Warning").tag(Severity.warning)
                  Text("Error").tag(Severity.error)
                }
                .labelsHidden()
                Toggle("Notify", isOn: $job.signals[index].notify)
                Button {
                  job.signals.remove(at: index)
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
              }
              HStack {
                Toggle("Regular expression", isOn: $job.signals[index].isRegex)
                Toggle("Case-sensitive", isOn: $job.signals[index].caseSensitive)
              }
              .font(.caption)
            }
          }
          HStack {
            Button("Add Rule", systemImage: "plus") {
              job.signals.append(SignalRule(pattern: "", severity: .warning, notify: false))
            }
            Menu("Suggested Rules") {
              ForEach(Self.suggestedRules, id: \.pattern) { rule in
                Button(rule.pattern) { addSuggestedRule(rule) }
                  .disabled(job.signals.contains { $0.pattern == rule.pattern })
              }
            }
          }
        }

        if let errorMessage {
          Text(errorMessage).foregroundStyle(.red)
        }
      }
      .formStyle(.grouped)

      Divider()
      HStack {
        Button("Cancel") { dismiss() }
        Button("Test Run", systemImage: "play.fill") { model.testRun(job) }
          .disabled(!canTest)
        Spacer()
        Button("Save") { save() }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(!isValid)
      }
      .padding()
    }
    .frame(minWidth: 560, minHeight: 820)
    .navigationTitle(model.jobs.contains { $0.job.id == job.id } ? "Edit Stuff" : "Add Stuff")
    .onAppear { commandSuggestions = suggestedCommands(in: job.workingDirectory) }
  }

  private var isValid: Bool {
    !job.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !job.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && FileManager.default.fileExists(atPath: job.workingDirectory.path)
      && job.signals.allSatisfy { !$0.pattern.isEmpty }
      && readyRuleIsValid
  }

  private var canTest: Bool {
    !job.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && FileManager.default.fileExists(atPath: job.workingDirectory.path)
  }

  private var readyRuleKind: Binding<ReadyRuleKind> {
    Binding(
      get: {
        switch job.readyRule {
        case nil: .none
        case .outputPattern: .output
        case .port: .port
        }
      },
      set: { kind in
        switch kind {
        case .none: job.readyRule = nil
        case .output: job.readyRule = .outputPattern("")
        case .port: job.readyRule = .port(3000)
        }
      })
  }

  private var readyRuleIsValid: Bool {
    switch job.readyRule {
    case nil: true
    case .outputPattern(let pattern): !pattern.isEmpty
    case .port(let port): (1...65_535).contains(port)
    }
  }

  private func addSuggestedRule(_ rule: SignalRule) {
    guard !job.signals.contains(where: { $0.pattern == rule.pattern }) else { return }
    job.signals.append(rule)
  }

  private static let suggestedRules = [
    SignalRule(pattern: "EADDRINUSE", severity: .error, notify: true),
    SignalRule(pattern: "ELIFECYCLE", severity: .error, notify: true),
    SignalRule(pattern: "Cannot find module", severity: .error, notify: true),
  ]

  private var shellWarning: String? {
    let directory = job.workingDirectory
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".nvmrc").path),
      job.shellMode != .interactiveLogin
    {
      return "This folder has an .nvmrc. Interactive login usually loads nvm."
    }
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".envrc").path) {
      return "RunStuff does not automatically load this folder's .envrc."
    }
    return nil
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = job.workingDirectory
    guard panel.runModal() == .OK, let url = panel.url else { return }
    selectFolder(url)
  }

  private var recentFolders: [URL] {
    (UserDefaults.standard.stringArray(forKey: "recentProjectFolders") ?? [])
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  private func selectFolder(_ url: URL) {
    job.workingDirectory = url
    if job.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      job.name = url.lastPathComponent
    }
    commandSuggestions = suggestedCommands(in: url)
    var paths = recentFolders.map(\.path)
    paths.removeAll { $0 == url.path }
    paths.insert(url.path, at: 0)
    UserDefaults.standard.set(Array(paths.prefix(6)), forKey: "recentProjectFolders")
  }

  private func addEnvironmentValue() {
    job.env[newEnvironmentKey] = newEnvironmentValue
    newEnvironmentKey = ""
    newEnvironmentValue = ""
  }

  private func save() {
    Task {
      do {
        try await model.saveEditorJob(job)
        dismiss()
      } catch {
        errorMessage = String(describing: error)
      }
    }
  }
}

private func folderHasDirectoryResource(_ url: URL) -> Bool {
  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
}

private func suggestedCommands(in folder: URL) -> [String] {
  var commands: [String] = []
  let packageURL = folder.appendingPathComponent("package.json")
  if let data = try? Data(contentsOf: packageURL),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let scripts = object["scripts"] as? [String: Any]
  {
    let names = scripts.keys.sorted { left, right in
      let priorities = ["dev", "start"]
      return (priorities.firstIndex(of: left) ?? Int.max, left)
        < (priorities.firstIndex(of: right) ?? Int.max, right)
    }
    commands.append(contentsOf: names.map { "npm run \($0)" })
  }
  let makefileURL = folder.appendingPathComponent("Makefile")
  if let makefile = try? String(contentsOf: makefileURL, encoding: .utf8) {
    let targets = makefile.split(separator: "\n").compactMap { line -> String? in
      guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix("."),
        !line.hasPrefix("#")
      else { return nil }
      let target = line[..<colon].trimmingCharacters(in: .whitespaces)
      return target.isEmpty || target.contains("%") || target.contains("=") ? nil : "make \(target)"
    }
    commands.append(contentsOf: targets.prefix(8))
  }
  if ["compose.yml", "compose.yaml", "docker-compose.yml", "docker-compose.yaml"].contains(where: {
    FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
  }) {
    commands.append("docker compose up")
  }
  return Array(commands.prefix(12))
}

private enum ReadyRuleKind {
  case none
  case output
  case port
}

extension ShellMode {
  fileprivate var displayName: String {
    switch self {
    case .login: "Login shell"
    case .interactiveLogin: "Interactive login shell"
    case .direct: "Direct"
    }
  }
}
