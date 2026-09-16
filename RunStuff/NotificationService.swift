import Combine
import Foundation
import RunStuffCore
import UserNotifications

enum NotificationAction: Sendable {
  case viewOutput
  case restart
  case openBrowser(UInt16)
  case checkPortOwner(UInt16)
}

@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  var actionHandler: ((UUID, NotificationAction) -> Void)?
  var errorHandler: ((String) -> Void)?
  var soundsEnabled = true
  @Published private(set) var permissionSummary = "Checking notification permission…"
  @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
  private var authorizationTask: Task<Void, Never>?
  private var lastSoundAt = Date.distantPast

  override init() {
    super.init()
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: "RunStuff.PortConflict",
        actions: [
          UNNotificationAction(
            identifier: "checkPort", title: "Check Port Owner", options: [.foreground]),
          UNNotificationAction(identifier: "view", title: "View Output", options: [.foreground]),
          UNNotificationAction(identifier: "restart", title: "Restart"),
        ], intentIdentifiers: []),
      UNNotificationCategory(
        identifier: "RunStuff.Failure",
        actions: [
          UNNotificationAction(identifier: "view", title: "View Output", options: [.foreground]),
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

  func jobExited(
    jobID: UUID, name: String, status: ExitStatus, failure: FailureDiagnostic?,
    reportedPortConflict: FailureDiagnostic?
  ) async {
    if let failure {
      await send(
        jobID: jobID, port: failure.conflictingPort, title: "\(name) reported a failure",
        body: failure.summary,
        category: failure.conflictingPort == nil ? "RunStuff.Failure" : "RunStuff.PortConflict",
        sound: true)
      return
    }
    switch status {
    case .exited(let code) where code == 0:
      if let port = reportedPortConflict?.conflictingPort {
        await send(
          jobID: jobID, port: port, title: "\(name) finished — check output",
          body: "Output reported TCP port \(port) already in use. The command exited with code 0.",
          category: "RunStuff.PortConflict", sound: true)
        return
      }
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
        body: "The command stopped unexpectedly. View Output for details.",
        category: "RunStuff.Failure", sound: true)
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

  func signalMatched(jobID: UUID, name: String, rule: SignalRule, line: String) async {
    let diagnostic = FailureDiagnostic.matchedLine(line)
    await send(
      jobID: jobID, port: diagnostic.conflictingPort,
      title: "\(name): \(rule.severity.rawValue)", body: diagnostic.summary,
      category: diagnostic.conflictingPort == nil ? "RunStuff.Failure" : "RunStuff.PortConflict",
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

  func refreshAuthorization() async {
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    authorizationStatus = settings.authorizationStatus
    switch settings.authorizationStatus {
    case .notDetermined:
      permissionSummary = "Enable notifications to receive exit and failure alerts."
    case .denied:
      permissionSummary =
        "Notifications are disabled. Enable RunStuff in System Settings → Notifications."
    case .authorized, .provisional, .ephemeral:
      permissionSummary =
        settings.alertSetting == .enabled
        ? "Notifications are enabled. Focus and macOS settings may silence alerts."
        : "Notification banners are disabled. Check RunStuff in System Settings → Notifications."
    @unknown default:
      permissionSummary = "Check RunStuff in System Settings → Notifications."
    }
  }

  func requestPermission() async {
    if let authorizationTask {
      await authorizationTask.value
      return
    }
    let task = Task { @MainActor in
      do {
        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [
          .alert, .sound,
        ])
      } catch {
        errorHandler?("Could not request notification permission: \(error.localizedDescription)")
      }
      await refreshAuthorization()
    }
    authorizationTask = task
    await task.value
    authorizationTask = nil
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
    await refreshAuthorization()
    if authorizationStatus == .notDetermined { await requestPermission() }
    guard authorizationStatus == .authorized || authorizationStatus == .provisional else {
      errorHandler?(permissionSummary)
      return
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
    do {
      try await center.add(
        UNNotificationRequest(
          identifier: "\(jobID.uuidString).\(category)", content: content, trigger: nil))
    } catch {
      errorHandler?("Could not deliver a notification for \(title): \(error.localizedDescription)")
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list, .sound])
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
    case "checkPort":
      action = port.flatMap { $0 > 0 ? .checkPortOwner($0) : nil }
    default:
      action = nil
    }
    completionHandler()
    Task { @MainActor [weak self] in
      if let jobID, let action { self?.actionHandler?(jobID, action) }
    }
  }
}
