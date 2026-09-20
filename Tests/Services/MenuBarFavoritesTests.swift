import Foundation
import Testing
@testable import OpenNOW

/// The Favorites tab's state on the menu bar surface: favorites arriving from the catalog snapshot,
/// surviving a source detach for the windowless surface, and launching through the same path a
/// Continue Playing row does.
///
/// An extension of `MenuBarSessionTests` rather than a second suite, because the model reads the
/// process-wide stream lifecycle and the shared close-behavior preference — and Swift Testing does
/// not serialize two suites against each other. It lives in its own file to keep the suite within
/// its length budget.
extension MenuBarSessionTests {
    private var menuBarFavoritesPreferencesKey: String { OPNWindowClosePreferences.behaviorKey }

    private func preserveFavoritesCloseBehavior() -> Any? {
        UserDefaults.standard.object(forKey: menuBarFavoritesPreferencesKey)
    }

    private func restoreFavoritesCloseBehavior(_ existing: Any?) {
        if let existing {
            UserDefaults.standard.set(existing, forKey: menuBarFavoritesPreferencesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: menuBarFavoritesPreferencesKey)
        }
    }

    private func storeFavoritesCloseBehavior(_ behavior: OPNWindowCloseBehavior) {
        UserDefaults.standard.set(behavior.rawValue, forKey: menuBarFavoritesPreferencesKey)
    }

    /// The model observes `NotificationCenter.default` so the tests exercise the real posting path;
    /// a main-queue delivery needs the run loop to turn.
    private func waitForFavoritesDelivery() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func favoritesArriveFromTheSnapshotAndSurviveADetach() async throws {
        let existing = preserveFavoritesCloseBehavior()
        defer { restoreFavoritesCloseBehavior(existing) }

        storeFavoritesCloseBehavior(.keepRunningInDock)
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        let game = OPNMenuBarGame(title: "Hades", appId: "fav-1")
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", favorites: [game])

        model.attach(source: source)
        try await waitForFavoritesDelivery()
        #expect(model.favorites == [game])

        // Closing the window to the tray detaches the source; the favorites must survive so the
        // next windowless open still shows the tab.
        model.detachSource(source)
        #expect(model.favorites == [game])

        // The rows disable whenever a launch is in flight: a launch belongs to the catalog, which
        // refuses one while a session is already running. `starting` is used rather than `idle` so
        // the read does not depend on whether another suite has a stream running — the process-wide
        // lifecycle outranks an idle snapshot, and `.serialized` does not serialize suites.
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .starting, title: "Hades", favorites: [game])
        model.attach(source: source)
        try await waitForFavoritesDelivery()
        #expect(!model.canLaunchFavorites)
    }

    @Test func launchingAFavoriteUsesTheSamePathAsARecentGame() async throws {
        let existing = preserveFavoritesCloseBehavior()
        defer { restoreFavoritesCloseBehavior(existing) }

        storeFavoritesCloseBehavior(.keepRunningInDock)
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        let favorite = OPNMenuBarGame(title: "Hades", appId: "fav-1")
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", favorites: [favorite])
        model.attach(source: source)
        try await waitForFavoritesDelivery()
        defer { model.detachSource(source) }

        model.requestLaunch(favorite)
        #expect(source.launchedGames.map(\.title) == ["Hades"])
    }

    /// The windowless path: the persisted cache seeds the tab before any source exists, and a live
    /// source's list is never overwritten by that seed.
    @Test func cachedFavoritesSeedTheTabUntilASourceOwnsIt() {
        let model = OPNMenuBarSessionModel()
        let cached = OPNMenuBarGame(title: "Hades", appId: "fav-1")
        model.primeFavorites([cached], accountIdentifier: "user-1")
        #expect(model.favorites == [cached])

        let source = StubMenuBarSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", favorites: [OPNMenuBarGame(title: "Live", appId: "live-1")])
        model.attach(source: source)
        defer { model.detachSource(source) }
        #expect(model.favorites.map(\.title) == ["Live"])

        // Once a source owns the surface the seed is a no-op, so the live list stands.
        model.primeFavorites([OPNMenuBarGame(title: "Stale", appId: "stale-1")], accountIdentifier: "user-1")
        #expect(model.favorites.map(\.title) == ["Live"])
    }

    /// The server result replaces the cache seed, but only for the account it was fetched for — a
    /// response that lands after an account change must not cross over.
    @Test func aFetchedListReplacesTheSeedOnlyForTheSameAccount() {
        let model = OPNMenuBarSessionModel()
        let cached = OPNMenuBarGame(title: "Cached", appId: "cached-1")
        model.primeFavorites([cached], accountIdentifier: "user-1")

        let live = OPNMenuBarGame(title: "Hades", appId: "fav-1")
        model.applyFetchedFavorites([live], accountIdentifier: "user-2")
        #expect(model.favorites == [cached])

        model.applyFetchedFavorites([live], accountIdentifier: "user-1")
        #expect(model.favorites == [live])
    }
}
