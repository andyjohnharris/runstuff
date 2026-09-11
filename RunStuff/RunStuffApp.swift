import RunStuffCore
import SwiftUI

@main
struct RunStuffApp: App {
  @StateObject private var model: AppModel
  private let statusItemController: StatusItemController

  init() {
    do {
      let model = try AppModel()
      _model = StateObject(wrappedValue: model)
      let controller = StatusItemController(model: model)
      statusItemController = controller
      model.start()
      if ProcessInfo.processInfo.environment["RUNSTUFF_OPEN_PANEL"] == "1" {
        DispatchQueue.main.async {
          controller.showPanel()
          if let path = ProcessInfo.processInfo.environment["RUNSTUFF_SCREENSHOT"] {
            let delay =
              ProcessInfo.processInfo.environment["RUNSTUFF_SCREENSHOT_DELAY"]
              .flatMap(Double.init) ?? 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
              controller.capturePanel(to: path)
              if ProcessInfo.processInfo.environment["RUNSTUFF_EXIT_AFTER_SCREENSHOT"] == "1" {
                Task {
                  await model.stopAll()
                  NSApp.terminate(nil)
                }
              }
            }
          }
        }
      }
      if let path = ProcessInfo.processInfo.environment["RUNSTUFF_SCREENSHOT_EDITOR"] {
        DispatchQueue.main.async {
          controller.captureEditor(to: path)
          if ProcessInfo.processInfo.environment["RUNSTUFF_EXIT_AFTER_SCREENSHOT"] == "1" {
            Task {
              await model.stopAll()
              NSApp.terminate(nil)
            }
          }
        }
      }
      if let path = ProcessInfo.processInfo.environment["RUNSTUFF_SCREENSHOT_SETTINGS"] {
        DispatchQueue.main.async {
          controller.captureSettings(to: path)
          if ProcessInfo.processInfo.environment["RUNSTUFF_EXIT_AFTER_SCREENSHOT"] == "1" {
            Task {
              await model.stopAll()
              NSApp.terminate(nil)
            }
          }
        }
      }
      if let path = ProcessInfo.processInfo.environment["RUNSTUFF_SCREENSHOT_RECOVERY"] {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          controller.captureRecovery(to: path)
          if ProcessInfo.processInfo.environment["RUNSTUFF_EXIT_AFTER_SCREENSHOT"] == "1" {
            Task {
              for orphan in model.orphans {
                try? await model.supervisor.stopOrphan(jobID: orphan.jobID, grace: .seconds(1))
              }
              NSApp.terminate(nil)
            }
          }
        }
      }
      if let path = ProcessInfo.processInfo.environment["RUNSTUFF_SCREENSHOT_TERMINAL"] {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          guard let job = model.jobs.first else { return }
          model.openTerminal(job.job.id)
          model.start(job.job.id)
          DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            model.captureTerminal(job.job.id, to: path)
          }
        }
      }
      if let path = ProcessInfo.processInfo.environment["RUNSTUFF_SCREENSHOT_PREVIEW"] {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          let job = Job(
            name: "Preview",
            command: "/bin/echo Preview output",
            workingDirectory: FileManager.default.temporaryDirectory,
            shellMode: .direct,
            colorSeed: 0)
          let preview = model.testRun(job)
          DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            preview.capture(to: path)
            preview.window?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
              NSApp.terminate(nil)
            }
          }
        }
      }
    } catch {
      fatalError("RunStuff could not start: \(error)")
    }
  }

  var body: some Scene {
    Window("Add Stuff", id: "editor") {
      JobEditorHost(model: model)
    }
    .defaultSize(width: 560, height: 820)

    Settings {
      SettingsView(settings: model.settings, updates: model.updates)
    }
  }
}
