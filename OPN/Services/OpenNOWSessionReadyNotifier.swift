//  Posts a system notification when a launch that was queued or provisioning becomes ready to
//  play while OpenNOW is not the frontmost application. The official client does the same, and
//  it is the only way a long queue can be waited out in another window.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
enum OpenNOWSessionReadyNotifier {
    static let enabledKey = "OpenNOW.Interface.SessionReadyNotificationsEnabled"
    private static let notificationIdentifier = "io.github.opencloudgaming.opennow.session-ready"
    private static var didRequestAuthorization = false

    static var isEnabled: Bool {
        get {
            guard let stored = OPNAppPreferenceStorage.standard.object(forKey: enabledKey) as? Bool else { return true }
            return stored
        }
        set { OPNAppPreferenceStorage.standard.set(newValue, forKey: enabledKey) }
    }

    /// Asks for notification permission while the user is looking at the launch overlay, so the
    /// system prompt appears in context rather than over another application when the seat is
    /// finally ready. Asks at most once per run and only while the status is undetermined.
    static func prepareAuthorizationIfNeeded() {
        guard isEnabled, !didRequestAuthorization, Bundle.main.bundleIdentifier != nil else { return }
        didRequestAuthorization = true
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                OpenNOWLog.info(.app, "Notification authorization \(granted ? "granted" : "denied")")
            } catch {
                OpenNOWLog.warning(.app, "Notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Delivers the ready notification unless the app is already frontmost, in which case the
    /// stream surface itself is the announcement.
    static func sessionDidBecomeReady(title: String) {
        guard isEnabled, !NSApplication.shared.isActive, Bundle.main.bundleIdentifier != nil else { return }
        let gameTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                status = (try? await center.requestAuthorization(options: [.alert, .sound])) == true ? .authorized : .denied
            }
            guard status == .authorized || status == .provisional else {
                OpenNOWLog.info(.app, "Session ready notification skipped: authorization status \(status.rawValue)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = gameTitle.isEmpty ? "Your session is ready" : "\(gameTitle) is ready"
            content.body = "Your GeForce NOW session is ready to play."
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: nil))
                OpenNOWLog.info(.app, "Session ready notification posted for \(gameTitle.isEmpty ? "the session" : gameTitle)")
            } catch {
                OpenNOWLog.warning(.app, "Session ready notification failed: \(error.localizedDescription)")
            }
        }
    }

    /// Removes a delivered ready notification once the user is back in the app.
    static func clearDelivered() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
    }
}
