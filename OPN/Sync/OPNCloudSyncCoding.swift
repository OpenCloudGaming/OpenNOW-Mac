import CryptoKit
import Foundation

/// The on-disk shapes and shared coders for the iCloud backup: a flat, self-describing layout under
/// the container's `Documents/OpenNOW/` folder that a reader can open in Finder.
public enum OPNCloudSyncLayout {
    /// Bumped to 2 when account namespaces were normalized to lowercase, so a build that only knows
    /// the old, case-preserving layout can be told apart from one that understands the new one.
    public static let schemaVersion = 2

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

    static func load<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
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

    /// The account identifiers stored on this Mac, keyed by their normalized namespace. A collections
    /// key wins over a playtime or recently-played key for the same account, because that is the key
    /// the app reads and writes collections under.
    static func localAccounts() -> [String: String] {
        var accounts: [String: String] = [:]
        let allKeys = OPNAppPreferenceStorage.standard.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix(collectionsKeyPrefix) {
            guard let identifier = accountIdentifier(inKey: key, prefix: collectionsKeyPrefix) else { continue }
            accounts[namespace(for: identifier)] = identifier
        }
        for prefix in accountKeyPrefixes where prefix != collectionsKeyPrefix {
            for key in allKeys where key.hasPrefix(prefix) {
                guard let identifier = accountIdentifier(inKey: key, prefix: prefix) else { continue }
                let namespace = namespace(for: identifier)
                if accounts[namespace] == nil { accounts[namespace] = identifier }
            }
        }
        return accounts
    }

    /// The same accounts keyed by every namespace a shared file might have used: the normalized one
    /// and, for an identifier whose stored casing differs, its pre-normalization namespace. Reading
    /// through this lets `apply` import collections a Mac wrote before namespaces were normalized.
    static func importableAccounts() -> [String: String] {
        var accounts: [String: String] = [:]
        for (namespace, identifier) in localAccounts() {
            accounts[namespace] = identifier
            let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw != normalized(raw) { accounts[hash(raw)] = identifier }
        }
        return accounts
    }

    /// Each pre-normalization namespace paired with its normalized replacement. The merge drops the
    /// stale spelling once the normalized namespace carries the account's collections, so the shared
    /// file converges on one spelling without a Mac that has never signed into the account losing it.
    static func aliasNormalizations() -> [String: String] {
        var aliases: [String: String] = [:]
        for identifier in localAccounts().values {
            let raw = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw != normalized(raw) else { continue }
            aliases[hash(raw)] = namespace(for: raw)
        }
        return aliases
    }

    private static func accountIdentifier(inKey key: String, prefix: String) -> String? {
        let identifier = String(key.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return identifier.isEmpty ? nil : identifier
    }
}
