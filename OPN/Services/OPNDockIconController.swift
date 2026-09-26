import AppKit
import Combine

/// Everything the app does to its Dock icon, in one place.
///
/// **Existence.** It keeps the icon in step with `OPNWindowCloseBehavior.menuBarOnly`: when that
/// choice is active and no window is on screen, the app withdraws from the Dock and lives only in the
/// menu bar; the moment a window is shown, the Dock icon comes back. This is the one place the app
/// changes its activation policy. A regular app gets its Dock icon, Dock-menu, and Cmd-Tab entry for
/// free, and every other close choice keeps it — the menu-bar-only choice is the single trade that
/// gives the Dock up, and it is only safe while the status item exists to reach the app by.
///
/// **Content.** The badge and the progress bar are written here too, because they only mean anything
/// while the policy above is `.regular` — an accessory app has no tile to write to — and because
/// every write redraws the Dock icon. One owner for both keeps the two from fighting: a wait that
/// starts while the icon is hidden is written when it comes back, rather than lost or left behind.
///
/// The decisions themselves are pure and live in `OPNDockTileContent` and `OPNDockQueueProgress`; a
/// Dock exists only in a running app, so anything worth testing is kept out of the `NSDockTile`
/// calls themselves.
@MainActor
enum OPNDockIconController {
    private static var observerTokens: [NSObjectProtocol] = []

    /// Whether the Dock icon should be hidden right now. Pure, so the decision is testable without
    /// touching `NSApplication`.
    static func shouldHideDockIcon(
        behavior: OPNWindowCloseBehavior,
        showsStatusItem: Bool,
        hasVisibleAppWindow: Bool
    ) -> Bool {
        behavior == .menuBarOnly && showsStatusItem && !hasVisibleAppWindow
    }

