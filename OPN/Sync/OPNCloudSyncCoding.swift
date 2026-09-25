import CryptoKit
import Foundation

/// The on-disk shapes and shared coders for the iCloud backup: a flat, self-describing layout under
/// the container's `Documents/OpenNOW/` folder that a reader can open in Finder.
public enum OPNCloudSyncLayout {
    /// Bumped to 3 when collections gained per-item write times and deletion tombstones, so an older
    /// build that would merge whole sets and resurrect a deletion can be told apart from one that
    /// understands newest-write-wins.
    public static let schemaVersion = 3

    static let manifestFileName = "manifest.json"
    static let settingsFileName = "settings/keys.json"
    static let catalogFileName = "catalog/catalog.json"

    static func url(root: URL, relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    static func screenshotsDirectory(root: URL) -> URL {
        root.appendingPathComponent("screenshots", isDirectory: true)
    }

    static func collectionIconsDirectory(root: URL) -> URL {
        root.appendingPathComponent("collectionIcons", isDirectory: true)
    }
}

/// Identity for conflict resolution. The CloudMatch device id is stable across launches and already
/// used to identify this machine to the vendor, so it needs no second source of truth.
enum OPNCloudSyncDevice {
    static var identifier: String { OPNDeviceIdentity.stableCloudmatchDeviceId() }

    /// The reader-facing name of this Mac, so a conflict can say which machine a competing backup
    /// came from. The hostname is what Finder and System Settings call the machine.
    static var name: String {
        let host = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? "This Mac" : host
    }
}

/// A divergence the reader has to settle: both this Mac and the shared backup changed since the last
/// sync, and the two no longer agree, so folding one over the other would silently discard work.
/// Carries which category diverged, and who wrote the backup, so a prompt can name both.
public struct OPNCloudSyncConflict: Equatable, Sendable, Identifiable {
    public let category: OPNCloudSyncCategory
    public var remoteDeviceID: String
    public var remoteDeviceName: String?
    public var remoteGeneratedAt: Date

    public var id: OPNCloudSyncCategory { category }

    public init(category: OPNCloudSyncCategory, remoteDeviceID: String, remoteDeviceName: String?, remoteGeneratedAt: Date) {
        self.category = category
        self.remoteDeviceID = remoteDeviceID
        self.remoteDeviceName = remoteDeviceName
        self.remoteGeneratedAt = remoteGeneratedAt
    }

    /// The name to show in the prompt, never empty.
    public var remoteDisplayName: String {
        guard let name = remoteDeviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "another Mac"
        }
        return name
    }
}

/// A `UserDefaults` value as a binary property list, so it round-trips through JSON without OpenNOW
/// guessing at its type. Property lists carry exactly the types `UserDefaults` stores.
enum OPNCloudSyncPlist {
    static func encode(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> Any? {
        try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
    }

    /// Type-aware equality: `NSObject.isEqual` alone treats the boolean `true` as the integer `1`,
    /// so boolean-ness is compared first and a bool is never declared unchanged against a number.
    static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        let left = lhs as AnyObject
        let right = rhs as AnyObject
        let leftIsBool = CFGetTypeID(left) == CFBooleanGetTypeID()
        let rightIsBool = CFGetTypeID(right) == CFBooleanGetTypeID()
        guard leftIsBool == rightIsBool else { return false }
        return leftIsBool ? (left as? Bool) == (right as? Bool) : left.isEqual(right)
    }
}

/// Why a sync could not proceed. Surfaced through the coordinator's status so the reader is told,
/// rather than a backup being silently overwritten by a build that does not understand it.
enum OPNCloudSyncError: LocalizedError {
    case backupFromNewerBuild(found: Int, supported: Int)
    case backupUnreadable

    var errorDescription: String? {
        switch self {
        case .backupFromNewerBuild(let found, let supported):
            return "The iCloud backup uses a newer format (version \(found)); this build understands version \(supported). Update OpenNOW to sync."
        case .backupUnreadable:
            return "The iCloud backup could not be read. Check that iCloud Drive is available, then try again."
        }
    }
}

