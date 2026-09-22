import Foundation

/// Loads the menu bar's Collections tab without a window: it paints the cached games from the local
/// store and asks `OPNGameService` for the members the catalog has not resolved yet.
@MainActor
enum OPNMenuBarCollections {
    /// Supersedes an in-flight lookup when the account changes or the loader starts again.
    private static var fetchGeneration = 0

    /// Paints the collections and their cached games before any window or network. A no-op once a
    /// window owns the surface or the account has no collections.
    static func primeFromCache(accountIdentifier: String) {
        guard !accountIdentifier.isEmpty else { return }
        let collections = CatalogCollectionsStore.load(accountIdentifier: accountIdentifier).collections
        guard !collections.isEmpty else { return }
        let cache = CatalogCollectionGamesCache.load(accountIdentifier: accountIdentifier)
        OPNMenuBarSessionModel.shared.primeCollections(
            reduced(collections, gamesByIdentity: cache.gamesByIdentity),
            accountIdentifier: accountIdentifier
        )
    }

    /// Resolves the collection members the cache cannot, and applies the result. Dropped if a newer
    /// lookup supersedes it; an expired session is left to the window that can refresh it.
    static func start(accountIdentifier: String, accessToken: String, idToken: String) {
        guard !accountIdentifier.isEmpty, !accessToken.isEmpty || !idToken.isEmpty else { return }
        let collections = CatalogCollectionsStore.load(accountIdentifier: accountIdentifier).collections
        guard !collections.isEmpty else { return }
        let referencedIdentities = Set(collections.flatMap(\.gameIds))
        let cache = CatalogCollectionGamesCache.load(accountIdentifier: accountIdentifier)
        let unresolved = unresolvedIdentities(in: collections, gamesByIdentity: cache.gamesByIdentity)
        guard !unresolved.isEmpty else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        OPNMenuBarSessionModel.shared.setResolvingCollectionGames(true)
        OPNGameService.shared.configureCatalogSession(accessToken: accessToken, idToken: idToken, userId: accountIdentifier)
        OPNLog.info(.app, "Menu bar resolving \(unresolved.count) collection games without a window")
        OPNGameService.shared.resolveCatalogGames(byIdentities: unresolved) { gamesByIdentity in
            guard generation == fetchGeneration else { return }
            OPNMenuBarSessionModel.shared.setResolvingCollectionGames(false)
            guard !gamesByIdentity.isEmpty else {
                OPNLog.warning(.app, "Menu bar collection game lookup resolved none of \(unresolved.count) identities")
                return
            }
            let resolved = gamesByIdentity.mapValues(OPNMenuBarGame.init(catalogGame:))
            let merged = cache.merging(resolved).pruned(keeping: referencedIdentities)
            merged.save(accountIdentifier: accountIdentifier)
            OPNLog.info(.app, "Menu bar resolved \(gamesByIdentity.count) of \(unresolved.count) collection games")
            OPNMenuBarSessionModel.shared.applyFetchedCollections(
                reduced(collections, gamesByIdentity: merged.gamesByIdentity),
                accountIdentifier: accountIdentifier
            )
        }
    }

    /// The collections reduced for the surface, each member looked up in the resolved games.
    private static func reduced(_ collections: [OPNUserCollection], gamesByIdentity: [String: OPNMenuBarGame]) -> [OPNMenuBarCollection] {
        collections.map { collection in
            OPNMenuBarCollection(collection: collection) { gamesByIdentity[$0] }
        }
    }

    /// The stored member identities the cache cannot name yet, deduped in stored order.
    static func unresolvedIdentities(in collections: [OPNUserCollection], gamesByIdentity: [String: OPNMenuBarGame]) -> [String] {
        var seen = Set<String>()
        var unresolved: [String] = []
        for collection in collections {
            for identity in collection.gameIds {
                let trimmed = identity.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, gamesByIdentity[trimmed] == nil, seen.insert(trimmed).inserted else { continue }
                unresolved.append(trimmed)
            }
        }
        return unresolved
    }
}
