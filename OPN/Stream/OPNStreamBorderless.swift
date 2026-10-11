//  Borderless windowed full screen, as a mode of the dedicated stream window.
//
//  The window keeps its style mask. Changing `styleMask` on a window that is already on screen is
//  the trap `OPNStreamPictureInPicture` documents, and `.titled` is what the Dock icon counts. The
//  mode is the frame, the level and the standard buttons instead: the window is set to a screen's
//  frame, raised above the menu bar and the Dock when it covers the whole screen, and its traffic
//  lights are hidden. Leaving puts back what entering replaced.

import AppKit

@MainActor
enum OPNStreamBorderless {
    /// Above the menu bar, so a window that covers a screen covers it too.
    static let coveringLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    /// Where a window the reader has to reach sits: above the borderless stream windows, which cover
    /// the whole screen they are on.
    static let aboveCoveringLevel = NSWindow.Level(rawValue: coveringLevel.rawValue + 1)

    /// Whether `frame` fills one of `screenFrames`. Only such a window is raised over the menu bar
    /// and the Dock; a tile that shares a screen stays an ordinary window beside its neighbours.
    static func coversWholeScreen(_ frame: NSRect, screenFrames: [NSRect]) -> Bool {
        screenFrames.contains { screen in
            abs(screen.minX - frame.minX) < 1 && abs(screen.minY - frame.minY) < 1
                && abs(screen.width - frame.width) < 1 && abs(screen.height - frame.height) < 1
        }
    }

    static func level(for frame: NSRect, screenFrames: [NSRect]) -> NSWindow.Level {
        coversWholeScreen(frame, screenFrames: screenFrames) ? coveringLevel : .normal
    }

    /// Puts the window into borderless mode at `frame`, or moves an already borderless window to a
    /// new one. What was there before the first entry is kept for the way out.
    static func enter(_ window: OPNStreamWindow, frame: NSRect, screenFrames: [NSRect] = NSScreen.screens.map(\.frame)) {
        if window.borderlessRestoreState == nil {
            window.borderlessRestoreState = OPNStreamWindow.WindowedState(
                level: window.level,
                collectionBehavior: window.collectionBehavior,
                frame: window.frame,
                isMiniaturized: window.isMiniaturized
            )
            OPNStreamWindowFrameStore.save(window.frame, isPictureInPicture: false, defaults: window.frameStoreDefaults)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.layoutState.isBorderless = true
        StreamWindowGeometryGate.releaseAspectRatioLock(window)
        OPNStreamWindowChrome.applyBorderless(to: window, isBorderless: true)
        let level = level(for: frame, screenFrames: screenFrames)
        window.level = level
        for child in window.childWindows ?? [] { child.level = level }
        apply(frame: frame, to: window)
    }

    static func exit(_ window: OPNStreamWindow) {
        guard window.layoutState.isBorderless else { return }
        window.layoutState.isBorderless = false
        OPNStreamWindowChrome.applyBorderless(to: window, isBorderless: false)
        guard let state = window.borderlessRestoreState else {
            window.level = .normal
            for child in window.childWindows ?? [] { child.level = .normal }
            return
        }
        window.borderlessRestoreState = nil
        window.level = state.level
        for child in window.childWindows ?? [] { child.level = state.level }
        apply(frame: state.frame, to: window)
        if state.isMiniaturized { window.miniaturize(nil) }
    }

    /// The window's own toggle, from the HUD: the window is the reader's from here on, so the layout
    /// stops placing it whichever way it goes.
    static func toggleByReader(_ window: OPNStreamWindow) {
        if window.layoutState.isBorderless {
            releaseToReader(window)
            return
        }
        window.layoutState.isManuallyPlaced = true
        enter(window, frame: targetFrame(for: window))
    }

    /// Leaves borderless and the layout together, for a window that is about to become something
    /// else (Picture in Picture) or that the reader no longer wants tiled.
    static func releaseToReader(_ window: OPNStreamWindow) {
        window.layoutState.isManuallyPlaced = true
        window.layoutState.isAutoTiled = false
        exit(window)
        window.clearLayoutFrame()
    }

    /// The screen a borderless toggle fills when nothing else decided: the one the window is on.
    static func targetFrame(for window: NSWindow) -> NSRect {
        (window.screen ?? NSScreen.main)?.frame ?? window.frame
    }

    private static func apply(frame: NSRect, to window: OPNStreamWindow) {
        StreamWindowGeometryGate.whenGeometryIsMutable { [weak window] in
            guard let window else { return }
            window.setFrameFromLayout(frame)
        }
    }
}
