//  What happens when a maintenance-watched title comes back: a system notification per edge, a
//  critical Dock attention request that keeps bouncing until OpenNOW is activated, and an in-app
//  status line when OpenNOW is already frontmost. A sibling of `OPNSessionReadyAction` rather than a
//  reuse of it: a session becoming ready and a watched title returning are different promises with
//  different copy, and the session path activates the app for a game about to be streamed.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
enum OPNMaintenanceWatchAction {
    private static let notificationIdentifierPrefix = "io.github.opencloudgaming.opennow.maintenance-watch"
    private static var didRequestAuthorization = false
    /// The one attention request this cycle owns. Held so a second cycle replaces rather than stacks
    /// a second bounce on the Dock.
    private static var attentionArbiter = OPNMaintenanceWatchAttentionArbiter()
    /// The delivered notification identifiers, so the reader coming back can retract exactly the
    /// watches that posted rather than every notification the app has ever shown.
    private static var postedIdentifiers = Set<String>()
    private static var activationObserver: NSObjectProtocol?

    /// Asks for notification permission while the reader is looking at the Watch control, so the
    /// system prompt appears in context. Asks at most once per run.
    static func prepareAuthorizationIfNeeded() {
        guard !didRequestAuthorization, Bundle.main.bundleIdentifier != nil else { return }
        didRequestAuthorization = true
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                OPNLog.info(.app, "Maintenance watch notification authorization \(granted ? "granted" : "denied")")
            } catch {
                OPNLog.warning(.app, "Maintenance watch notification authorization failed: \(error.localizedDescription)")
            }
        }
    }

    /// Announces the edges one poll detected.
    ///
    /// When OpenNOW is frontmost there is no bounce to make and no reason to interrupt: the returned
    /// line is what the caller writes into the catalog status line. In the background it posts one
    /// notification per edge, brings the Dock icon back, and requests attention once for the cycle.
    @discardableResult
    static func announce(_ events: [CatalogMaintenanceWatchEvent]) -> String? {
        guard !events.isEmpty else { return nil }
        guard !NSApplication.shared.isActive else {
            return events.map(inAppMessage).joined(separator: " ")
        }
        for event in events { postNotification(event) }
        beginAttention()
        return nil
    }

    /// The line the catalog status area shows when the reader is already looking at OpenNOW. Never
    /// names a time: the vendor publishes no maintenance ETA, so the honest promise is detection
    /// within one poll interval of it happening.
    static func inAppMessage(_ event: CatalogMaintenanceWatchEvent) -> String {
        let title = displayTitle(event.watch)
        switch event.edge {
        case .patching:
            return "Maintenance finished. \(title) is patching now — OpenNOW will launch it when it is ready."
        case .available:
            return "\(title) is ready to play. Maintenance has finished."
        }
    }

    static func notificationTitle(_ event: CatalogMaintenanceWatchEvent) -> String {
        let title = displayTitle(event.watch)
        switch event.edge {
        case .patching: return "\(title) is now patching"
        case .available: return "\(title) is ready to play"
        }
    }

    static func notificationBody(_ event: CatalogMaintenanceWatchEvent) -> String {
        let title = displayTitle(event.watch)
        switch event.edge {
        case .patching:
            return "Maintenance on \(title) has finished. GeForce NOW is patching it now, and OpenNOW will bring it up when it is ready to play."
        case .available:
            return "Maintenance on \(title) has finished. It is ready to play on GeForce NOW."
        }
    }

    private static func displayTitle(_ watch: CatalogMaintenanceWatch) -> String {
        let trimmed = watch.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Your watched game" : trimmed
    }

    // MARK: - Dock attention

    /// Brings the icon back first, then asks for attention, so menu-bar-only mode has a tile to
    /// bounce. The announcing flag keeps the next `apply()` from withdrawing it before the reader
    /// arrives. One request per cycle: a held identifier is cancelled before the new one is made.
    private static func beginAttention() {
        guard shouldRequestAttention(isActive: NSApplication.shared.isActive) else { return }
        OPNDockIconController.setWatchAnnouncementActive(true)
        OPNDockIconController.showDockIcon()
        if let cancelled = attentionArbiter.replace(with: NSApplication.shared.requestUserAttention(.criticalRequest)) {
            NSApplication.shared.cancelUserAttentionRequest(cancelled)
        }
        installActivationObserver()
    }

    /// No bounce when the reader is already looking at the app: there is nothing to call them back
    /// to, so the in-app line carries it instead. Pure, so the guard is testable without a Dock.
    static func shouldRequestAttention(isActive: Bool) -> Bool {
        !isActive
    }

    /// The reader is back: stop the bounce, give the Dock icon back to the close behaviour that owns
    /// it, and retract the notifications the return just made redundant. Idempotent, so it can run
    /// from the activation observer and from a fresh announcement alike.
    static func endAttention() {
        if let cancelled = attentionArbiter.clear() {
            NSApplication.shared.cancelUserAttentionRequest(cancelled)
        }
        OPNDockIconController.setWatchAnnouncementActive(false)
        clearDelivered()
    }

    private static func installActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { endAttention() }
        }
    }

    static func clearDelivered() {
        guard Bundle.main.bundleIdentifier != nil, !postedIdentifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(postedIdentifiers))
        postedIdentifiers.removeAll()
    }

    private static func postNotification(_ event: CatalogMaintenanceWatchEvent) {

        guard Bundle.main.bundleIdentifier != nil else { return }
        let identifier = "\(notificationIdentifierPrefix).\(event.watch.identity).\(event.edge.rawValue)"
        let title = notificationTitle(event)
        let body = notificationBody(event)
        Task {
            let center = UNUserNotificationCenter.current()
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined {
                status = (try? await center.requestAuthorization(options: [.alert, .sound])) == true ? .authorized : .denied
            }
            guard status == .authorized || status == .provisional else {
                OPNLog.info(.app, "Maintenance watch notification skipped: authorization status \(status.rawValue)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                postedIdentifiers.insert(identifier)
                OPNLog.info(.app, "Maintenance watch notification posted for \(event.watch.identity) (\(event.edge.rawValue))")
            } catch {
                OPNLog.warning(.app, "Maintenance watch notification failed: \(error.localizedDescription)")
            }
        }
    }
}

/// At most one Dock attention request at a time.
///
/// `replace(with:)` hands back the request a new one supersedes, so the caller cancels it rather than
/// stacking a second bounce when several titles return in the same cycle. Pure, so the arbitration
/// is testable without a running Dock.
struct OPNMaintenanceWatchAttentionArbiter: Equatable {
    private(set) var heldRequestId: Int?

    mutating func replace(with requestId: Int) -> Int? {
        let superseded = heldRequestId
        heldRequestId = requestId
        return superseded
    }

    mutating func clear() -> Int? {
        defer { heldRequestId = nil }
        return heldRequestId
    }
}
