import Foundation
import UserNotifications

enum Notifier {
    /// UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run`).
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func configure() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = ForegroundPresenter.shared
    }

    /// Calls back on the main actor with whether notifications are allowed.
    static func requestAuthorization(_ completion: @escaping @Sendable @MainActor (Bool) -> Void) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }

    static func isAuthorized(_ completion: @escaping @Sendable @MainActor (Bool) -> Void) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = [.authorized, .provisional, .notDetermined].contains(settings.authorizationStatus)
            Task { @MainActor in completion(authorized) }
        }
    }

    static func post(_ result: SpeedTestResult) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Speed test complete"
        var body = "↓ \(SpeedFormat.mbps(result.downloadMbps)) Mbps   ↑ \(SpeedFormat.mbps(result.uploadMbps)) Mbps"
        if let ping = result.pingMs { body += "   ·   \(SpeedFormat.ms(ping)) ms ping" }
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: result.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Shows banners even while the popover makes the app active.
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = ForegroundPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
