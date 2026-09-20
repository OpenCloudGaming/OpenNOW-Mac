import Foundation
import Testing
@testable import OpenNOW

/// The persisted favorites cache, and the catalog writing it so a windowless menu bar launch has
/// something to paint before any `CatalogViewModel` exists.
@MainActor struct CatalogFavoritesCacheTests {
    @Test func favoritesRoundTripByAccount() {
        let identifier = "favorites-cache-\(UUID().uuidString)"
        defer { CatalogFavoritesCache(games: []).save(accountIdentifier: identifier) }

        let games = [
            OPNMenuBarGame(title: "Hades", appId: "fav-1", artworkURL: "https://cdn.example/hades.png"),
            OPNMenuBarGame(title: "Manor Lords", appId: "fav-2"),
        ]
        CatalogFavoritesCache(games: games).save(accountIdentifier: identifier)

        #expect(CatalogFavoritesCache.load(accountIdentifier: identifier).games == games)
        // Another account's key is untouched, and an empty identifier stores nothing.
        #expect(CatalogFavoritesCache.load(accountIdentifier: "someone-else").games.isEmpty)
        #expect(CatalogFavoritesCache.load(accountIdentifier: "").games.isEmpty)
    }

    @Test func anEmptyListClearsTheStoredFavorites() {
        let identifier = "favorites-cache-empty-\(UUID().uuidString)"
        defer { CatalogFavoritesCache(games: []).save(accountIdentifier: identifier) }

        CatalogFavoritesCache(games: [OPNMenuBarGame(title: "Hades", appId: "fav-1")]).save(accountIdentifier: identifier)
        #expect(!CatalogFavoritesCache.load(accountIdentifier: identifier).games.isEmpty)

        CatalogFavoritesCache(games: []).save(accountIdentifier: identifier)
        #expect(CatalogFavoritesCache.load(accountIdentifier: identifier).games.isEmpty)
    }

    @Test func theCatalogPersistsFavoritesForTheWindowlessSurface() {
        let model = makeCatalogViewModelForTesting()
        model.session.userId = "favorites-persist-\(UUID().uuidString)"
        let identifier = model.catalogAccountIdentifier
        defer { CatalogFavoritesCache(games: []).save(accountIdentifier: identifier) }

        let game = OPNCatalogGameObject()
        game.id = "fav-cache-1"
        game.title = "Hades"
        game.imageUrl = "https://cdn.example/hades.png"
        model.updateFavoriteGames([game])

        let cached = CatalogFavoritesCache.load(accountIdentifier: identifier).games
        #expect(cached.map(\.appId) == ["fav-cache-1"])
        #expect(cached.first?.title == "Hades")
        #expect(cached.first?.artworkURL == "https://cdn.example/hades.png")
    }
}
