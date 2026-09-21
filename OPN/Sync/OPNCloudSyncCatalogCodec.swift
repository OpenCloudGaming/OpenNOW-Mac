import Foundation

/// Reads and writes the OpenNOW-owned catalog data: user collections and the home rail arrangement.
/// Favorites, recently played, and playtime are absent: they live on the vendor's service and are
/// re-fetched per account, so copying them would only create stale local state.
enum OPNCloudSyncCatalogCodec {
    static let baselineKey = "OpenNOW.CloudSync.CatalogBaseline"

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
            collectionsByAccount: collectionsByAccount,
            railOrder: arrangement.order,
            railsHidden: Array(arrangement.hidden).sorted()
        )
    }

    /// Writes a shared catalog file back into local storage. Only accounts this Mac already knows can
    /// be restored: an account the reader has never signed into has no key to write to.
    static func apply(_ file: OPNCloudSyncCatalogFile) {
        let accounts = OPNCloudSyncAccountNamespace.localAccounts()
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
        let isLocalFileChanged = remote.map { !isContentEqual(file, $0) } ?? true
        file.generatedAt = now
        file.deviceID = device
        return MergeResult(file: file, isLocalFileChanged: isLocalFileChanged)
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
