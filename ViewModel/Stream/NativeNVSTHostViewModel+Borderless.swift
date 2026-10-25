//  The Borderless Full Screen tile and what it does to a stream window: a single window toggles its
//  own borderless mode, and a window the couch co-op layout places flips every tile between sitting
//  below the menu bar and filling the screens.
//
//  AppKit is imported for the same reason as the main file: the window is what these controls act on.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

@MainActor
extension NativeNVSTHostViewModel {
    private var streamLayoutState: OPNStreamWindowLayoutState? {
        (nativeView?.window as? OPNStreamWindow)?.layoutState
    }

    var isBorderlessWindow: Bool { streamLayoutState?.isBorderless ?? false }

    /// A window the couch co-op layout places. Its tile switches every tiled window between sitting
    /// below the menu bar and filling the screens, rather than taking this one window out.
    private var isTiledWindow: Bool { streamLayoutState?.isAutoTiled ?? false }

    var isBorderlessTileActive: Bool {
        isTiledWindow ? OPNStreamTileCoverage.stored == .fullScreen : isBorderlessWindow
    }

    var borderlessTileTitle: String {
        if isTiledWindow { return OPNStreamTileCoverage.stored == .fullScreen ? "Tiles Below Menu Bar" : "Tiles Fill Screen" }
        return isBorderlessWindow ? "Leave Borderless" : "Borderless Full Screen"
    }

    var borderlessTileSubtitle: String {
        if isTiledWindow { return OPNStreamTileCoverage.stored == .fullScreen ? "Filling every screen" : "Below the menu bar" }
        return isBorderlessWindow ? "Borderless" : "Fill the screen, keep the Spaces"
    }

    /// Borderless is a couch co-op mode, so the tile exists only behind the flag, and like full
    /// screen it has nothing to act on in a small floating window or in a native full-screen Space.
    var isBorderlessTileAvailable: Bool { OPNLabs.isCouchCoopEnabled }

    var isBorderlessTileDisabled: Bool {
        nativeView?.window == nil || isPictureInPicture || streamWindowIsFullScreen || isFullScreenTransitioning
    }

    /// The reader's own choice, so the layout stops placing this window: it stays where the toggle
    /// left it, borderless or not.
    func toggleBorderlessFullScreen() {
        guard isBorderlessTileAvailable, !isBorderlessTileDisabled, !isEnding, !didEnd,
              let window = nativeView?.window as? OPNStreamWindow else { return }
        if window.layoutState.isAutoTiled {
            let coverage = OPNStreamTileCoverage.stored.flipped
            OPNStreamWindowPresenter.shared.setTileCoverage(coverage)
            showNativeTransientStreamMessage(coverage == .fullScreen ? "Tiles fill the screen" : "Tiles below the menu bar")
            return
        }
        OPNStreamBorderless.toggleByReader(window)
        showNativeTransientStreamMessage(window.layoutState.isBorderless ? "Borderless full screen" : "Leaving borderless full screen")
    }
}