/// The shared JSON coding policy for every sync file: deterministic key order so two devices writing
/// the same content produce the same bytes, and millisecond dates to break an `updatedAt` tie.
enum OPNCloudSyncJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()

    /// Reads a synced file, materialising an iCloud item first. A coordinated read waits for a
    /// dataless item to download, so a not-yet-synced backup is never mistaken for an absent one.
    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = readData(at: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Whether a synced file is known to exist, including an iCloud item not downloaded yet.
    static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Reads a synced file's bytes, starting a download and coordinating when the item lives in
    /// iCloud. Returns nil only when the bytes could not be read.
    static func readData(at url: URL) -> Data? {
        let isUbiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? false
        if isUbiquitous {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        var coordinatedData: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            coordinatedData = try? Data(contentsOf: coordinatedURL)
        }
        guard coordinationError == nil else { return nil }
        return coordinatedData
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }
}

/// The container-level file: what a reader browsing iCloud Drive sees first, and how a future build
/// version refuses to consume a newer layout than it understands.
public struct OPNCloudSyncManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var deviceID: String
    /// The machine that wrote this file, so a reader browsing iCloud Drive can tell whose Mac it is.
    public var deviceName: String?
    public var generatedAt: Date

    public init(schemaVersion: Int = OPNCloudSyncLayout.schemaVersion, deviceID: String, deviceName: String? = nil, generatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.generatedAt = generatedAt
    }
}

/// One preference as it travels: its value, when it last changed, and which machine changed it.
public struct OPNCloudSyncSettingsEntry: Codable, Equatable, Sendable {
    public var plist: Data
    public var updatedAt: Date
    public var deviceID: String

    public init(plist: Data, updatedAt: Date, deviceID: String) {
        self.plist = plist
        self.updatedAt = updatedAt
        self.deviceID = deviceID
    }
}

public struct OPNCloudSyncSettingsFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    /// The machine that wrote this file, named so a conflict can be attributed to it.
    public var deviceName: String?
    public var entries: [String: OPNCloudSyncSettingsEntry]

    public init(schemaVersion: Int = OPNCloudSyncLayout.schemaVersion, deviceName: String? = nil, entries: [String: OPNCloudSyncSettingsEntry] = [:]) {
        self.schemaVersion = schemaVersion
        self.deviceName = deviceName
        self.entries = entries
    }
}

/// The OpenNOW-owned catalog data: user collections (per account) and the home rail arrangement.
/// Favorites, recently played, and playtime are absent — the vendor owns those.
public struct OPNCloudSyncCatalogFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var deviceID: String
    /// The machine that wrote this catalog, named so a conflict can be attributed to it.
    public var deviceName: String?
    public var collectionsByAccount: [String: [OPNUserCollection]]
    public var railOrder: [String]
    public var railsHidden: [String]

    public init(
        schemaVersion: Int = OPNCloudSyncLayout.schemaVersion,
        generatedAt: Date = Date(),
        deviceID: String,
        deviceName: String? = nil,
        collectionsByAccount: [String: [OPNUserCollection]] = [:],
        railOrder: [String] = [],
        railsHidden: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.collectionsByAccount = collectionsByAccount
        self.railOrder = railOrder
        self.railsHidden = railsHidden
    }
}

/// Maps an NVIDIA account identifier to the filename it lives under. The identifier can fall back
/// to an email address, so the container never stores it: only its hash reaches disk.
///
/// Namespaces are keyed by the *normalized* identifier. NVIDIA account ids and emails are
/// case-insensitive, and playtime and recently-played already store the lowercased form, so a
/// collections key that preserved the session's casing would otherwise put one account under two
/// namespaces and stop collections syncing between Macs.
public enum OPNCloudSyncAccountNamespace {
    static let collectionsKeyPrefix = "OpenNOW.Catalog.Collections."

    /// Every local key whose suffix is a catalog account identifier. Playtime and recently-played
    /// keys name an account with no collections yet, so a fresh sign-in still finds its namespace.
    static let accountKeyPrefixes = [
        collectionsKeyPrefix,
        "OpenNOW.Catalog.PlaytimeStatistics.",
        "OpenNOW.Catalog.RecentlyPlayed.",
    ]

    /// The other identifiers that name the signed-in account, so a Mac keying collections by user id
    /// and one falling back to an email share a namespace instead of splitting the backup.
    static let aliasesKey = "OpenNOW.Catalog.CollectionAccountAliases"
    /// The signed-in account, recorded so its namespace is importable before any local key exists.
    static let currentAccountsKey = "OpenNOW.Catalog.CollectionLocalAccounts"

