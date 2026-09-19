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

    static var startupPresentation: OPNStartupPresentation {
        get {
            guard let rawValue = OPNAppPreferenceStorage.standard.string(forKey: startupPresentationKey),
                  let presentation = OPNStartupPresentation(rawValue: rawValue) else {
                return defaultStartupPresentation
            }
            return presentation
        }
        set {
            guard newValue != startupPresentation else { return }
            OPNAppPreferenceStorage.standard.set(newValue.rawValue, forKey: startupPresentationKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