    static func install() {
        guard observerTokens.isEmpty else { return }
        let immediateNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            OPNWindowClosePreferences.didChangeNotification,
            OPNMenuBarPreferences.didChangeNotification,
        ]
        for name in immediateNames {
            observerTokens.append(observe(name) { apply() })
        }
        // A closing window is still counted as visible while `willClose` is posted, so this one waits
        // for the next turn of the run loop, after the window is off screen.
        observerTokens.append(observe(NSWindow.willCloseNotification) {
            _ = Task { @MainActor in apply() }
        })
        // Deferred for the same reason at launch: the window SwiftUI is about to show must be counted
        // before the menu-bar-only choice withdraws the Dock icon from under it.
        _ = Task { @MainActor in apply() }
        observeSessionSurface()
    }

    static func uninstall() {
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
        observerTokens.removeAll()
        sessionObservers.removeAll()
        appliedContent = .none
        queueProgress.reset()
        exportFraction = nil
        progressView = nil
        if let tile = NSApp?.dockTile {
            tile.badgeLabel = nil
            tile.contentView = nil
            tile.display()
        }
    }

    /// Called before the main window is opened from the menu bar so it arrives with its Dock icon.
    static func showDockIcon() {
        setPolicy(.regular)
    }

    static func apply() {
        let hide = shouldHideDockIcon(
            behavior: OPNWindowClosePreferences.behavior,
            showsStatusItem: OPNMenuBarPreferences.showsStatusItem,
            hasVisibleAppWindow: hasVisibleAppWindow()
        )
        setPolicy(hide ? .accessory : .regular)
    }

    /// Any ordinary window counts: the main window, the Remote Co-Op guest window. A minimized window
    /// counts too — it is sitting in the Dock and must keep the icon that reaches it. The status
    /// item's popover and the status bar window are borderless, so they never keep a Dock icon alive.
    private static func hasVisibleAppWindow() -> Bool {
        NSApp.windows.contains { window in
            (window.isVisible || window.isMiniaturized) && countsAsAppWindow(styleMask: window.styleMask)
        }
    }

    /// Whether a window's style mask keeps a Dock icon alive. Named so the arithmetic can be asserted
    /// against a style mask alone - in particular the dedicated stream window's, which has to keep
    /// counting now that it can be the only window on screen.
    static func countsAsAppWindow(styleMask: NSWindow.StyleMask) -> Bool {
        styleMask.contains(.titled)
    }

    private static func observe(_ name: Notification.Name, _ action: @escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    private static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        _ = NSApp.setActivationPolicy(policy)
        OPNLog.info(.app, "Activation policy set to \(policy == .accessory ? "accessory: menu bar only" : "regular")")
        // The icon comes and goes; the tile does not. Whatever it was showing is written again, so a
        // wait that spans a trip through the menu bar is still on screen when the icon is back.
        reapplyTileContent()
    }

    // MARK: - Tile content

    /// What the tile is showing now, held so a write that would not change the picture is skipped:
    /// every write redraws the Dock icon.
    private static var appliedContent = OPNDockTileContent.none
    /// The wait for a seat, measured from the position it started at.
    private static var queueProgress = OPNDockQueueProgress()
    /// The recording export in flight, while the user has one running.
    private static var exportFraction: Double?
    /// The tile's content view while there is progress to draw. The Dock owns what it is installed
    /// in; this holds the view so a new fraction does not build a new one.
    private static var progressView: OPNDockTileProgressView?
    /// One subscription per fact the tile depends on. `$phase` and `$resumableSessionTitle` carry
    /// different types, so they are watched separately; recomputing is cheap and writes are skipped
    /// when nothing changed.
    private static var sessionObservers: [AnyCancellable] = []

    /// A recording export, as the Dock needs it: a fraction while one runs, nil once it is over.
    ///
    /// The editor reports this rather than the Dock watching it. There is no one export to watch —
    /// each editor owns its own — and the end has to be reported from the export's own exit path, so
    /// a cancelled or failed export cannot leave a wait the rest of the app has already forgotten on
    /// the tile.
    static func setExportProgress(_ fraction: Double?) {
        guard exportFraction != fraction else { return }
        exportFraction = fraction
        let session = OPNMenuBarSessionModel.shared
        refreshTile(phase: session.phase, resumableSessionTitle: session.resumableSessionTitle)
    }

    /// Watches the surface the menu bar reads — the same phase, the same resumable session — so the
    /// badge cannot describe a session the rest of the app does not have.
    private static func observeSessionSurface() {
        guard sessionObservers.isEmpty else { return }
        let session = OPNMenuBarSessionModel.shared
        // `@Published` sends its new value from `willSet`, before the property holds it, so each
        // subscription works from the value it was handed and reads only the *other* property off the
        // model. Reading the changed property back here would read what the change replaced, and the
        // tile would render every state one change behind — live-verified: a queue position reported
        // a badge only once the queue had already ended.
        sessionObservers = [
            session.$phase.sink { phase in
                refreshTile(phase: phase, resumableSessionTitle: session.resumableSessionTitle)
            },
            session.$resumableSessionTitle.sink { title in
                refreshTile(phase: session.phase, resumableSessionTitle: title)
            },
        ]
        refreshTile(phase: session.phase, resumableSessionTitle: session.resumableSessionTitle)
    }

    /// Recomputes the tile from the session surface and the export in flight, and writes it only if
    /// it changed. The surface's state arrives as arguments rather than being read here, for the
    /// reason above.
    private static func refreshTile(phase: OPNMenuBarSessionPhase, resumableSessionTitle: String?) {
        let queueFraction: Double?
        if case let .queued(position) = phase {
            queueFraction = queueProgress.observe(position: position)
        } else {
            queueProgress.reset()
            queueFraction = nil
        }
        apply(OPNDockTileContent(
            pendingSessions: OPNDockTileContent.pendingSessionCount(
                isQueued: phase.isQueued,
                hasResumableSession: resumableSessionTitle != nil
            ),
            progress: OPNDockTileContent.progress(queue: queueFraction, isStarting: phase == .starting, export: exportFraction)
        ))
    }

    private static func apply(_ content: OPNDockTileContent) {
        guard content != appliedContent else { return }
        appliedContent = content
        applyBadge(content.badgeLabel)
        applyProgress(content.progress)
    }

    private static func applyBadge(_ label: String?) {
        guard let tile = NSApp?.dockTile, tile.badgeLabel != label else { return }
        tile.badgeLabel = label
        tile.display()
    }

    private static func applyProgress(_ progress: OPNDockProgress?) {
        guard let tile = NSApp?.dockTile else { return }
        guard let progress else {
            // Clearing hands the tile back its own icon. Left installed, a finished wait would sit on
            // the Dock icon until the app quit.
            guard progressView != nil else { return }
            tile.contentView = nil
            progressView = nil
            tile.display()
            return
        }
        let view = progressView ?? installProgressView(on: tile)
        view.progress = progress
        tile.display()
    }

    private static func installProgressView(on tile: NSDockTile) -> OPNDockTileProgressView {
        let view = OPNDockTileProgressView(frame: NSRect(origin: .zero, size: tile.size))
        view.autoresizingMask = [.width, .height]
        tile.contentView = view
        progressView = view
        return view
    }

    /// Writes the current content back onto the tile after the icon's existence changed. The view is
    /// rebuilt rather than reused: what the Dock did with the old one while the icon was gone is the
    /// Dock's business, and a view that is no longer installed would draw to nothing.
    private static func reapplyTileContent() {
        NSApp?.dockTile.contentView = nil
        progressView = nil
        applyBadge(appliedContent.badgeLabel)
        applyProgress(appliedContent.progress)
    }
}
