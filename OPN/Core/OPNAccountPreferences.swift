import Foundation

/// Choices about which saved account OpenNOW browses with.
///
/// A device preference rather than a field on an account: it is about how this Mac starts up, not
/// about any one account, and it has to survive every account being signed out.
enum OPNAccountPreferences {
    static let asksWhichAccountOnStartupKey = "OpenNOW.Account.AskWhichAccountOnStartup"
    static let defaultAsksWhichAccountOnStartup = false

    /// Off unless it was explicitly turned on, so an install that predates the setting starts exactly
    /// as it did before: no chooser, no extra step, nothing to dismiss.
    static var asksWhichAccountOnStartup: Bool {
        get {
            guard OPNAppPreferenceStorage.standard.object(forKey: asksWhichAccountOnStartupKey) != nil else {
                return defaultAsksWhichAccountOnStartup
            }
            return OPNAppPreferenceStorage.standard.bool(forKey: asksWhichAccountOnStartupKey)
        }
        set {
            guard newValue != asksWhichAccountOnStartup else { return }
            OPNAppPreferenceStorage.standard.set(newValue, forKey: asksWhichAccountOnStartupKey)
        }
    }

    /// Whether a fresh launch has anything to ask about. One saved account is not a choice and none
    /// is not either, so both keep the ordinary startup however the preference is set.
    static func asksOnStartup(savedAccountCount: Int) -> Bool {
        asksWhichAccountOnStartup && savedAccountCount > 1
    }
}
