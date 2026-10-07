//  Watches an `NSWindow` for update passes. A type rather than a bare registration at the call site,
//  so the observation's lifetime is its owner's and `View/` never owns a notification observer.

import AppKit
import Foundation

final class OPNWindowUpdateObserver {
    private let token: any NSObjectProtocol

    /// `onUpdate` runs on the main queue, which is where AppKit posts the notification.
    @MainActor
    init(window: NSWindow, onUpdate: @escaping @MainActor @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onUpdate() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
