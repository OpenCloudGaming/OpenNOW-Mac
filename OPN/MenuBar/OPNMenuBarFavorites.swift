import Foundation

/// Loads the menu bar's Favorites tab without a window.
///
/// Favorites reach the surface two ways. When a window exists, the catalog owns them and pushes its
/// live list through the session snapshot. When one does not — a menu-bar-only launch, where no
/// `CatalogViewModel` is ever built — this loader covers it: the persisted cache paints the tab at
/// once, and the vendor is asked for the current list in the background. A delivered list is written
/// back to the cache so the next windowless run starts warm.
@MainActor
enum OPNMenuBarFavorites {
    /// Supersedes an in-flight fetch when the account changes or the loader is started again, so a
    /// late response cannot replace a newer one.
    private static var fetchGeneration = 0

    /// Paints the cached favorites before any window or network. A no-op once a window owns the
    /// surface or the account has no cached favorites.
    static func primeFromCache(accountIdentifier: String) {
        guard !accountIdentifier.isEmpty else { return }
        OPNMenuBarSessionModel.shared.primeFavorites(
            CatalogFavoritesCache.load(accountIdentifier: accountIdentifier).games,
            accountIdentifier: accountIdentifier
        )
    }

    /// Fetches the account's favorites from the vendor without a window, delivering to the session
    /// model and refreshing the cache. The session must be usable — an expired one can only be
    /// refreshed from inside the window — and the request is dropped if a newer one supersedes it.
    static func start(accountIdentifier: String, accessToken: String, idToken: String) {
        guard !accountIdentifier.isEmpty, !accessToken.isEmpty || !idToken.isEmpty else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        OPNGameService.shared.configureCatalogSession(accessToken: accessToken, idToken: idToken, userId: accountIdentifier)
        OPNLog.info(.app, "Menu bar fetching favorites without a window")
        OPNGameService.shared.fetchFavoriteGameObjects { success, games, error in
            guard generation == fetchGeneration else { return }
            guard success else {
                OPNLog.warning(.app, "Menu bar favorites fetch failed error=\(error)")
                return
            }
            let favorites = games.map { game in
                let artwork = game.imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
                return OPNMenuBarGame(title: game.title, appId: game.catalogIdentity, artworkURL: artwork.isEmpty ? nil : artwork)
            }
            CatalogFavoritesCache(games: favorites).save(accountIdentifier: accountIdentifier)
            OPNMenuBarSessionModel.shared.applyFetchedFavorites(favorites, accountIdentifier: accountIdentifier)
        }
    }
}
