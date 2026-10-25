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
    /// new one. What was there before the first entry is kept for the way out. `coversMenuBar` raises
    /// the window over the menu bar and the Dock even when it is only one tile of a screen, which is
    /// how tiles fill a screen together; without it only a window that fills a screen is raised.
    static func enter(_ window: OPNStreamWindow, frame: NSRect, coversMenuBar: Bool = false,
                      screenFrames: [NSRect] = NSScreen.screens.map(\.frame)) {
        guard !window.isPresentationEnding, !window.isPictureInPicture else { return }
        if window.borderlessRestoreState == nil {
            window.borderlessRestoreState = OPNStreamWindow.WindowedState(
                level: window.level,
                collectionBehavior: window.collectionBehavior,
                frame: window.frame,
                isMiniaturized: window.isMiniaturized
            )
            OPNStreamWindowFrameStore.save(window.frame, isPictureInPicture: false, defaults: window.frameStoreDefaults)
        }
        window.layoutState.isBorderless = true
        let level = coversMenuBar ? coveringLevel : level(for: frame, screenFrames: screenFrames)
        window.scheduleLayoutChange { window in
            if window.isMiniaturized { window.deminiaturize(nil) }
            StreamWindowGeometryGate.releaseAspectRatioLock(window)
            OPNStreamWindowChrome.applyBorderless(to: window, isBorderless: true)
            window.level = level
            for child in window.childWindows ?? [] { child.level = level }
            window.setFrameFromLayout(frame)
            postCoveringStateChange(for: window)
        }
    }

    static func exit(_ window: OPNStreamWindow, completion: (@MainActor () -> Void)? = nil) {
        guard !window.isPresentationEnding else { return }
        guard window.layoutState.isBorderless || window.borderlessRestoreState != nil ||
            StreamWindowGeometryGate.shouldDeferGeometryMutation(for: window) else {
            window.cancelPendingLayout()
            completion?()
            return
        }
        window.scheduleLayoutChange { window in
            restoreWindowedState(window, isFrameRestored: true)
            guard !Task.isCancelled, !window.isPresentationEnding else { return }
            completion?()
        }
        window.isBorderlessExitPending = window.layoutState.isBorderless
    }

    private static func restoreWindowedState(_ window: OPNStreamWindow, isFrameRestored: Bool) {
        guard window.layoutState.isBorderless || window.borderlessRestoreState != nil else {
            window.clearLayoutFrame()
            return
        }
        let wasBorderless = window.layoutState.isBorderless
        window.layoutState.isBorderless = false
        defer {
            window.clearLayoutFrame()
            if wasBorderless { postCoveringStateChange(for: window) }
        }
        OPNStreamWindowChrome.applyBorderless(to: window, isBorderless: false)
        guard let state = window.borderlessRestoreState else {
            window.level = .normal
            for child in window.childWindows ?? [] { child.level = .normal }
            return
        }
        window.borderlessRestoreState = nil
        window.level = state.level
        for child in window.childWindows ?? [] { child.level = state.level }
        guard isFrameRestored else { return }
        window.setFrameFromLayout(state.frame)
        if state.isMiniaturized { window.miniaturize(nil) }
    }

    /// Posted whenever a stream window takes or gives up the covering level, so a window that has to
    /// stay reachable above it re-reads its level then instead of on a timer.
    static let coveringStateDidChange = Notification.Name("OpenNOW.StreamBorderless.coveringStateDidChange")

    static func postCoveringStateChange(for window: OPNStreamWindow? = nil) {
        NotificationCenter.default.post(name: coveringStateDidChange, object: window)
    }

    /// The window's own toggle, from the HUD: the window is the reader's from here on, so the layout
    /// stops placing it whichever way it goes.
    static func toggleByReader(_ window: OPNStreamWindow) {
        if window.layoutState.isBorderless, !window.isBorderlessExitPending {
            releaseToReader(window)
            return
        }
        window.layoutState.isManuallyPlaced = true
        enter(window, frame: targetFrame(for: window))
        window.layoutMembershipDidChange?()
    }

    /// Leaves borderless and the layout together, for a window that is about to become something
    /// else (Picture in Picture) or that the reader no longer wants tiled.
    static func releaseToReader(_ window: OPNStreamWindow, completion: (@MainActor () -> Void)? = nil) {
        window.layoutState.isManuallyPlaced = true
        window.layoutState.isAutoTiled = false
        window.clearLayoutFrame()
        exit(window, completion: completion)
        window.layoutMembershipDidChange?()
    }

    static func takePlacement(_ window: OPNStreamWindow) {
        window.cancelPendingLayout()
        window.layoutState.isManuallyPlaced = true
        window.layoutState.isAutoTiled = false
        restoreWindowedState(window, isFrameRestored: false)
        window.layoutMembershipDidChange?()
    }

    /// The screen a borderless toggle fills when nothing else decided: the one the window is on.
    static func targetFrame(for window: NSWindow) -> NSRect {
        (window.screen ?? NSScreen.main)?.frame ?? window.frame
    }
}
