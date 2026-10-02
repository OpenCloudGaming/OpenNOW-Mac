import AppKit

@MainActor
enum OPNCouchCoopWindowPlacement {
    static let tiledPresentationOptions: NSApplication.PresentationOptions = [.autoHideMenuBar, .autoHideDock]

    static func collectionBehavior(base: NSWindow.CollectionBehavior, layout: OPNCouchCoopLayout) -> NSWindow.CollectionBehavior {
        switch layout {
        case .manual:
            base.union(.fullScreenAllowsTiling)
        case .sideBySide, .topAndBottom:
            base.subtracting(.fullScreenPrimary).union(.fullScreenNone)
        }
    }

    static func apply(_ tile: OPNCouchCoopTile, to window: OPNStreamWindow) {
        window.collectionBehavior = collectionBehavior(base: window.collectionBehavior, layout: tile.layout)
        StreamWindowGeometryGate.releaseAspectRatioLock(window)
        guard let frame = tile.frame else { return }
        window.isTiled = true
        window.stopPersistingFrame()
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.setFrame(frame, display: false)
    }

    static func enterTiledPresentation() -> NSApplication.PresentationOptions {
        let previous = NSApp.presentationOptions
        NSApp.presentationOptions = previous.union(tiledPresentationOptions)
        return previous
    }

    static func restorePresentation(_ options: NSApplication.PresentationOptions) {
        NSApp.presentationOptions = options
    }
}
