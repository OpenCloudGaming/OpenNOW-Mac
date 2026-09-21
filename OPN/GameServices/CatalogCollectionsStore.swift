//  The account's user-defined collections, persisted locally. There is no vendor endpoint for them
//  and signing in does not restore them, so this machine is the only copy.

import Foundation

/// The local collections for one account, stored as JSON under a per-account key. An empty list
/// clears the key and an empty account identifier stores nothing, like `CatalogFavoritesCache`.
struct CatalogCollectionsStore: Equatable {
    private static let storagePrefix = "OpenNOW.Catalog.Collections"

    static let empty = CatalogCollectionsStore()

    let collections: [OPNUserCollection]

    init(collections: [OPNUserCollection] = []) {
        self.collections = Self.sanitized(collections)
    }

    static func load(accountIdentifier: String) -> CatalogCollectionsStore {
        guard !accountIdentifier.isEmpty,
              let data = OPNAppPreferenceStorage.standard.data(forKey: storageKey(accountIdentifier: accountIdentifier)),
              let decoded = try? JSONDecoder().decode([LossyCollection].self, from: data) else {
            return .empty
        }
        return CatalogCollectionsStore(collections: decoded.compactMap(\.value))
    }

    func save(accountIdentifier: String) {
        guard !accountIdentifier.isEmpty else { return }
        guard !collections.isEmpty else {
            OPNAppPreferenceStorage.standard.removeObject(forKey: Self.storageKey(accountIdentifier: accountIdentifier))
            return
        }
        guard let data = try? JSONEncoder().encode(collections) else { return }
        OPNAppPreferenceStorage.standard.set(data, forKey: Self.storageKey(accountIdentifier: accountIdentifier))
    }

    static func storageKey(accountIdentifier: String) -> String {
        "\(storagePrefix).\(accountIdentifier)"
    }

    private static let localOnlyNoticeKey = "\(storagePrefix).HasSeenLocalOnlyNotice"

    /// Whether the one-time explainer has been shown. Feature-wide rather than per account: the
    /// fact it teaches does not change when the reader signs in as someone else.
    static var isLocalOnlyNoticeSeen: Bool {
        get { OPNAppPreferenceStorage.standard.bool(forKey: localOnlyNoticeKey) }
        set { OPNAppPreferenceStorage.standard.set(newValue, forKey: localOnlyNoticeKey) }
    }

    /// Drops unusable collections, dedupes by id so the first wins, and caps the count. Every
    /// write and load passes through here, so what is stored is always storable again.
    static func sanitized(_ collections: [OPNUserCollection]) -> [OPNUserCollection] {
        var seen = Set<String>()
        let valid = collections.compactMap(\.validated).filter { seen.insert($0.id).inserted }
        return Array(valid.prefix(OPNUserCollection.maximumCount))
    }
}

/// Decodes each array element independently, so one malformed collection cannot discard the rest.
private struct LossyCollection: Decodable {
    let value: OPNUserCollection?

    init(from decoder: Decoder) throws {
        value = try? OPNUserCollection(from: decoder)
    }
}
