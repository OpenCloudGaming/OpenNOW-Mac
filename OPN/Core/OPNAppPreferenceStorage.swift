import Foundation

public struct OPNAppPreferenceStorage: @unchecked Sendable {
    public static let standard = OPNAppPreferenceStorage(defaults: .standard, defaultsDomain: OPNProductIdentity.releaseBundleIdentifier)

    /// The data iCloud sync owns: collections, the home arrangement, the account registry, and the
    /// sync's baselines. Kept out of `standard`, whose any change invalidates every `@AppStorage` view.
    public static let syncStore: OPNAppPreferenceStorage = {
        guard let suiteDefaults = UserDefaults(suiteName: syncStoreSuiteName) else {
            // No suite available: keep the catalog in the standard domain rather than lose it.
            return OPNAppPreferenceStorage(defaults: .standard, defaultsDomain: OPNProductIdentity.releaseBundleIdentifier)
        }
        let storage = OPNAppPreferenceStorage(defaults: suiteDefaults, defaultsDomain: syncStoreSuiteName)
        storage.migrateCatalogDataFromStandard()
        return storage
    }()

    /// Per-bundle, so a dev build never reads a release build's synced catalog.
    private static let syncStoreSuiteName = "\(Bundle.main.bundleIdentifier ?? "\(OPNProductIdentity.releaseBundleIdentifier).unidentified").syncstore"
    private static let migrationCompletedKey = "OpenNOW.SyncStore.MigrationCompleted"
    private static let catalogOwnedKeys = [
        "OpenNOW.Interface.HomeRailOrder",
        "OpenNOW.Interface.HomeRailsHidden",
        "OpenNOW.Catalog.CollectionLocalAccounts",
        "OpenNOW.Catalog.CollectionAccountAliases",
        "OpenNOW.CloudSync.CatalogBaseline",
        "OpenNOW.CloudSync.CatalogSignatureBaseline",
        "OpenNOW.CloudSync.SettingsBaseline",
        "OpenNOW.CloudSync.SettingsSignatureBaseline",
    ]
    private static let catalogOwnedKeyPrefixes = [
        "OpenNOW.Catalog.Collections.",
    ]

    private static func isCatalogOwnedKey(_ key: String) -> Bool {
        catalogOwnedKeys.contains(key) || catalogOwnedKeyPrefixes.contains { key.hasPrefix($0) }
    }

    private let defaults: UserDefaults
    private let defaultsDomain: String

    public init(defaults: UserDefaults, defaultsDomain: String) {
        self.defaults = defaults
        self.defaultsDomain = defaultsDomain
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func bool(forKey key: String) -> Bool {
        defaults.bool(forKey: key)
    }

    public func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    public func array(forKey key: String) -> [Any]? {
        defaults.array(forKey: key)
    }

    public func dictionary(forKey key: String) -> [String: Any]? {
        defaults.dictionary(forKey: key)
    }

    /// Every stored key/value, used by the iCloud backup to enumerate what it may export. Filtered
    /// by the caller: this includes the global and registration domains too.
    public func dictionaryRepresentation() -> [String: Any] {
        defaults.dictionaryRepresentation()
    }

    public func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    public func double(forKey key: String) -> Double {
        defaults.double(forKey: key)
    }

    public func set(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func removeObject(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    public func synchronize() {
        defaults.synchronize()
    }

    public func storedValue(forKey key: String, preferCanonicalDomain: Bool) -> Any? {
        if preferCanonicalDomain, let canonical = defaults.persistentDomain(forName: defaultsDomain)?[key] {
            return canonical
        }
        if let value = defaults.object(forKey: key) {
            return value
        }
        if let value = defaults.persistentDomain(forName: defaultsDomain)?[key] {
            return value
        }
        return defaults.persistentDomain(forName: UserDefaults.globalDomain)?[key]
    }

    public func setCanonicalInt(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
        var domain = defaults.persistentDomain(forName: defaultsDomain) ?? [:]
        domain[key] = value
        defaults.setPersistentDomain(domain, forName: defaultsDomain)
    }

    /// Moves catalog-owned values written before the suite existed into it, once.
    private func migrateCatalogDataFromStandard() {
        guard !defaults.bool(forKey: Self.migrationCompletedKey) else { return }
        let source = UserDefaults.standard
        for key in source.dictionaryRepresentation().keys where Self.isCatalogOwnedKey(key) {
            migrateValue(forKey: key, from: source)
        }
        defaults.set(true, forKey: Self.migrationCompletedKey)
    }

    private func migrateValue(forKey key: String, from source: UserDefaults) {
        guard let value = source.object(forKey: key) else { return }
        defaults.set(value, forKey: key)
        source.removeObject(forKey: key)
    }
}
