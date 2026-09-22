import Foundation
import Testing
@testable import OpenNOW

/// The Collections tab's state on the menu bar surface, kept in `MenuBarSessionTests`' serialized
/// suite because the model reads the process-wide stream lifecycle and the shared close preference.
extension MenuBarSessionTests {
    private var menuBarCollectionsPreferencesKey: String { OPNWindowClosePreferences.behaviorKey }

    private func preserveCollectionsCloseBehavior() -> Any? {
        UserDefaults.standard.object(forKey: menuBarCollectionsPreferencesKey)
    }

    private func restoreCollectionsCloseBehavior(_ existing: Any?) {
        if let existing {
            UserDefaults.standard.set(existing, forKey: menuBarCollectionsPreferencesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: menuBarCollectionsPreferencesKey)
        }
    }

    private func storeCollectionsCloseBehavior(_ behavior: OPNWindowCloseBehavior) {
        UserDefaults.standard.set(behavior.rawValue, forKey: menuBarCollectionsPreferencesKey)
    }

    /// The model observes `NotificationCenter.default` so the tests exercise the real posting path;
    /// a main-queue delivery needs the run loop to turn.
    private func waitForCollectionsDelivery() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    private func collection(id: String, name: String, games: [OPNMenuBarGame] = [], gameCount: Int? = nil) -> OPNMenuBarCollection {
        OPNMenuBarCollection(id: id, name: name, icon: nil, gameCount: gameCount ?? games.count, games: games)
    }

