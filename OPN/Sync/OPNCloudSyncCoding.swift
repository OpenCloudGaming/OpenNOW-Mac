import CryptoKit
import Foundation

/// The on-disk shapes and shared coders for the iCloud backup: a flat, self-describing layout under
/// the container's `Documents/OpenNOW/` folder that a reader can open in Finder.
public enum OPNCloudSyncLayout {
    public static let schemaVersion = 1

    static let manifestFileName = "manifest.json"
    static let settingsFileName = "settings/keys.json"
    static let catalogFileName = "catalog/catalog.json"

    static func url(root: URL, relativePath: String) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }

    static func screenshotsDirectory(root: URL) -> URL {
        root.appendingPathComponent("screenshots", isDirectory: true)
    }
}

/// Identity for conflict resolution. The CloudMatch device id is stable across launches and already
/// used to identify this machine to the vendor, so it needs no second source of truth.
enum OPNCloudSyncDevice {
    static var identifier: String { OPNDeviceIdentity.stableCloudmatchDeviceId() }
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
    public var generatedAt: Date

    public init(schemaVersion: Int = OPNCloudSyncLayout.schemaVersion, deviceID: String, generatedAt: Date = Date()) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
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
    public var entries: [String: OPNCloudSyncSettingsEntry]

    public init(schemaVersion: Int = OPNCloudSyncLayout.schemaVersion, entries: [String: OPNCloudSyncSettingsEntry] = [:]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }
}

/// The OpenNOW-owned catalog data: user collections (per account) and the home rail arrangement.
/// Favorites, recently played, and playtime are absent — the vendor owns those.
public struct OPNCloudSyncCatalogFile: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var deviceID: String
    public var collectionsByAccount: [String: [OPNUserCollection]]
    public var railOrder: [String]
    public var railsHidden: [String]

    public init(
        schemaVersion: Int = OPNCloudSyncLayout.schemaVersion,
        generatedAt: Date = Date(),
        deviceID: String,
        collectionsByAccount: [String: [OPNUserCollection]] = [:],
        railOrder: [String] = [],
        railsHidden: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.deviceID = deviceID
        self.collectionsByAccount = collectionsByAccount
        self.railOrder = railOrder
        self.railsHidden = railsHidden
    }
}

/// Maps an NVIDIA account identifier to the filename it lives under. The identifier can fall back
/// to an email address, so the container never stores it: only its hash reaches disk.
public enum OPNCloudSyncAccountNamespace {
    static let collectionsKeyPrefix = "OpenNOW.Catalog.Collections."

    /// Every local key whose suffix is a catalog account identifier. Playtime and recently-played
    /// keys name an account with no collections yet, so a fresh sign-in still finds its namespace.
    static let accountKeyPrefixes = [
        collectionsKeyPrefix,
        "OpenNOW.Catalog.PlaytimeStatistics.",
        "OpenNOW.Catalog.RecentlyPlayed.",
    ]

    public static func hash(_ accountIdentifier: String) -> String {
        SHA256.hash(data: Data(accountIdentifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// The account identifiers stored on this Mac, keyed by their hashed namespace.
    static func localAccounts() -> [String: String] {
        var accounts: [String: String] = [:]
        let allKeys = OPNAppPreferenceStorage.standard.dictionaryRepresentation().keys
        for prefix in accountKeyPrefixes {
            for key in allKeys where key.hasPrefix(prefix) {
                let identifier = String(key.dropFirst(prefix.count))
                guard !identifier.isEmpty else { continue }
                accounts[hash(identifier)] = identifier
            }
        }
        return accounts
    }
}
