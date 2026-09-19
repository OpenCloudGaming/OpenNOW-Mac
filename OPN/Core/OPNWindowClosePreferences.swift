import Foundation

/// What the main window's close button does.
///
/// This is also what decides whether a status item exists while nothing is streaming: the menu bar
/// surface can only outlive the window if the app does.
enum OPNWindowCloseBehavior: String, CaseIterable, Sendable {
    /// Closing the last window quits OpenNOW — an ordinary single-window Mac app.
    case quitApplication
    /// The window drops into the Dock and OpenNOW keeps running, so an active session survives being
    /// put out of the way and the menu bar stays reachable. The window keeps its place, so reopening
    /// it is instant.
    case minimizeToDock
    /// The window closes outright and OpenNOW keeps running for the menu bar. Nothing is kept alive
    /// behind it, so reopening builds the window from scratch.
    case keepRunningWindowless

    var label: String {
        switch self {
        case .quitApplication: return "Quit OpenNOW"
        case .minimizeToDock: return "Minimize to the Dock"
        case .keepRunningWindowless: return "Keep Running, No Window"
        }
    }

    /// Whether OpenNOW outlives its last window. True for both keep-running choices, which is what
    /// makes them different from the default and what keeps the menu bar surface alive.
    var keepsApplicationRunning: Bool {
        self != .quitApplication
    }

    /// True for the choice that leaves nothing on screen but the status item.
    var requiresStatusItem: Bool {
        self == .keepRunningWindowless
    }
}

enum OPNWindowClosePreferences {
    static let behaviorKey = "OpenNOW.Window.CloseBehavior"
    static let defaultBehavior = OPNWindowCloseBehavior.quitApplication
    static let didChangeNotification = Notification.Name("OPNWindowClosePreferencesDidChange")

    static var behavior: OPNWindowCloseBehavior {
        get {
            guard let rawValue = OPNAppPreferenceStorage.standard.string(forKey: behaviorKey),
                  let stored = OPNWindowCloseBehavior(rawValue: rawValue) else {
                return defaultBehavior
            }
            // A windowless app with the menu bar turned off would leave nothing on screen to see or
            // end a session from, so that combination is not a choice this app offers. The stored
            // value is kept as it was, so turning the menu bar item back on restores it.
            guard !stored.requiresStatusItem || OPNMenuBarPreferences.showsStatusItem else {
                return defaultBehavior
            }
            return stored
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
