//  Watches an `NSView` for frame changes.
//
//  A type rather than a bare `NotificationCenter` registration at the call site: the observation's
//  lifetime is this object's, so it is torn down when its owner goes away instead of relying on
//  every call site to remember.
//

import AppKit
import Foundation

final class AppKitViewFrameObserver {
    private let token: any NSObjectProtocol

    /// `onChange` runs on the main queue, which is where AppKit posts the notification.
    @MainActor
    init(view: NSView, onChange: @escaping @MainActor @Sendable () -> Void) {
        view.postsFrameChangedNotifications = true
        token = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
