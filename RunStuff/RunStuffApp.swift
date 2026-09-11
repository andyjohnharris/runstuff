import AppKit
import SwiftUI

final class RunStuffAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }
}

@main
struct RunStuffApp: App {
  @NSApplicationDelegateAdaptor(RunStuffAppDelegate.self) private var appDelegate
  @StateObject private var model: AppModel
  private let statusItemController: StatusItemController

  init() {
    do {
      let model = try AppModel()
      _model = StateObject(wrappedValue: model)
      let controller = StatusItemController(model: model)
      statusItemController = controller
      model.start()
    } catch {
      fatalError("RunStuff could not start: \(error)")
    }
  }

  var body: some Scene {
    Settings {
      SettingsView(settings: model.settings, updates: model.updates)
    }
  }
}
