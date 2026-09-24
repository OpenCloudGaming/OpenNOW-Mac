import CryptoKit
import Foundation

/// Reads and writes the OpenNOW-owned catalog data: user collections and the home rail arrangement.
/// Favorites, recently-played and playtime live on the vendor's service and are not copied.
enum OPNCloudSyncCatalogCodec {
    static let signatureBaselineKey = "OpenNOW.CloudSync.CatalogSignatureBaseline"
    /// How far ahead of this Mac a peer's write time is trusted. A peer with a fast clock would
    /// otherwise win every merge forever; one with a slow clock would have its writes ignored.
    private static let futureTimestampSkew: TimeInterval = 300

    /// The last catalog this Mac and the shared file agreed on, as content signatures rather than
    /// times: a signature tells the sync whether each side actually changed since, which is what
    /// separates "only they changed" and "only I changed" from a genuine conflict.
    struct SignatureBaseline: Codable, Equatable, Sendable {
        var local: String
        var remote: String
    }

    /// What one Mac's catalog looks like right now.
    static func snapshot() -> OPNCloudSyncCatalogFile {
        var collectionsByAccount: [String: [OPNUserCollection]] = [:]
        for (namespace, identifier) in OPNCloudSyncAccountNamespace.localAccounts() {
            let store = CatalogCollectionsStore.load(accountIdentifier: identifier)
            let records = store.collections + store.tombstones
            guard !records.isEmpty else { continue }
            collectionsByAccount[namespace] = records
        }
        let arrangement = OPNHomeCustomization.arrangement
        return OPNCloudSyncCatalogFile(
            deviceID: OPNCloudSyncDevice.identifier,
            deviceName: OPNCloudSyncDevice.name,
            collectionsByAccount: collectionsByAccount,
            railOrder: arrangement.order,
            railsHidden: Array(arrangement.hidden).sorted()
        )
    }

    /// Writes a shared catalog file back into local storage, only for accounts this Mac already knows:
    /// a normalized namespace and its pre-normalization spelling both map to the account.
    static func apply(_ file: OPNCloudSyncCatalogFile) {
        let accounts = OPNCloudSyncAccountNamespace.importableAccounts()
        for (namespace, records) in file.collectionsByAccount {
            guard let identifier = accounts[namespace] else { continue }
            save(records, for: identifier)
        }
        applyArrangement(from: file)
    }

    /// Replaces this Mac's catalog for every known account with the shared file, dropping local
    /// collections and tombstones the backup does not carry. The reader's "restore from iCloud" path.
    static func replaceLocal(with file: OPNCloudSyncCatalogFile) {
        let replacements = replacementRecords(for: file, accounts: OPNCloudSyncAccountNamespace.importableAccounts())
        for (identifier, records) in replacements {
            save(records, for: identifier)
        }
        applyArrangement(from: file)
    }

    /// The records every known account should hold after a restore: the backup's for an account it
    /// carries, and none for an account it does not, so a local-only collection cannot survive.
    static func replacementRecords(for file: OPNCloudSyncCatalogFile, accounts: [String: String]) -> [String: [OPNUserCollection]] {
        var recordsByIdentifier: [String: [OPNUserCollection]] = [:]
        for (namespace, records) in file.collectionsByAccount {
            guard let identifier = accounts[namespace] else { continue }
            recordsByIdentifier[identifier] = records
        }
        var replacements: [String: [OPNUserCollection]] = [:]
        for identifier in Set(accounts.values) {
            replacements[identifier] = recordsByIdentifier[identifier] ?? []
        }
        return replacements
    }

    /// Whether two files carry the same reader-visible catalog, ignoring when and where they were
    /// written. Used to decide whether an export has anything to say.
    static func isContentEqual(_ lhs: OPNCloudSyncCatalogFile, _ rhs: OPNCloudSyncCatalogFile) -> Bool {
        lhs.collectionsByAccount == rhs.collectionsByAccount
            && lhs.railOrder == rhs.railOrder
            && lhs.railsHidden == rhs.railsHidden
    }

    // MARK: - Merge

    /// What reconciling one Mac's catalog with the shared file produced.
    struct MergeResult {
        var file: OPNCloudSyncCatalogFile
        var isLocalFileChanged: Bool
    }

    /// Reconciles local and shared catalog data. Collections merge per identity with newest write
    /// winning, so an edit travels and a deletion survives a peer that still carries the collection.
    static func merge(
        remote: OPNCloudSyncCatalogFile?,
        device: String,
        now: Date = Date()
    ) -> MergeResult {
        var file = remote ?? snapshot()
        let local = snapshot()

        // The arrangement is one value, so this Mac's wins only when it has actually been arranged.
        // A fresh Mac's empty default must not overwrite the backup's rail order.
        if local.isArranged {
            file.railOrder = local.railOrder
            file.railsHidden = local.railsHidden
        }

        let aliases = OPNCloudSyncAccountNamespace.aliasNormalizations()
        var merged = file.collectionsByAccount
        for (namespace, localRecords) in local.collectionsByAccount {
            var remoteRecords = file.collectionsByAccount[namespace] ?? []
            // An alias spelling of this account carries the same account's collections.
            for (alias, normalized) in aliases where normalized == namespace {
                remoteRecords += file.collectionsByAccount[alias] ?? []
            }
            merged[namespace] = mergedRecords(local: localRecords, remote: remoteRecords, now: now)
        }
        for (alias, normalized) in aliases where merged[normalized] != nil {
            merged[alias] = nil
        }
        file.collectionsByAccount = merged.filter { !$0.value.isEmpty }

        // Converge local storage with the merged result only when it differs, so a settled pass writes.
        if !isContentEqual(file, local) {
            apply(file)
        }

        let isLocalFileChanged = remote.map { !isContentEqual(file, $0) || $0.schemaVersion != file.schemaVersion } ?? true
        file.generatedAt = now
        file.deviceID = device
        file.deviceName = OPNCloudSyncDevice.name
        file.schemaVersion = OPNCloudSyncLayout.schemaVersion
        return MergeResult(file: file, isLocalFileChanged: isLocalFileChanged)
    }

