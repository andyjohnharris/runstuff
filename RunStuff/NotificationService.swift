import Foundation
import RunStuffCore
import UserNotifications

enum NotificationAction: Sendable {
  case viewOutput
  case restart
  case openBrowser(UInt16)
}

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
  var actionHandler: ((UUID, NotificationAction) -> Void)?
  var soundsEnabled = true
  private var authorizationRequested = false
  private var lastSoundAt = Date.distantPast

  override init() {
    super.init()
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: "RunStuff.Failure",
        actions: [
          UNNotificationAction(identifier: "view", title: "View Output"),
          UNNotificationAction(identifier: "restart", title: "Restart"),
        ],
        intentIdentifiers: []),
      UNNotificationCategory(
        identifier: "RunStuff.Finished",
        actions: [UNNotificationAction(identifier: "restart", title: "Restart")],
        intentIdentifiers: []),
      UNNotificationCategory(
        identifier: "RunStuff.Ready",
        actions: [
          UNNotificationAction(identifier: "browser", title: "Open in Browser"),
          UNNotificationAction(identifier: "view", title: "View Output"),
        ],
        intentIdentifiers: []),
      UNNotificationCategory(
        identifier: "RunStuff.ReadyWithoutPort",
        actions: [UNNotificationAction(identifier: "view", title: "View Output")],
        intentIdentifiers: []),
      UNNotificationCategory(
        identifier: "RunStuff.Waiting",
        actions: [UNNotificationAction(identifier: "view", title: "View Output")],
        intentIdentifiers: []),
    ])
  }

  func jobExited(jobID: UUID, name: String, status: ExitStatus) async {
    switch status {
    case .exited(let code) where code == 0:
      await send(
        jobID: jobID, title: "\(name) finished", body: "Exited successfully",
        category: "RunStuff.Finished", sound: false)
    case .exited(let code) where code == 127:
      await send(
        jobID: jobID, title: "\(name) failed to start", body: RunStuffMessage.commandNotFound,
        category: "RunStuff.Failure", sound: true)
    case .exited(let code):
      await send(
        jobID: jobID, title: "\(name) exited with code \(code)",
        body: "Open RunStuff to view its output", category: "RunStuff.Failure", sound: true)
    case .signalled(let signal, _):
      await send(
        jobID: jobID, title: "\(name) crashed", body: signalName(signal),
        category: "RunStuff.Failure", sound: true)
    }
  }

  func failedToStart(jobID: UUID, name: String, message: String) async {
    await send(
      jobID: jobID, title: "\(name) failed to start", body: message,
      category: "RunStuff.Failure", sound: true)
  }

  func signalMatched(jobID: UUID, name: String, rule: SignalRule) async {
    await send(
      jobID: jobID, title: "\(name): \(rule.severity.rawValue)", body: rule.pattern,
      category: "RunStuff.Failure",
      interruptionLevel: rule.severity == .error ? .active : .passive,
      sound: rule.severity == .error)
  }

  func ready(jobID: UUID, name: String, port: UInt16?) async {
    let body = port.map { "Listening on localhost:\($0)" } ?? "Ready rule matched"
    await send(
      jobID: jobID, port: port, title: "\(name) is ready", body: body,
      category: port == nil ? "RunStuff.ReadyWithoutPort" : "RunStuff.Ready",
      interruptionLevel: .passive, sound: false)
  }

  func restarting(jobID: UUID, name: String, attempt: Int) async {
    await send(
      jobID: jobID, title: "\(name) crashed", body: "Restarting (attempt \(attempt))",
      category: "RunStuff.Failure", interruptionLevel: .passive, sound: false)
  }

  func restartLoopExhausted(jobID: UUID, name: String, attempts: Int) async {
    await send(
      jobID: jobID, title: "\(name) stopped restarting",
      body: "Gave up after \(attempts) restarts", category: "RunStuff.Failure", sound: true)
  }

  func waitingForInput(jobID: UUID, name: String) async {
    await send(
      jobID: jobID, title: "\(name) is waiting for input",
      body: "Open its output to respond", category: "RunStuff.Waiting", sound: false)
  }

  func sustainedHighCPU(jobID: UUID, name: String, cpuPercent: Double) async {
    await send(
      jobID: jobID, title: "\(name) is using high CPU",
      body: "CPU has remained above 80% and is now \(Int(cpuPercent.rounded()))%",
      category: "RunStuff.Failure", interruptionLevel: .passive, sound: false)
  }

  private func send(
    jobID: UUID,
    port: UInt16? = nil,
    title: String,
    body: String,
    category: String,
    interruptionLevel: UNNotificationInterruptionLevel = .active,
    sound: Bool
  ) async {
    let center = UNUserNotificationCenter.current()
    if !authorizationRequested {
      authorizationRequested = true
      guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else {
        return
      }
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.categoryIdentifier = category
    content.interruptionLevel = interruptionLevel
    var userInfo: [String: Any] = ["jobID": jobID.uuidString]
    if let port { userInfo["port"] = Int(port) }
    content.userInfo = userInfo
    if sound && soundsEnabled && Date().timeIntervalSince(lastSoundAt) >= 10 {
      content.sound = UNNotificationSound(
        named: UNNotificationSoundName("RunStuffError.wav"))
      lastSoundAt = Date()
    }
    try? await center.add(
      UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil))
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    let jobID = (info["jobID"] as? String).flatMap(UUID.init(uuidString:))
    let port = (info["port"] as? NSNumber).flatMap { UInt16(exactly: $0.intValue) }
    let action: NotificationAction?
    switch response.actionIdentifier {
    case "view", UNNotificationDefaultActionIdentifier:
      action = .viewOutput
    case "restart":
      action = .restart
    case "browser":
      action = port.map(NotificationAction.openBrowser)
    default:
      action = nil
    }
    completionHandler()
    Task { @MainActor [weak self] in
      if let jobID, let action { self?.actionHandler?(jobID, action) }
    }
  }
}
