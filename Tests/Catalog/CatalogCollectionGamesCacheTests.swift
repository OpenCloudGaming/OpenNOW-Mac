import Foundation
import Testing
@testable import OpenNOW

/// The persisted collection-games cache, and the catalog writing it so a windowless menu bar launch
/// can paint each collection's games before any `CatalogViewModel` exists.
@MainActor struct CatalogCollectionGamesCacheTests {
    @Test func theCacheRoundTripsByAccount() {
        let identifier = "collection-games-\(UUID().uuidString)"
        defer { CatalogCollectionGamesCache().save(accountIdentifier: identifier) }

        let games = [
            "game-1": OPNMenuBarGame(title: "Hades", appId: "game-1", artworkURL: "https://cdn.example/hades.png"),
            "108118999": OPNMenuBarGame(title: "Aniimo", appId: "catalog-1"),
        ]
        CatalogCollectionGamesCache(gamesByIdentity: games).save(accountIdentifier: identifier)

        #expect(CatalogCollectionGamesCache.load(accountIdentifier: identifier).gamesByIdentity == games)
        // Another account's key is untouched, and an empty identifier stores nothing.
        #expect(CatalogCollectionGamesCache.load(accountIdentifier: "someone-else").gamesByIdentity.isEmpty)
        #expect(CatalogCollectionGamesCache.load(accountIdentifier: "").gamesByIdentity.isEmpty)
    }

    @Test func anEmptyCacheClearsTheStoredGames() {
        let identifier = "collection-games-empty-\(UUID().uuidString)"
        defer { CatalogCollectionGamesCache().save(accountIdentifier: identifier) }

        CatalogCollectionGamesCache(gamesByIdentity: ["game-1": OPNMenuBarGame(title: "Hades", appId: "game-1")])
            .save(accountIdentifier: identifier)
        #expect(!CatalogCollectionGamesCache.load(accountIdentifier: identifier).gamesByIdentity.isEmpty)

        CatalogCollectionGamesCache().save(accountIdentifier: identifier)
        #expect(CatalogCollectionGamesCache.load(accountIdentifier: identifier).gamesByIdentity.isEmpty)
    }

    /// A partial lookup must not shorten what is already cached: the same identity resolving again
    /// keeps the row that is already stored.
    @Test func mergingKeepsAnEntryThatIsAlreadyCached() {
        let cache = CatalogCollectionGamesCache(gamesByIdentity: ["game-1": OPNMenuBarGame(title: "Hades", appId: "game-1")])

        let merged = cache.merging([
            "game-1": OPNMenuBarGame(title: "Hades: Second Run", appId: "game-1"),
            "game-2": OPNMenuBarGame(title: "Starfield", appId: "game-2"),
        ])

        #expect(merged.gamesByIdentity["game-1"]?.title == "Hades")
        #expect(merged.gamesByIdentity["game-2"]?.title == "Starfield")
    }

    @Test func pruningDropsIdentitiesNoCollectionReferences() {
        let cache = CatalogCollectionGamesCache(gamesByIdentity: [
            "game-1": OPNMenuBarGame(title: "Hades", appId: "game-1"),
            "game-2": OPNMenuBarGame(title: "Starfield", appId: "game-2"),
        ])

        let pruned = cache.pruned(keeping: ["game-2"])
        #expect(pruned.gamesByIdentity.keys.sorted() == ["game-2"])
    }

    @Test func theCatalogWritesTheResolvedGamesForTheWindowlessSurface() {
        let model = makeCatalogViewModelForTesting()
        model.session.userId = "collection-persist-\(UUID().uuidString)"
        let identifier = model.collectionsAccountIdentifier
        defer { CatalogCollectionGamesCache().save(accountIdentifier: identifier) }

        let game = OPNCatalogGameObject()
        game.id = "collection-game-1"
        game.title = "Hades"
        game.imageUrl = "https://cdn.example/hades.png"
        model.catalogGames = [game]
        model.userCollections = [
            OPNUserCollection(id: "c-1", name: "Roguelikes", gameIds: ["collection-game-1", "unknown-game"]),
        ]
        model.persistUserCollections()

        let cached = CatalogCollectionGamesCache.load(accountIdentifier: identifier).gamesByIdentity
        #expect(cached["collection-game-1"]?.title == "Hades")
        #expect(cached["collection-game-1"]?.artworkURL == "https://cdn.example/hades.png")
        // A member the catalog cannot resolve is not invented, and stays pending for the next lookup.
        #expect(cached["unknown-game"] == nil)
    }
}
