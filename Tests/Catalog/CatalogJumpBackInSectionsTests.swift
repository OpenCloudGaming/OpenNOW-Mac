import Testing
import Foundation
@testable import OpenNOW

/// The Jump Back In rail: a locally tracked recently played game must resolve onto the catalog and
/// claim the first rail slot, above My Favorites and My Library.
@Suite @MainActor struct CatalogJumpBackInSectionsTests {
    private func makeModel() -> CatalogViewModel {
        makeCatalogViewModelForTesting()
    }

    @Test func aFinishedStreamLeadsTheHomeRailsAboveFavorites() {
        let model = makeModel()
        let played = OPNCatalogGameObject(game: Self.gameInfo(id: "id-1", title: "Manor Lords", launchAppId: "app-1"))
        let favorite = OPNCatalogGameObject(game: Self.gameInfo(id: "id-2", title: "Cyberpunk 2077", launchAppId: "app-2"))
        model.catalogGames = [played, favorite]
        model.favoriteGames = [favorite]

        model.recentlyPlayed.record(title: "Manor Lords", appId: "app-1", store: "steam", playedAt: Date())

        let sections = model.catalogSections
        #expect(sections.first?.id == "jump-back-in")
        #expect(sections.first?.title == "Jump Back In")
        #expect(sections.first?.games.map(\.title) == ["Manor Lords"])
        #expect(sections.first?.kind == .jumpBackIn)
        #expect(sections.dropFirst().contains { $0.id == "remote-favorites" })
    }

    @Test func disablingTheLookSettingRemovesTheRail() {
        let model = makeModel()
        model.catalogGames = [OPNCatalogGameObject(game: Self.gameInfo(id: "id-1", title: "Manor Lords", launchAppId: "app-1"))]

        model.recentlyPlayed.record(title: "Manor Lords", appId: "app-1", store: "steam", playedAt: Date())
        model.isJumpBackInEnabled = false

        #expect(model.jumpBackInGames.isEmpty)
        #expect(!model.catalogSections.contains { $0.id == "jump-back-in" })
    }

    @Test func aTitleTheCatalogNoLongerCarriesDropsOutOfTheRail() {
        let model = makeModel()
        model.catalogGames = [OPNCatalogGameObject(game: Self.gameInfo(id: "id-2", title: "Cyberpunk 2077", launchAppId: "app-2"))]

        model.recentlyPlayed.record(title: "Delisted Game", appId: "app-gone", store: "steam", playedAt: Date())

        #expect(model.jumpBackInGames.isEmpty)
        #expect(model.catalogSections.first?.id != "jump-back-in")
    }

    @Test func finishingAStreamRecordsTheGameForTheRail() {
        let model = makeModel()
        model.catalogGames = [OPNCatalogGameObject(game: Self.gameInfo(id: "id-1", title: "Manor Lords", launchAppId: "app-1"))]
        model.startPreparedStream(
            StreamLaunchConfiguration(
                title: "Manor Lords",
                applicationID: "app-1",
                accessToken: "t",
                accountLinked: false,
                selectedStore: "steam"
            ),
            message: "Starting..."
        )

        model.finishActiveStream(success: true, message: "", report: nil)

        #expect(model.recentlyPlayed.games.map(\.title) == ["Manor Lords"])
        #expect(model.catalogSections.first?.id == "jump-back-in")
    }

    @Test func finishingAStreamRecordsTheGameUnderItsCatalogIdentity() {
        let model = makeModel()
        model.catalogGames = [OPNCatalogGameObject(game: Self.gameInfo(id: "id-1", title: "Manor Lords", launchAppId: "app-1"))]
        model.startPreparedStream(
            StreamLaunchConfiguration(
                title: "Manor Lords",
                applicationID: "app-1",
                accessToken: "t",
                accountLinked: false,
                selectedStore: "steam"
            ),
            message: "Starting..."
        )

        model.finishActiveStream(success: true, message: "", report: nil)

        // The catalog identity, not the numeric launch app id, so the entry merges with the vendor's
        // server-side history for the same game instead of doubling it.
        #expect(model.recentlyPlayed.games.first?.appId == "id-1")
    }

    @Test func aFailedLaunchDoesNotClaimTheRail() {
        let model = makeModel()
        model.catalogGames = [OPNCatalogGameObject(game: Self.gameInfo(id: "id-1", title: "Manor Lords", launchAppId: "app-1"))]
        model.startPreparedStream(
            StreamLaunchConfiguration(
                title: "Manor Lords",
                applicationID: "app-1",
                accessToken: "t",
                accountLinked: false,
                selectedStore: "steam"
            ),
            message: "Starting..."
        )

        model.finishActiveStream(success: false, message: "Seat refused the title.", report: nil)

        #expect(model.recentlyPlayed == .empty)
        #expect(model.catalogSections.first?.id != "jump-back-in")
    }

    private static func gameInfo(id: String, title: String, launchAppId: String) -> OPNGameInfo {
        var game = OPNGameInfo()
        game.id = id
        game.title = title
        game.launchAppId = launchAppId
        game.variants = [OPNGameVariant(id: launchAppId, appStore: "STEAM", serviceStatus: "AVAILABLE", isPatching: false)]
        return game
    }

    @Test func serverHistorySeedsTheRailWithoutPlayingOnThisMac() {
        let model = makeModel()
        var played = Self.gameInfo(id: "id-1", title: "Manor Lords", launchAppId: "app-1")
        played.lastPlayedDate = "2026-09-01T12:00:00.000Z"
        model.catalogGames = [OPNCatalogGameObject(game: played)]

        model.applyServerRecentlyPlayed(from: [OPNCatalogGameObject(game: played)])

        #expect(model.recentlyPlayed.games.map(\.title) == ["Manor Lords"])
        #expect(model.catalogSections.first?.id == "jump-back-in")
        #expect(model.catalogSections.first?.games.map(\.title) == ["Manor Lords"])
    }

    @Test func theCatalogQueryStillAsksForTheServerLastPlayedDate() {
        #expect(OPNGameService.catalogQuery.contains("lastPlayedDate"))
        #expect(OPNGameService.catalogSearchQuery.contains("lastPlayedDate"))
    }
}
