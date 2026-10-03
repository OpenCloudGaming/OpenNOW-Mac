//  The account-scoped state the catalog reads at launch: the reader's collections, playtime and
//  recently-played, plus the collection-icon prune. All three are disk reads - a directory listing
//  and `UserDefaults` lookups - that used to run inline on the main actor from `start()`, before the
//  first frame was built. They run on the generic executor now; the surfaces that display them wait
//  on `awaitAccountScopedState()` rather than painting an empty list that fills in a frame later.

import Foundation

extension CatalogViewModel {
    /// Reads the account's collections, playtime and recently-played, and prunes orphaned collection
    /// icons, on the generic executor.
    func startAccountScopedStateLoad() {
        // Read on the main actor first: the identifiers are derived from the account and session
        // models, which are not safe to touch once the work moves off it.
        let playtimeIdentifier = Self.playtimeAccountIdentifier(account: account, session: session)
        let collectionsIdentifier = collectionsAccountIdentifier
        let accountIdentifiers = [session.userId, account.userId, account.externalUserId, account.email]
        accountScopedStateTask = Task { [weak self] in
            let state = await Self.readAccountScopedState(
                playtimeAccountIdentifier: playtimeIdentifier,
                collectionsAccountIdentifier: collectionsIdentifier,
                accountIdentifiers: accountIdentifiers
            )
            guard let self else { return }
            self.playtimeStatistics = state.playtimeStatistics
            self.recentlyPlayed = state.recentlyPlayed
            self.userCollections = state.collections
            self.hasLoadedAccountScopedState = true
        }
    }

    /// Waits for the account-scoped disk work `start()` deferred. A surface that displays collections,
    /// playtime or recently-played on its first frame awaits this before reading them.
    func awaitAccountScopedState() async {
        await accountScopedStateTask?.value
    }
}