    /// The account identifier's canonical spelling: trimmed and lowercased.
    public static func normalized(_ accountIdentifier: String) -> String {
        accountIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func hash(_ accountIdentifier: String) -> String {
        SHA256.hash(data: Data(accountIdentifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The namespace an account's collections travel under, keyed by the normalized identifier.
    public static func namespace(for accountIdentifier: String) -> String {
        hash(normalized(accountIdentifier))
    }

    /// Records the signed-in account and every other identifier that names it, so collections keyed
    /// under any of them resolve to one namespace.
    static func registerCurrentAccount(_ accountIdentifier: String, candidates: [String]) {
        let canonical = normalized(accountIdentifier)
        guard !canonical.isEmpty else { return }

        let storage = OPNAppPreferenceStorage.syncStore
        var current = Set(storage.array(forKey: currentAccountsKey) as? [String] ?? [])
        current.insert(canonical)
        storage.set(Array(current).sorted(), forKey: currentAccountsKey)

        var aliases = storage.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
        for candidate in candidates {
            let alias = normalized(candidate)
            guard !alias.isEmpty, alias != canonical else { continue }
            aliases[alias] = canonical
        }
        storage.set(aliases, forKey: aliasesKey)
    }

    /// The account identifiers this Mac knows, keyed by normalized namespace. Collections live in the
    /// synced store; playtime and recently-played stay in the standard domain.
    static func localAccounts() -> [String: String] {
        var accounts: [String: String] = [:]
        let syncStore = OPNAppPreferenceStorage.syncStore
        for identifier in syncStore.array(forKey: currentAccountsKey) as? [String] ?? [] {
            let canonical = normalized(identifier)
            guard !canonical.isEmpty else { continue }
            accounts[namespace(for: canonical)] = canonical
        }
        let syncKeys = syncStore.dictionaryRepresentation().keys
        for key in syncKeys where key.hasPrefix(collectionsKeyPrefix) {
            guard key != CatalogCollectionsStore.localOnlyNoticeKey else { continue }
            guard let identifier = accountIdentifier(inKey: key, prefix: collectionsKeyPrefix) else { continue }
            accounts[namespace(for: identifier)] = identifier
        }
        let standardKeys = OPNAppPreferenceStorage.standard.dictionaryRepresentation().keys
        for prefix in accountKeyPrefixes where prefix != collectionsKeyPrefix {
            for key in standardKeys where key.hasPrefix(prefix) {
                guard let identifier = accountIdentifier(inKey: key, prefix: prefix) else { continue }
                let namespace = namespace(for: identifier)
                if accounts[namespace] == nil { accounts[namespace] = identifier }
            }
        }
        return accounts
    }

    /// The same accounts keyed by every namespace a shared file might have used: the normalized one,
    /// a pre-normalization spelling, and every alias identifier for the account.
    static func importableAccounts() -> [String: String] {
        var accounts: [String: String] = [:]
        for (namespace, identifier) in localAccounts() {
            accounts[namespace] = identifier
            let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw != normalized(raw) { accounts[hash(raw)] = identifier }
        }
        let knownAccounts = localAccounts()
        for (alias, canonical) in identityAliases() {
            guard let identifier = knownAccounts[namespace(for: canonical)] else { continue }
            accounts[hash(alias)] = identifier
        }
        return accounts
    }

    /// Each stale namespace paired with the canonical namespace it folds into: a pre-normalization
    /// spelling or an alias identifier, so the shared file converges on one namespace per account.
    static func aliasNormalizations() -> [String: String] {
        var aliases: [String: String] = [:]
        for identifier in localAccounts().values {
            let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw != normalized(raw) else { continue }
            aliases[hash(raw)] = namespace(for: raw)
        }
        let knownNamespaces = Set(localAccounts().values.map { namespace(for: $0) })
        for (alias, canonical) in identityAliases() where knownNamespaces.contains(namespace(for: canonical)) {
            aliases[hash(alias)] = namespace(for: canonical)
        }
        return aliases
    }

    /// Every alias identifier mapped to the canonical spelling of the account it names.
    private static func identityAliases() -> [String: String] {
        OPNAppPreferenceStorage.syncStore.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
    }

    private static func accountIdentifier(inKey key: String, prefix: String) -> String? {
        let identifier = String(key.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }
}
