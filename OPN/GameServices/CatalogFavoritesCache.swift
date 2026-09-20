import Foundation

/// The account's favorites, persisted so the menu bar's Favorites tab can paint before any window
/// exists.
///
/// Favorites live on the vendor, and the catalog keeps them only in memory. Without a local copy a
/// menu-bar-only launch — where no `CatalogViewModel` is ever built to push the list — had nothing
/// to show until a window loaded the catalog. The catalog writes this cache whenever the live list
/// changes, and `OPNMenuBarFavorites` reads it at launch, so the tab fills on the next windowless run.
struct CatalogFavoritesCache: Codable, Equatable {
    private static let storagePrefix = "OpenNOW.Catalog.Favorites"

    static let empty = CatalogFavoritesCache()

    private(set) var games: [OPNMenuBarGame]

    init(games: [OPNMenuBarGame] = []) {
        self.games = games
    }

    static func load(accountIdentifier: String) -> CatalogFavoritesCache {
        guard !accountIdentifier.isEmpty,
              let data = OPNAppPreferenceStorage.standard.data(forKey: storageKey(accountIdentifier: accountIdentifier)),
              let cache = try? JSONDecoder().decode(CatalogFavoritesCache.self, from: data) else {
            return .empty
        }
        return cache
    }

    func save(accountIdentifier: String) {
        guard !accountIdentifier.isEmpty else { return }
        // An empty list has nothing to paint and would only leave a stale entry behind on sign-out.
        guard !games.isEmpty else {
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
