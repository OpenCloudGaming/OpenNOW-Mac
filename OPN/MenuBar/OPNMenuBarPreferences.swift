import Foundation

/// Whether OpenNOW puts anything in the menu bar at all.
///
/// The close-button behaviour decides whether the app outlives its window; this decides whether the
/// status item exists to reach it by in the first place, so somebody who wants no menu bar presence
/// can have none — during a session included.
enum OPNMenuBarPreferences {
    static let showsStatusItemKey = "OpenNOW.MenuBar.ShowsStatusItem"
    static let defaultShowsStatusItem = true
    static let didChangeNotification = Notification.Name("OPNMenuBarPreferencesDidChange")

    static var showsStatusItem: Bool {
        get {
            guard OPNAppPreferenceStorage.standard.object(forKey: showsStatusItemKey) != nil else {
                return defaultShowsStatusItem
            }
            return OPNAppPreferenceStorage.standard.bool(forKey: showsStatusItemKey)
        }
        set {
            guard newValue != showsStatusItem else { return }
            OPNAppPreferenceStorage.standard.set(newValue, forKey: showsStatusItemKey)
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
