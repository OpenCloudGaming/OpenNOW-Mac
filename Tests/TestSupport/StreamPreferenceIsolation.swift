import Foundation

/// Every suite that writes `OPNStreamPreferences` shares one process-wide defaults domain, so the
/// save/restore window lives here instead of being copied into each suite.
let streamPreferenceDomain = "io.github.opencloudgaming.opennow"

/// Runs `body` as the only writer of the shared preference domain, restoring `keys` afterwards.
func withPreservedPreferences<Result>(_ keys: [String], _ body: () throws -> Result) rethrows -> Result {
    try withExclusivePreferenceDomain {
        let defaults = UserDefaults.standard
        let previousValues = keys.map { ($0, defaults.object(forKey: $0)) }
        let previousDomain = defaults.persistentDomain(forName: streamPreferenceDomain)
        let previousGlobalDomain = defaults.persistentDomain(forName: UserDefaults.globalDomain)
        defer {
            for (key, value) in previousValues {
                guard let value else {
                    defaults.removeObject(forKey: key)
                    continue
                }
                defaults.set(value, forKey: key)
            }
            restorePersistentDomain(previousDomain, named: streamPreferenceDomain, in: defaults)
            restorePersistentDomain(previousGlobalDomain, named: UserDefaults.globalDomain, in: defaults)
            defaults.synchronize()
        }
        return try body()
    }
}

/// Clears a key from the domain the app reads and from the persistent domains it writes through.
func removePreferenceValue(_ key: String) {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: key)
    clearPreferenceValue(key, fromPersistentDomain: streamPreferenceDomain, in: defaults)
    clearPreferenceValue(key, fromPersistentDomain: UserDefaults.globalDomain, in: defaults)
    defaults.synchronize()
}

private func restorePersistentDomain(_ domain: [String: Any]?, named name: String, in defaults: UserDefaults) {
    guard let domain else {
        defaults.removePersistentDomain(forName: name)
        return
    }
    defaults.setPersistentDomain(domain, forName: name)
}

private func clearPreferenceValue(_ key: String, fromPersistentDomain name: String, in defaults: UserDefaults) {
    var domain = defaults.persistentDomain(forName: name) ?? [:]
    domain.removeValue(forKey: key)
    defaults.setPersistentDomain(domain, forName: name)
}