    /// Newest write wins per identity, with the local record breaking a tie. Local order is kept and
    /// remote-only records are appended, so nothing is silently dropped.
    static func mergedRecords(local: [OPNUserCollection], remote: [OPNUserCollection], now: Date) -> [OPNUserCollection] {
        var remoteByIdentity: [String: OPNUserCollection] = [:]
        for record in remote {
            remoteByIdentity[record.id] = newer(remoteByIdentity[record.id], than: record, now: now)
        }

        var result: [OPNUserCollection] = []
        var seen = Set<String>()
        for record in local {
            seen.insert(record.id)
            guard let peer = remoteByIdentity[record.id] else {
                result.append(record)
                continue
            }
            result.append(newer(record, than: peer, now: now))
        }
        for record in remote where !seen.contains(record.id) {
            result.append(record)
        }
        return result.filter { !isExpiredTombstone($0, now: now) }
    }

    private static func newer(_ existing: OPNUserCollection?, than candidate: OPNUserCollection, now: Date) -> OPNUserCollection {
        guard let existing else { return candidate }
        guard clampedModificationDate(candidate, now: now) > clampedModificationDate(existing, now: now) else { return existing }
        return candidate
    }

    private static func clampedModificationDate(_ record: OPNUserCollection, now: Date) -> Date {
        min(record.modificationDate, now.addingTimeInterval(futureTimestampSkew))
    }

    private static func isExpiredTombstone(_ record: OPNUserCollection, now: Date) -> Bool {
        guard record.isDeleted else { return false }
        return record.modificationDate < now.addingTimeInterval(-OPNUserCollection.tombstoneRetention)
    }

    private static func save(_ records: [OPNUserCollection], for accountIdentifier: String) {
        CatalogCollectionsStore(
            collections: records.filter { !$0.isDeleted },
            tombstones: records.filter { $0.isDeleted }
        ).save(accountIdentifier: accountIdentifier)
    }

    private static func applyArrangement(from file: OPNCloudSyncCatalogFile) {
        var arrangement = OPNHomeCustomization.arrangement
        arrangement.order = file.railOrder
        arrangement.hidden = Set(file.railsHidden)
        OPNHomeCustomization.arrangement = arrangement
    }

    // MARK: - Conflict detection

    /// A deterministic digest of the home arrangement, ignoring when and where it was written. The
    /// arrangement is the only catalog value that cannot merge, so it alone can raise a conflict.
    static func arrangementSignature(_ file: OPNCloudSyncCatalogFile) -> String {
        let content = SignatureContent(railOrder: file.railOrder, railsHidden: file.railsHidden)
        guard let data = try? OPNCloudSyncJSON.encoder.encode(content) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The divergence to surface, or nil when one side folds over the other. A conflict needs a
    /// settled baseline, both sides changed since it, and the two now differing.
    static func detectConflict(
        remote: OPNCloudSyncCatalogFile,
        baseline: SignatureBaseline?,
        local: OPNCloudSyncCatalogFile
    ) -> OPNCloudSyncConflict? {
        guard let baseline else { return nil }
        let localSignature = arrangementSignature(local)
        let remoteSignature = arrangementSignature(remote)
        guard localSignature != baseline.local,
              remoteSignature != baseline.remote,
              localSignature != remoteSignature else { return nil }
        return OPNCloudSyncConflict(
            category: .catalog,
            remoteDeviceID: remote.deviceID,
            remoteDeviceName: remote.deviceName,
            remoteGeneratedAt: remote.generatedAt
        )
    }

    static func loadSignatureBaseline() -> SignatureBaseline? {
        guard let data = OPNAppPreferenceStorage.syncStore.data(forKey: signatureBaselineKey) else { return nil }
        return try? OPNCloudSyncJSON.decoder.decode(SignatureBaseline.self, from: data)
    }

    static func saveSignatureBaseline(_ baseline: SignatureBaseline) {
        guard let data = try? OPNCloudSyncJSON.encoder.encode(baseline) else { return }
        let storage = OPNAppPreferenceStorage.syncStore
        guard storage.data(forKey: signatureBaselineKey) != data else { return }
        storage.set(data, forKey: signatureBaselineKey)
    }

    private struct SignatureContent: Encodable {
        let railOrder: [String]
        let railsHidden: [String]
    }
}

private extension OPNCloudSyncCatalogFile {
    /// Whether this Mac has arranged its home rails at all. An empty default is not an arrangement.
    var isArranged: Bool { !railOrder.isEmpty || !railsHidden.isEmpty }
}
