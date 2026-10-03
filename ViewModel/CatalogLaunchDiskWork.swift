//  The launch's account-scoped disk work: the collection-icon prune and the reads behind
//  collections, playtime and recently-played. Runs on the generic executor, never the main actor.

import Foundation

/// What the launch's account-scoped disk work loads, carried back to the main actor in one hop so
/// the observable properties are assigned together and no observer sees a half-applied state.
struct CatalogAccountScopedState: Sendable {
    let playtimeStatistics: CatalogPlaytimeStatistics
    let recentlyPlayed: CatalogRecentlyPlayed
    let collections: [OPNUserCollection]
}

extension CatalogViewModel {
    /// Runs both launch disk scans on the generic executor: the account-namespace registration and
    /// state reads, then the orphan-icon prune that depends on that registration.
    nonisolated static func loadAccountScopedLaunchState(
        playtimeAccountIdentifier: String,
        collectionsAccountIdentifier: String,
        accountIdentifiers: [String]
    ) async -> CatalogAccountScopedState {
        OPNCloudSyncAccountNamespace.registerCurrentAccount(
            collectionsAccountIdentifier,
            candidates: accountIdentifiers
        )
        let accountScopedState = CatalogAccountScopedState(
            playtimeStatistics: CatalogPlaytimeStatistics.load(accountIdentifier: playtimeAccountIdentifier),
            recentlyPlayed: CatalogRecentlyPlayed.load(accountIdentifier: playtimeAccountIdentifier),
            collections: CatalogCollectionsStore.load(accountIdentifier: collectionsAccountIdentifier).collections
        )
        pruneOrphanedCollectionIcons()
        return accountScopedState
    }

    /// Starts that work and applies what it read. `start()` calls this and waits for nothing.
    func startAccountScopedStateLoad() {
        // Identifiers first, on the main actor: the account and session models are not safe to
        // read once the work moves off it.
        let playtimeIdentifier = Self.playtimeAccountIdentifier(account: account, session: session)
        let collectionsIdentifier = collectionsAccountIdentifier
        let accountIdentifiers = [session.userId, account.userId, account.externalUserId, account.email]
        accountScopedStateTask = Task { [weak self] in
            let accountScopedState = await Self.loadAccountScopedLaunchState(
                playtimeAccountIdentifier: playtimeIdentifier,
                collectionsAccountIdentifier: collectionsIdentifier,
                accountIdentifiers: accountIdentifiers
            )
            guard let self else { return }
            self.playtimeStatistics = accountScopedState.playtimeStatistics
            self.recentlyPlayed = accountScopedState.recentlyPlayed
            self.userCollections = accountScopedState.collections
            self.isAccountScopedStateLoaded = true
        }
    }

    /// Waits for the disk work `start()` deferred. A surface that shows collections, playtime or
    /// recently-played on its first frame awaits this before reading them.
    func awaitAccountScopedState() async {
        await accountScopedStateTask?.value
    }
}
