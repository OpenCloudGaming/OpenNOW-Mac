import Foundation

/// Whether the post-session Session Insights summary is shown when a stream ends.
///
/// Defaults to on; the summary itself carries a "Don't show this again" escape.
enum OPNSessionInsightsPreferences {
    static let isEnabledKey = "OpenNOW.Stream.SessionInsights"
    static let isEnabledByDefault = true

    static var isEnabled: Bool {
        get {
            guard OPNAppPreferenceStorage.standard.object(forKey: isEnabledKey) != nil else {
                return isEnabledByDefault
            }
            return OPNAppPreferenceStorage.standard.bool(forKey: isEnabledKey)
        }
        set {
            guard newValue != isEnabled else { return }
            OPNAppPreferenceStorage.standard.set(newValue, forKey: isEnabledKey)
        }
    }
}
