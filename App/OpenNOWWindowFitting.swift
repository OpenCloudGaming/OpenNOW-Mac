//  Sizing the main window at launch.
//
//  Lives outside the view layer because it owns a notification observer with an app-lifetime scope,
//  and because the window is AppKit's, not SwiftUI's.
//

import AppKit

enum OpenNOWWindowFitting {
    static let targetFillRatio: CGFloat = 0.85
    /// Floor for the fitted size when AppKit has not adopted SwiftUI's minimum content size yet,
    /// which is the case this early. Matches the root's `frame(minWidth:minHeight:)`.
    private static let fallbackMinimumContentSize = CGSize(width: 640, height: 480)
    private static let mainWindowIdentifier = "main"

    @MainActor private static var earlyFittingObserver: NSObjectProtocol?

    /// Fits the restored frame before the window is first painted.
    ///
    /// This used to run from `viewDidMoveToWindow` on a SwiftUI background view, which AppKit only
    /// reaches once the window has already been ordered in at its restored size: the whole interface
    /// drew one frame too large and then snapped smaller ~25 ms later. `didUpdateNotification` is
    /// posted to the window while it is still invisible, which is early enough to resize in silence.
    @MainActor
    static func installEarlyFitting() {
        guard earlyFittingObserver == nil else { return }
        earlyFittingObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { fitPendingMainWindow() }
        }
    }

    @MainActor
    private static func fitPendingMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == mainWindowIdentifier }) else { return }
        let fitted = fittedFrame(for: window)
        // Once it is on screen there is nothing left to fix quietly, and resizing then is the flash
        // this exists to avoid. Stop listening either way.
        if !window.isVisible, let fitted {
            window.setFrame(fitted, display: false)
        }
        removeEarlyFitting()
    }

    @MainActor
    private static func removeEarlyFitting() {
        guard let earlyFittingObserver else { return }
        NotificationCenter.default.removeObserver(earlyFittingObserver)
        self.earlyFittingObserver = nil
    }

    @MainActor
    static func fittedFrame(for window: NSWindow) -> CGRect? {
        let screen = window.screen ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        let allowedWidth = visible.width * targetFillRatio
        let allowedHeight = visible.height * targetFillRatio
        let current = window.frame
        let widthScale = allowedWidth / current.width
        let heightScale = allowedHeight / current.height
        guard widthScale < 1 || heightScale < 1 else { return nil }
        let scale = min(widthScale, heightScale)
        guard scale < 1 else { return nil }
        // Never shrink below the window's minimum content size: SwiftUI keeps
        // laying the content out at its minWidth/minHeight, so a smaller frame
        // just clips the trailing edge instead of resizing the interface.
        let contentMinSize = window.contentMinSize
        let minimumContentSize = CGSize(
            width: max(contentMinSize.width, fallbackMinimumContentSize.width),
            height: max(contentMinSize.height, fallbackMinimumContentSize.height)
        )
        let minFrame = window.frameRect(forContentRect: CGRect(origin: .zero, size: minimumContentSize)).size
        let newSize = CGSize(
            width: max(floor(current.width * scale), minFrame.width),
            height: max(floor(current.height * scale), minFrame.height)
        )
        guard newSize.width < current.width || newSize.height < current.height else { return nil }
        let origin = CGPoint(
            x: visible.midX - newSize.width / 2,
            y: visible.midY - newSize.height / 2
        )
        return CGRect(origin: origin, size: newSize)
    }
}
