//  What happens when a launch that was queued or provisioning becomes ready to play while OpenNOW
//  is not the frontmost application: a system notification, or the app coming to the front on its
//  own. Either way a long queue can be waited out in another window.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
enum OpenNOWSessionReadyAction {
    enum Mode: String, CaseIterable {
        case notification
        case bringToFront

        var label: String {
            switch self {
            case .notification: "Notification"
            case .bringToFront: "Bring to Front"
            }
        }
    }

    static let modeKey = "OpenNOW.Interface.SessionReadyAction"
    private static let notificationIdentifier = "io.github.opencloudgaming.opennow.session-ready"
    private static var didRequestAuthorization = false

    static var mode: Mode {
        get { Mode(rawValue: OPNAppPreferenceStorage.standard.string(forKey: modeKey) ?? "") ?? .notification }
        set { OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Asks for notification permission while the user is looking at the launch overlay, so the
    /// system prompt appears in context rather than over another application when the seat is
    /// finally ready. Asks at most once per run and only while the status is undetermined.
    static func prepareAuthorizationIfNeeded() {
        guard mode == .notification, !didRequestAuthorization, Bundle.main.bundleIdentifier != nil else { return }
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

    /// Runs the chosen action unless the app is already frontmost, in which case the stream
    /// surface itself is the announcement.
    static func sessionDidBecomeReady(title: String) {
        guard !NSApplication.shared.isActive else { return }
        switch mode {
        case .notification:
            postNotification(title: title)
        case .bringToFront:
            bringToFront()
        }
    }

    /// Activates the app and raises its windows. macOS may refuse an activation the user did not
    /// initiate; the Dock bounce is the fallback so the ready state is still visible.
    private static func bringToFront() {
        let app = NSApplication.shared
        app.activate(ignoringOtherApps: true)
        for window in app.windows where window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        if app.isActive {
            OpenNOWLog.info(.app, "Session ready: brought OpenNOW to the front")
        } else {
            app.requestUserAttention(.criticalRequest)
            OpenNOWLog.info(.app, "Session ready: activation refused by the system, bouncing the Dock icon instead")
        }
    }

    private static func postNotification(title: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
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
