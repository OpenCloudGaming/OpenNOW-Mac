//  The account's user-defined collections, persisted locally. There is no vendor endpoint for them
//  and signing in does not restore them, so this machine is the only copy.

import Foundation

/// The local collections for one account, stored as JSON under a per-account key. An empty list
/// clears the key; deleted collections are kept as tombstones so a peer cannot re-add them.
struct CatalogCollectionsStore: Equatable {
    private static let storagePrefix = "OpenNOW.Catalog.Collections"
    /// The most tombstones one account keeps, so a long-lived account cannot grow a delete log
    /// without bound. Tombstones also age out; this is only the hard ceiling.
    static let maximumTombstoneCount = 100

    /// Posted after any account's collections are written or cleared, because a store write has no
    /// other channel to a live view model that read its collections at launch.
    static let didChangeNotification = Notification.Name("OPNCatalogCollectionsStoreDidChange")
    /// The `userInfo` key naming the account whose collections changed.
    static let accountIdentifierKey = "accountIdentifier"

    static let empty = CatalogCollectionsStore()

    let collections: [OPNUserCollection]
    let tombstones: [OPNUserCollection]

    init(collections: [OPNUserCollection] = [], tombstones: [OPNUserCollection] = [], now: Date = Date()) {
        let sanitized = Self.sanitized(collections + tombstones, now: now)
        self.collections = sanitized.live
        self.tombstones = sanitized.tombstones
    }

    static func load(accountIdentifier: String) -> CatalogCollectionsStore {
        guard !accountIdentifier.isEmpty,
              let data = OPNAppPreferenceStorage.syncStore.data(forKey: resolveStorageKey(accountIdentifier: accountIdentifier)),
              let decoded = try? JSONDecoder().decode([LossyCollection].self, from: data) else {
            return .empty
        }
        return CatalogCollectionsStore(collections: decoded.compactMap(\.value))
    }

    func save(accountIdentifier: String) {
        guard !accountIdentifier.isEmpty else { return }
        let storage = OPNAppPreferenceStorage.syncStore
        let resolvedKey = Self.resolveStorageKey(accountIdentifier: accountIdentifier)
        let records = collections + tombstones
        guard !records.isEmpty else {
            guard storage.object(forKey: resolvedKey) != nil else { return }
            storage.removeObject(forKey: resolvedKey)
            announceChange(accountIdentifier: accountIdentifier)
            return
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        guard !Self.isStored(records, forKey: resolvedKey, in: storage) else { return }
        storage.set(data, forKey: resolvedKey)
        announceChange(accountIdentifier: accountIdentifier)
    }

    /// Compares decoded records, not encoded bytes: `JSONEncoder` key order is not byte-stable, so
    /// equal content can encode differently and would otherwise be rewritten on every pass.
    private static func isStored(_ records: [OPNUserCollection], forKey key: String, in storage: OPNAppPreferenceStorage) -> Bool {
        guard let existing = storage.data(forKey: key),
              let decoded = try? JSONDecoder().decode([OPNUserCollection].self, from: existing) else { return false }
        return decoded == records
    }

    /// The key an account's collections live under, resolved case-insensitively so a key written
    /// before casing was normalized is reused rather than a second, empty key created beside it.
    static func resolveStorageKey(accountIdentifier: String) -> String {
        let storage = OPNAppPreferenceStorage.syncStore
        let canonicalKey = storageKey(accountIdentifier: accountIdentifier)
        guard storage.object(forKey: canonicalKey) == nil else { return canonicalKey }
        let keyPrefix = "\(storagePrefix)."
        for key in storage.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            let storedIdentifier = String(key.dropFirst(keyPrefix.count))
            guard storedIdentifier.caseInsensitiveCompare(accountIdentifier) == .orderedSame else { continue }
            return key
        }
        return canonicalKey
    }

    static func storageKey(accountIdentifier: String) -> String {
        "\(storagePrefix).\(accountIdentifier)"
    }

    /// The key marking the one-time explainer as seen. Named so account-namespace enumeration can
    /// skip it: it shares the collections prefix but is not an account.
    static let localOnlyNoticeKey = "\(storagePrefix).HasSeenLocalOnlyNotice"

    /// Whether the one-time explainer has been shown. Feature-wide rather than per account: the
    /// fact it teaches does not change when the reader signs in as someone else.
    static var isLocalOnlyNoticeSeen: Bool {
        get { OPNAppPreferenceStorage.syncStore.bool(forKey: localOnlyNoticeKey) }
        set { OPNAppPreferenceStorage.syncStore.set(newValue, forKey: localOnlyNoticeKey) }
    }

    /// Drops unusable records, keeps the newest write per id, expires aged-out tombstones, and caps
    /// both lists. Every write and load passes through here, so what is stored is storable again.
    static func sanitized(_ records: [OPNUserCollection], now: Date = Date()) -> (live: [OPNUserCollection], tombstones: [OPNUserCollection]) {
        var newestByIdentity: [String: OPNUserCollection] = [:]
        var identityOrder: [String] = []
        for candidate in records {
            guard let valid = candidate.validated else { continue }
            keepNewest(valid, in: &newestByIdentity, order: &identityOrder)
        }

        let expiryCutoff = now.addingTimeInterval(-OPNUserCollection.tombstoneRetention)
        var live: [OPNUserCollection] = []
        var tombstones: [OPNUserCollection] = []
        for identity in identityOrder {
            guard let record = newestByIdentity[identity] else { continue }
            guard record.isDeleted else {
                live.append(record)
                continue
            }
            guard record.modificationDate >= expiryCutoff else { continue }
            tombstones.append(record)
        }
        return (Array(live.prefix(OPNUserCollection.maximumCount)), Array(tombstones.prefix(maximumTombstoneCount)))
    }

    /// Every image asset any account's live collections reference, so pruning keeps the icons of
    /// accounts other than the one on screen instead of deleting them.
    static func referencedImageAssetIdentifiers() -> Set<String> {
        var identifiers = Set<String>()
        for accountIdentifier in OPNCloudSyncAccountNamespace.localAccounts().values {
            for collection in load(accountIdentifier: accountIdentifier).collections {
                guard let icon = collection.icon?.validated, icon.kind == .image else { continue }
                identifiers.insert(icon.value)
            }
        }
        return identifiers
    }

    private static func keepNewest(_ candidate: OPNUserCollection, in newestByIdentity: inout [String: OPNUserCollection], order: inout [String]) {
        guard let existing = newestByIdentity[candidate.id] else {
            newestByIdentity[candidate.id] = candidate
            order.append(candidate.id)
            return
        }
        guard candidate.modificationDate > existing.modificationDate else { return }
        newestByIdentity[candidate.id] = candidate
    }

    private func announceChange(accountIdentifier: String) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [Self.accountIdentifierKey: accountIdentifier]
        )
    }
}

/// Decodes each array element independently, so one malformed collection cannot discard the rest.
private struct LossyCollection: Decodable {
    let value: OPNUserCollection?

    init(from decoder: Decoder) throws {
        value = try? OPNUserCollection(from: decoder)
    }
}
