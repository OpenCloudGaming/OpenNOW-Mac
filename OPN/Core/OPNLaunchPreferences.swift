import Foundation

/// How OpenNOW presents itself when it launches: onto the main window, or only the menu bar item.
enum OPNStartupPresentation: String, CaseIterable, Sendable {
    case window
    case menuBarOnly

    var label: String {
        switch self {
        case .window: return "Open the Window"
        case .menuBarOnly: return "Menu Bar Only"
        }
    }
}

/// What OpenNOW does when the Mac logs in or the app launches.
///
/// The login item is owned by the system once registered, so the stored value is only the user's
/// intent; `OPNLoginItemController` reads the system's answer back.
enum OPNLaunchPreferences {
    static let launchesAtLoginKey = "OpenNOW.Launch.AtLogin"
    static let startupPresentationKey = "OpenNOW.Launch.StartupPresentation"
    static let didChangeNotification = Notification.Name("OPNLaunchPreferencesDidChange")

    static let defaultLaunchesAtLogin = false
    static let defaultStartupPresentation = OPNStartupPresentation.window

    static var launchesAtLogin: Bool {
        get {
            guard OPNAppPreferenceStorage.standard.object(forKey: launchesAtLoginKey) != nil else {
                return defaultLaunchesAtLogin
            }
            return OPNAppPreferenceStorage.standard.bool(forKey: launchesAtLoginKey)
        }
        set {
            guard newValue != launchesAtLogin else { return }
            OPNAppPreferenceStorage.standard.set(newValue, forKey: launchesAtLoginKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    /// The stored choice resolved against the surfaces that could be reached at launch. A
    /// menu-bar-only launch suppresses the window, so it is only safe when the status item will
    /// actually be inserted: the menu bar item must be on, and the app must outlive its window. With
    /// either off there would be no window and no status item — nothing on screen at all — so the
    /// stored choice is withheld, not rewritten, and resolves to opening the window. Shared with the
    /// settings row so it shows the presentation actually in force.
    static func resolvedStartupPresentation(storedRawValue: String?) -> OPNStartupPresentation {
        resolvedStartupPresentation(
            storedRawValue: storedRawValue,
            canReachMenuBar: OPNMenuBarPreferences.showsStatusItem && OPNWindowClosePreferences.keepsApplicationRunning
        )
    }

    /// The same resolution with the reachability supplied, so the rule is testable without touching
    /// the preference store.
    static func resolvedStartupPresentation(storedRawValue: String?, canReachMenuBar: Bool) -> OPNStartupPresentation {
        guard let rawValue = storedRawValue, let presentation = OPNStartupPresentation(rawValue: rawValue) else {
            return defaultStartupPresentation
        }
        guard presentation == .menuBarOnly else { return presentation }
        return canReachMenuBar ? presentation : .window
    }

    static var startupPresentation: OPNStartupPresentation {
        get {
            resolvedStartupPresentation(storedRawValue: OPNAppPreferenceStorage.standard.string(forKey: startupPresentationKey))
        }
        set {
            guard newValue != startupPresentation else { return }
            OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: startupPresentationKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
