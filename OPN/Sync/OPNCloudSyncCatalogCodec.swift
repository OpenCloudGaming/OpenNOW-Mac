import CryptoKit
import Foundation

/// Reads and writes the OpenNOW-owned catalog data: user collections and the home rail arrangement.
/// Favorites, recently played, and playtime are absent: they live on the vendor's service and are
/// re-fetched per account, so copying them would only create stale local state.
enum OPNCloudSyncCatalogCodec {
    static let baselineKey = "OpenNOW.CloudSync.CatalogBaseline"
    static let signatureBaselineKey = "OpenNOW.CloudSync.CatalogSignatureBaseline"

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
            let collections = CatalogCollectionsStore.load(accountIdentifier: identifier).collections
            guard !collections.isEmpty else { continue }
            collectionsByAccount[namespace] = collections
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

    /// Writes a shared catalog file back into local storage. Only accounts this Mac already knows can
    /// be restored: an account the reader has never signed into has no key to write to. Both the
    /// normalized namespace and a pre-normalization spelling map to the account, so a file written
    /// before namespaces changed casing still restores.
    static func apply(_ file: OPNCloudSyncCatalogFile) {
        let accounts = OPNCloudSyncAccountNamespace.importableAccounts()
        for (namespace, collections) in file.collectionsByAccount {
            guard let identifier = accounts[namespace] else { continue }
            CatalogCollectionsStore(collections: collections).save(accountIdentifier: identifier)
        }
        var arrangement = OPNHomeCustomization.arrangement
        arrangement.order = file.railOrder
        arrangement.hidden = Set(file.railsHidden)
        OPNHomeCustomization.arrangement = arrangement
    }

    /// Whether two files carry the same reader-visible catalog, ignoring when and where they were
    /// written. Used to decide whether an export has anything to say.
    static func isContentEqual(_ lhs: OPNCloudSyncCatalogFile, _ rhs: OPNCloudSyncCatalogFile) -> Bool {
        lhs.collectionsByAccount == rhs.collectionsByAccount
            && lhs.railOrder == rhs.railOrder
            && lhs.railsHidden == rhs.railsHidden
    }

    /// What reconciling one Mac's catalog with the shared file produced.
    struct MergeResult {
        var file: OPNCloudSyncCatalogFile
        var isLocalFileChanged: Bool
    }

    /// Reconciles local and shared catalog data. A remote file newer than the baseline is applied
    /// first, then local collections are folded over it; namespaces this Mac cannot map are carried
    /// through untouched rather than dropped.
    static func merge(
        remote: OPNCloudSyncCatalogFile?,
        baseline: Date?,
        device: String,
        now: Date = Date()
    ) -> MergeResult {
        var file = remote ?? snapshot()
        if let remote, isRemoteNewer(remote: remote, baseline: baseline) {
            apply(remote)
        }

        file = fileFoldingInLocalCatalog(file)

        // Drop a pre-normalization namespace only once the normalized one carries the account's
        // collections in this file. An account whose collections this Mac does not hold keeps its
        // stale spelling rather than being pruned into nothing.
        for (alias, normalized) in OPNCloudSyncAccountNamespace.aliasNormalizations() where file.collectionsByAccount[normalized] != nil {
            file.collectionsByAccount[alias] = nil
        }

        let isLocalFileChanged = remote.map { !isContentEqual(file, $0) || $0.schemaVersion != file.schemaVersion } ?? true
        file.generatedAt = now
        file.deviceID = device
        file.deviceName = OPNCloudSyncDevice.name
        file.schemaVersion = OPNCloudSyncLayout.schemaVersion
        return MergeResult(file: file, isLocalFileChanged: isLocalFileChanged)
    }

    // MARK: - Conflict detection

    /// A deterministic digest of the reader-visible catalog, ignoring when and where it was written.
    /// Two files with the same signature say the same thing, so the sync can tell whether a side
    /// changed by comparing against the signature it last settled on.
    static func contentSignature(_ file: OPNCloudSyncCatalogFile) -> String {
        let content = SignatureContent(
            collectionsByAccount: file.collectionsByAccount,
            railOrder: file.railOrder,
            railsHidden: file.railsHidden
        )
        guard let data = try? OPNCloudSyncJSON.encoder.encode(content) else { return "" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The divergence to surface, or nil when one side can simply be folded over the other.
    ///
    /// A conflict needs all three: a settled baseline, both sides changed since it, and the two now
    /// differing. Before the first successful sync there is no baseline, so the initial merge runs
    /// unattended; once both sides changed the same way there is nothing to choose.
    static func detectConflict(
        remote: OPNCloudSyncCatalogFile,
        baseline: SignatureBaseline?,
        local: OPNCloudSyncCatalogFile
    ) -> OPNCloudSyncConflict? {
        guard let baseline else { return nil }
        let localSignature = contentSignature(local)
        let remoteSignature = contentSignature(remote)
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
        guard let data = OPNAppPreferenceStorage.standard.data(forKey: signatureBaselineKey) else { return nil }
        return try? OPNCloudSyncJSON.decoder.decode(SignatureBaseline.self, from: data)
    }

    static func saveSignatureBaseline(_ baseline: SignatureBaseline) {
        guard let data = try? OPNCloudSyncJSON.encoder.encode(baseline) else { return }
        OPNAppPreferenceStorage.standard.set(data, forKey: signatureBaselineKey)
    }

    private struct SignatureContent: Encodable {
        let collectionsByAccount: [String: [OPNUserCollection]]
        let railOrder: [String]
        let railsHidden: [String]
    }

    private static func isRemoteNewer(remote: OPNCloudSyncCatalogFile, baseline: Date?) -> Bool {
        guard let baseline else { return true }
        return remote.generatedAt > baseline
    }

    /// Places every collection and the arrangement this Mac owns over the shared file, leaving the
    /// namespaces it has no key for in place.
    private static func fileFoldingInLocalCatalog(_ file: OPNCloudSyncCatalogFile) -> OPNCloudSyncCatalogFile {
        var result = file
        let local = snapshot()
        for (namespace, collections) in local.collectionsByAccount {
            result.collectionsByAccount[namespace] = collections
        }
        result.railOrder = local.railOrder
        result.railsHidden = local.railsHidden
        return result
    }

    static func loadBaseline() -> Date? {
        OPNAppPreferenceStorage.standard.object(forKey: baselineKey) as? Date
    }

    static func saveBaseline(_ date: Date) {
        OPNAppPreferenceStorage.standard.set(date, forKey: baselineKey)
    }
}
