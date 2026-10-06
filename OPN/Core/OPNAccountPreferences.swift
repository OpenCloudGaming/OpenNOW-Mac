import Foundation

/// Choices about which saved account OpenNOW browses with. A device preference, so it survives every
/// account being signed out.
enum OPNAccountPreferences {
    static let shouldAskWhichAccountOnStartupKey = "OpenNOW.Account.AskWhichAccountOnStartup"
    static let defaultShouldAskWhichAccountOnStartup = false

    /// Off unless it was explicitly turned on, so an install that predates the setting starts exactly
    /// as it did before.
    static var shouldAskWhichAccountOnStartup: Bool {
        get {
            guard OPNAppPreferenceStorage.standard.object(forKey: shouldAskWhichAccountOnStartupKey) != nil else {
                return defaultShouldAskWhichAccountOnStartup
            }
            return OPNAppPreferenceStorage.standard.bool(forKey: shouldAskWhichAccountOnStartupKey)
        }
        set {
            guard newValue != shouldAskWhichAccountOnStartup else { return }
            OPNAppPreferenceStorage.standard.set(newValue, forKey: shouldAskWhichAccountOnStartupKey)
        }
    }

    /// One saved account is not a choice and none is not either, so both keep the ordinary startup.
    static func shouldAskOnStartup(savedAccountCount: Int) -> Bool {
        shouldAskWhichAccountOnStartup && savedAccountCount > 1
    }
}
