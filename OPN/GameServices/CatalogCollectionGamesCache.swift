import Foundation

/// The collection members the app has already resolved, persisted per account so the menu bar's
/// Collections tab can paint its games before any window. Members are keyed by the identity asked for.
struct CatalogCollectionGamesCache: Codable, Equatable {
    private static let storagePrefix = "OpenNOW.Catalog.CollectionGames"

    let gamesByIdentity: [String: OPNMenuBarGame]

    init(gamesByIdentity: [String: OPNMenuBarGame] = [:]) {
        self.gamesByIdentity = gamesByIdentity
    }

    /// A copy with newly resolved games folded in. An entry that already exists is kept, so a partial
    /// lookup cannot shorten the list that is already on screen.
    func merging(_ resolved: [String: OPNMenuBarGame]) -> CatalogCollectionGamesCache {
        var merged = gamesByIdentity
        for (identity, game) in resolved where merged[identity] == nil {
            merged[identity] = game
        }
        return CatalogCollectionGamesCache(gamesByIdentity: merged)
    }

    /// A copy keeping only the identities the account's collections still reference, so a deleted
    /// member does not accumulate in the cache forever.
    func pruned(keeping referencedIdentities: Set<String>) -> CatalogCollectionGamesCache {
        CatalogCollectionGamesCache(gamesByIdentity: gamesByIdentity.filter { referencedIdentities.contains($0.key) })
    }

    static func load(accountIdentifier: String) -> CatalogCollectionGamesCache {
        guard !accountIdentifier.isEmpty,
              let data = OPNAppPreferenceStorage.standard.data(forKey: storageKey(accountIdentifier: accountIdentifier)),
              let cache = try? JSONDecoder().decode(CatalogCollectionGamesCache.self, from: data) else {
            return CatalogCollectionGamesCache()
        }
        return cache
    }

    func save(accountIdentifier: String) {
        guard !accountIdentifier.isEmpty else { return }
        guard !gamesByIdentity.isEmpty else {
            OPNAppPreferenceStorage.standard.removeObject(forKey: Self.storageKey(accountIdentifier: accountIdentifier))
            return
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        OPNAppPreferenceStorage.standard.set(data, forKey: Self.storageKey(accountIdentifier: accountIdentifier))
    }

    private static func storageKey(accountIdentifier: String) -> String {
        "\(storagePrefix).\(accountIdentifier)"
    }
}
