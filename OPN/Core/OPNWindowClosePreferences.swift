import Foundation

/// What the main window's close button does.
///
/// This is also what decides whether a status item exists while nothing is streaming: the menu bar
/// surface can only outlive the window if the app does.
enum OPNWindowCloseBehavior: String, CaseIterable, Sendable {
    /// Closing the last window quits OpenNOW — an ordinary single-window Mac app.
    case quitApplication
    /// The window closes and OpenNOW keeps running with its Dock icon, the way a regular Mac app
    /// stays in the Dock after its last window is closed. The Dock icon and the Window menu bring the
    /// window back, so nothing is kept alive behind it and reopening builds it from scratch. This is
    /// the default because it is what a close button does everywhere else on the system.
    case keepRunningInDock
    /// The window closes and OpenNOW leaves the Dock entirely, living only in the menu bar. The menu
    /// bar item is the only way back to the window, so this choice needs it.
    case menuBarOnly

    var label: String {
        switch self {
        case .quitApplication: return "Quit on Close"
        case .keepRunningInDock: return "Close, Keep Dock Icon"
        case .menuBarOnly: return "Close, Menu Bar Only"
        }
    }

    /// Whether OpenNOW outlives its last window. True for both keep-running choices, which is what
    /// separates them from quitting.
    var keepsApplicationRunning: Bool {
        self != .quitApplication
    }

    /// True for the choice that withdraws the app from the Dock and leaves nothing on screen but the
    /// status item.
    var requiresStatusItem: Bool {
        self == .menuBarOnly
    }
}

enum OPNWindowClosePreferences {
    static let behaviorKey = "OpenNOW.Window.CloseBehavior"
    static let defaultBehavior = OPNWindowCloseBehavior.keepRunningInDock
    static let didChangeNotification = Notification.Name("OPNWindowClosePreferencesDidChange")

    /// The stored choice resolved against the menu bar item. Menu-bar-only mode hides the Dock icon,
    /// so with the menu bar item off there would be nothing on screen to reach OpenNOW by. That
    /// combination is not offered: the stored choice is withheld, not rewritten, and resolves to the
    /// Dock-keeping fallback. Shared with the settings row so it shows the behavior actually in force.
    static func resolvedBehavior(storedRawValue: String?) -> OPNWindowCloseBehavior {
        guard let storedRawValue, let stored = OPNWindowCloseBehavior(rawValue: storedRawValue) else {
            return defaultBehavior
        }
        guard !stored.requiresStatusItem || OPNMenuBarPreferences.showsStatusItem else {
            return .keepRunningInDock
        }
        return stored
    }

    static var behavior: OPNWindowCloseBehavior {
        get {
            resolvedBehavior(storedRawValue: OPNAppPreferenceStorage.standard.string(forKey: behaviorKey))
        }
        set {
            guard newValue != behavior else { return }
            OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: behaviorKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    static var keepsApplicationRunning: Bool {
        behavior.keepsApplicationRunning
    }
}
