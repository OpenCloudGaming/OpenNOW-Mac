//  Watches an `NSView` for the changes that move content under a stationary cursor: a clip view's
//  scroll offset, and a clip or document view's size.
//
//  A type rather than a bare `NotificationCenter` registration at the call site: the observation's
//  lifetime is this object's, so it is torn down when its owner goes away instead of relying on
//  every call site to remember.
//

import AppKit
import Foundation

final class AppKitViewMovementObserver {
    private let tokens: [any NSObjectProtocol]

    /// `onChange` runs on the main queue, which is where AppKit posts the notification.
    @MainActor
    init(view: NSView, onChange: @escaping @MainActor @Sendable () -> Void) {
        view.postsBoundsChangedNotifications = true
        view.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        tokens = [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification].map { name in
            center.addObserver(forName: name, object: view, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
    }

    deinit {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
