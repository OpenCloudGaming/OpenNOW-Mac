import AppKit

/// Keeps the Dock icon in step with `OPNWindowCloseBehavior.menuBarOnly`: when that choice is active
/// and no window is on screen, the app withdraws from the Dock and lives only in the menu bar; the
/// moment a window is shown, the Dock icon comes back.
///
/// This is the one place the app changes its activation policy. A regular app gets its Dock icon,
/// Dock-menu, and Cmd-Tab entry for free, and every other close choice keeps it — the menu-bar-only
/// choice is the single trade that gives the Dock up, and it is only safe while the status item
/// exists to reach the app by.
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
    }

    static func uninstall() {
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
        observerTokens.removeAll()
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
            (window.isVisible || window.isMiniaturized) && window.styleMask.contains(.titled)
        }
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
    }
}