    @Test func collectionsArriveFromTheSnapshotAndSurviveADetach() async throws {
        let existing = preserveCollectionsCloseBehavior()
        defer { restoreCollectionsCloseBehavior(existing) }

        storeCollectionsCloseBehavior(.keepRunningInDock)
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        let spaceGames = collection(id: "c-1", name: "Space Games", games: [OPNMenuBarGame(title: "Starfield", appId: "game-1")])
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", collections: [spaceGames])

        model.attach(source: source)
        try await waitForCollectionsDelivery()
        #expect(model.collections == [spaceGames])

        // Closing the window to the tray detaches the source; the collections must survive so the
        // next windowless open still shows the tab.
        model.detachSource(source)
        #expect(model.collections == [spaceGames])

        // A launch in flight disables the rows; `starting` rather than `idle` keeps the read
        // independent of whether another suite has a stream running.
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .starting, title: "Starfield", collections: [spaceGames])
        model.attach(source: source)
        try await waitForCollectionsDelivery()
        #expect(!model.canLaunchCollections)
    }

    /// The windowless path: the local store and its resolved-game cache seed the tab before any
    /// source exists, and a live source's list is never overwritten by that seed.
    @Test func cachedCollectionsSeedTheTabUntilASourceOwnsIt() {
        let model = OPNMenuBarSessionModel()
        let cached = collection(id: "c-1", name: "Cached", games: [OPNMenuBarGame(title: "Hades", appId: "g-1")])
        model.primeCollections([cached], accountIdentifier: "user-1")
        #expect(model.collections == [cached])

        let source = StubMenuBarSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", collections: [collection(id: "c-2", name: "Live")])
        model.attach(source: source)
        defer { model.detachSource(source) }
        #expect(model.collections.map(\.name) == ["Live"])

        // Once a source owns the surface the seed is a no-op, so the live list stands.
        model.primeCollections([cached], accountIdentifier: "user-1")
        #expect(model.collections.map(\.name) == ["Live"])
    }

    /// The member lookup replaces the cache seed, but only for the account it was resolved for — a
    /// response that lands after an account change must not cross over.
    @Test func aFetchedCollectionListReplacesTheSeedOnlyForTheSameAccount() {
        let model = OPNMenuBarSessionModel()
        let cached = collection(id: "c-1", name: "Cached", games: [OPNMenuBarGame(title: "Hades", appId: "g-1")])
        model.primeCollections([cached], accountIdentifier: "user-1")

        let live = collection(id: "c-2", name: "Live", games: [OPNMenuBarGame(title: "Starfield", appId: "g-2")])
        model.applyFetchedCollections([live], accountIdentifier: "user-2")
        #expect(model.collections.map(\.name) == ["Cached"])

        model.applyFetchedCollections([live], accountIdentifier: "user-1")
        #expect(model.collections.map(\.name) == ["Live"])
    }

    @Test func collectionGameResolutionPublishesItsLoadingState() {
        let model = OPNMenuBarSessionModel()
        #expect(!model.isResolvingCollectionGames)

        model.setResolvingCollectionGames(true)
        #expect(model.isResolvingCollectionGames)

        model.setResolvingCollectionGames(false)
        #expect(!model.isResolvingCollectionGames)
    }

    @Test func launchingACollectionGameUsesTheSamePathAsARecentGame() async throws {
        let existing = preserveCollectionsCloseBehavior()
        defer { restoreCollectionsCloseBehavior(existing) }

        storeCollectionsCloseBehavior(.keepRunningInDock)
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        let game = OPNMenuBarGame(title: "Hades", appId: "g-1")
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", collections: [collection(id: "c-1", name: "Roguelikes", games: [game])])
        model.attach(source: source)
        try await waitForCollectionsDelivery()
        defer { model.detachSource(source) }

        model.requestLaunch(game)
        #expect(source.launchedGames.map(\.title) == ["Hades"])
    }

    /// One collection reduced for the surface: members keep their stored order, two identities that
    /// resolve to the same game collapse to one row, and the row still reports the stored size.
    @Test func theReductionKeepsStoredOrderAndCollapsesMembersThatResolveToOneGame() {
        let collection = OPNUserCollection(id: "c-1", name: "Space", gameIds: ["a", "b", "missing"])
        let first = OPNMenuBarGame(title: "Starfield", appId: "game-1")
        let second = OPNMenuBarGame(title: "Hades", appId: "game-2")

        let reduced = OPNMenuBarCollection(collection: collection) { identity in
            switch identity {
            case "a", "b": return first
            case "missing": return nil
            default: return second
            }
        }

        #expect(reduced.id == "c-1")
        #expect(reduced.name == "Space")
        #expect(reduced.gameCount == 3)
        #expect(reduced.games == [first])
        #expect(reduced.resolvedIcon == .fallback)
    }

    /// The windowless loader asks the vendor only for what its cache cannot name: cached members and
    /// a member two collections share are left out, and the surviving identities keep stored order.
    @Test func theWindowlessLoaderNamesOnlyTheMembersTheCacheCannot() {
        let collections = [
            OPNUserCollection(id: "c-1", name: "Space", gameIds: ["cached-game", "missing-game", "shared-game"]),
            OPNUserCollection(id: "c-2", name: "Roguelikes", gameIds: ["shared-game", "  ", "another-missing"]),
        ]
        let cached = ["cached-game": OPNMenuBarGame(title: "Hades", appId: "cached-game")]

        let unresolved = OPNMenuBarCollections.unresolvedIdentities(in: collections, gamesByIdentity: cached)
        #expect(unresolved == ["missing-game", "shared-game", "another-missing"])
    }
}

/// What the catalog hands the surface's Collections tab, in its own file so `MenuBarSessionTests`
/// stays within its length budget.
extension MenuBarCatalogSnapshotTests {
    @Test func snapshotOffersTheAccountsCollectionsWithTheirResolvedGames() {
        let model = makeCatalogViewModelForTesting()
        let known = OPNCatalogGameObject()
        known.id = "collection-game-1"
        known.title = "Hades"
        known.imageUrl = "https://cdn.example/hades.png"
        model.catalogGames = [known]
        model.userCollections = [
            OPNUserCollection(id: "c-2", name: "Space Games", gameIds: ["collection-game-1"]),
            OPNUserCollection(id: "c-1", name: "Backlog", gameIds: ["unknown-game"]),
        ]

        let collections = model.menuBarSnapshot.collections
        // The catalog's order, which is the order the app's own Collections surfaces list.
        #expect(collections.map(\.name) == ["Backlog", "Space Games"])
        #expect(collections.first?.gameCount == 1)
        #expect(collections.first?.games.isEmpty == true)
        #expect(collections.last?.games.map(\.title) == ["Hades"])
        #expect(collections.last?.games.first?.appId == "collection-game-1")
        #expect(collections.last?.games.first?.artworkURL == "https://cdn.example/hades.png")
    }
}
