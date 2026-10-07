//  Watches an `NSWindow` for update passes.
//
//  A type rather than a bare `NotificationCenter` registration at the call site: the observation's
//  lifetime is this object's, so it is torn down when its owner goes away instead of relying on
//  every call site to remember. `View/` may not own a notification observer directly.
//

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
