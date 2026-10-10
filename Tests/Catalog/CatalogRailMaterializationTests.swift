import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

/// The home page's rails are built eagerly, so the window each rail materializes before the reader
/// scrolls is the whole first-frame tile budget. These pin the bound, and pin that the bound can
/// always be grown until it covers the rail - the cap must not truncate what the reader can reach.
@Suite(.serialized) @MainActor struct CatalogRailMaterializationTests {
    @Test func aWideRailMaterializesTheScreenItShowsPlusOneScreenOfScrollAhead() {
        // The P0-2 baseline window is 2197pt wide: 2133pt of usable width at a 368pt slot, so six
        // tiles are on screen and the window is twelve.
        let perScreen = CatalogRailMaterialization.tilesPerScreen(availableWidth: 2197, scale: 1, density: 1, isPoster: false)
        #expect(perScreen == 6)
        #expect(CatalogRailMaterialization.initialEnd(gameCount: 400, tilesPerScreen: perScreen) == 12)
    }

    @Test func aPosterRailShowsMoreTilesSoItsWindowIsWider() {
        let wide = CatalogRailMaterialization.tilesPerScreen(availableWidth: 2197, scale: 1, density: 1, isPoster: false)
        let poster = CatalogRailMaterialization.tilesPerScreen(availableWidth: 2197, scale: 1, density: 1, isPoster: true)
        #expect(poster == 10)
        #expect(poster > wide)
    }

    @Test func aPartiallyVisibleTileStillCountsAsOnScreen() {
        // 2133 / 368 = 5.79: six tiles are drawn, the sixth only in part. Rounding down would leave
        // the window's trailing edge one tile short of the viewport.
        #expect(CatalogRailMaterialization.tilesPerScreen(availableWidth: 2197, scale: 1, density: 1, isPoster: false) == 6)
        #expect(CatalogRailMaterialization.tilesPerScreen(availableWidth: 368 + 64 + 1, scale: 1, density: 1, isPoster: false) == 2)
    }

    @Test func anUnmeasuredPageStillMaterializesSomething() {
        #expect(CatalogRailMaterialization.tilesPerScreen(availableWidth: 0, scale: 1, density: 1, isPoster: false) == 1)
        #expect(CatalogRailMaterialization.tilesPerScreen(availableWidth: -1, scale: 1, density: 1, isPoster: false) == 1)
        #expect(CatalogRailMaterialization.initialEnd(gameCount: 9, tilesPerScreen: 1) == 2)
    }

    @Test func theWindowNeverMaterializesMoreThanTheRailHolds() {
        for gameCount in [0, 1, 5, 12, 13, 18, 400] {
            #expect(CatalogRailMaterialization.initialEnd(gameCount: gameCount, tilesPerScreen: 6) <= gameCount)
        }
        #expect(CatalogRailMaterialization.initialEnd(gameCount: 9, tilesPerScreen: 6) == 9)
        #expect(CatalogRailMaterialization.initialEnd(gameCount: 0, tilesPerScreen: 6) == 0)
    }

    @Test func theWindowAlwaysCoversTheScreenItDrawsInto() {
        for width: CGFloat in [600, 1200, 2197, 2560, 5120] {
            let perScreen = CatalogRailMaterialization.tilesPerScreen(availableWidth: width, scale: 1, density: 1, isPoster: false)
            #expect(CatalogRailMaterialization.initialEnd(gameCount: 400, tilesPerScreen: perScreen) >= perScreen)
        }
    }

    @Test func growingTheWindowReachesEveryGameInTheRail() {
        var end = CatalogRailMaterialization.initialEnd(gameCount: 37, tilesPerScreen: 6)
        #expect(end == 12)
        var steps = 0
        while end < 37 {
            let next = CatalogRailMaterialization.grownEnd(gameCount: 37, tilesPerScreen: 6, current: end)
            #expect(next > end)
            end = next
            steps += 1
            #expect(steps < 10)
        }
        #expect(end == 37)
    }

    @Test func growthStopsAtTheEndOfTheRail() {
        #expect(CatalogRailMaterialization.grownEnd(gameCount: 12, tilesPerScreen: 6, current: 12) == 12)
        #expect(CatalogRailMaterialization.grownEnd(gameCount: 37, tilesPerScreen: 6, current: 36) == 37)
        #expect(CatalogRailMaterialization.grownEnd(gameCount: 37, tilesPerScreen: 6, current: 0) == 18)
    }

    @Test func theWindowNeverStartsBeforeAGameTheRailHasToShow() {
        #expect(CatalogRailMaterialization.end(gameCount: 400, tilesPerScreen: 6, materialized: 0, required: 0) == 12)
        #expect(CatalogRailMaterialization.end(gameCount: 400, tilesPerScreen: 6, materialized: 0, required: 17) == 17)
        #expect(CatalogRailMaterialization.end(gameCount: 400, tilesPerScreen: 6, materialized: 24, required: 0) == 24)
        // A requirement past the rail clamps to the rail rather than reading past it.
        #expect(CatalogRailMaterialization.end(gameCount: 400, tilesPerScreen: 6, materialized: 0, required: 900) == 400)
        #expect(CatalogRailMaterialization.end(gameCount: 0, tilesPerScreen: 6, materialized: 0, required: 4) == 0)
    }

    @Test func aNarrowerRailMaterializesNoMoreThanAWiderOne() {
        var previous = 0
        for width: CGFloat in [600, 1200, 2197, 2560, 5120] {
            let perScreen = CatalogRailMaterialization.tilesPerScreen(availableWidth: width, scale: 1, density: 1, isPoster: false)
            #expect(perScreen >= previous)
            previous = perScreen
        }
    }

    @Test func aLargerInterfaceScaleFitsFewerTilesOnScreen() {
        let atOne = CatalogRailMaterialization.tilesPerScreen(availableWidth: 2560, scale: 1, density: 1, isPoster: false)
        let atOneAndHalf = CatalogRailMaterialization.tilesPerScreen(availableWidth: 2560, scale: 1.5, density: 1, isPoster: false)
        #expect(atOne == 7)
        #expect(atOneAndHalf <= atOne)
    }

    @Test func theWindowGrowsHalfAScreenBeforeTheTrailingEdge() {
        #expect(CatalogRailMaterialization.trailingTriggerDistance(availableWidth: 2197, scale: 1, density: 1, isPoster: false) == CGFloat(6 * 368 / 2))
    }

    @Test func theFirstFrameTileCountSumsTheWindowAcrossEveryRail() {
        let counts = [400, 400, 3]
        let total = CatalogRailMaterialization.firstFrameTileCount(gameCounts: counts, availableWidth: 2197, scale: 1, density: 1, isPoster: false)
        #expect(total == 12 + 12 + 3)
    }
}

/// The rails compare a section against the last one they prefetched for. Forming that comparison
/// value in the body built a `[String]` of every identity per rail per pass; it is folded once, when
/// the section is built.
@Suite(.serialized) @MainActor struct CatalogSectionIdentitySignatureTests {
    @Test func theSignatureChangesWhenTheGamesChange() {
        let base = Self.section(games: [Self.game(id: "a"), Self.game(id: "b")])
        let reordered = Self.section(games: [Self.game(id: "b"), Self.game(id: "a")])
        let replaced = Self.section(games: [Self.game(id: "a"), Self.game(id: "c")])
        let same = Self.section(games: [Self.game(id: "a"), Self.game(id: "b")])

        #expect(base.gameIdentitySignature == same.gameIdentitySignature)
        #expect(base.gameIdentitySignature != replaced.gameIdentitySignature)
        #expect(base.gameIdentitySignature != reordered.gameIdentitySignature)
    }

    @Test func aRailHandsItsRowNoMoreThanTheRailCap() {
        let games = (0..<40).map { Self.game(id: "g\($0)") }
        let section = Self.section(games: games)
        #expect(section.games.count == 40)
        #expect(section.visibleGames(expanded: false).count == CatalogSectionModel.maximumRailGameCount)
        #expect(section.visibleGames(expanded: true).count == 40)
    }

    private static func section(games: [OPNCatalogGameObject]) -> CatalogSectionModel {
        CatalogSectionModel(id: "rail", title: "Rail", games: games, kind: .panel)
    }

    private static func game(id: String) -> OPNCatalogGameObject {
        var info = OPNGameInfo()
        info.id = id
        info.title = "Game \(id)"
        info.launchAppId = id
        info.variants = [OPNGameVariant(id: id, appStore: "STEAM", serviceStatus: "AVAILABLE", isPatching: false)]
        return OPNCatalogGameObject(game: info)
    }
}

/// `homeRailRows` is read by the customization card and by the two rail-moving commands. It rebuilt
/// a dictionary plus two `contains` scans per call while every other derived collection was cached.
@Suite(.serialized) @MainActor struct CatalogHomeRailRowsCacheTests {
    @Test func theRowsAreCachedUntilAnInputChanges() {
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeCatalogViewModelForTesting()
        model.mainPanels = [Self.panel(sectionID: "rail-a", title: "Alpha")]

        let first = model.homeRailRows
        #expect(model.cachedHomeRailRows == first)

        model.setHomeRailVisible("rail-a", isVisible: false)
        #expect(model.cachedHomeRailRows == nil)

        #expect(model.homeRailRows.first { $0.id == "rail-a" }?.isVisible == false)
        #expect(model.cachedHomeRailRows != nil)
    }

    @Test func aCatalogReloadRebuildsTheRows() {
        let model = makeCatalogViewModelForTesting()
        model.mainPanels = [Self.panel(sectionID: "rail-a", title: "Alpha")]
        #expect(model.homeRailRows.contains { $0.title == "Alpha" })

        model.mainPanels = [Self.panel(sectionID: "rail-b", title: "Beta")]
        #expect(model.homeRailRows.contains { $0.title == "Beta" })
        #expect(!model.homeRailRows.contains { $0.title == "Alpha" })
    }

    private static func panel(sectionID: String, title: String) -> OPNCatalogPanelObject {
        var game = OPNGameInfo()
        game.id = "\(sectionID)-game"
        game.title = "\(title) Game"
        game.launchAppId = game.id
        game.variants = [OPNGameVariant(id: game.id, appStore: "STEAM", serviceStatus: "AVAILABLE", isPatching: false)]
        let section = OPNPanelSection(id: sectionID, title: title, games: [game])
        return OPNCatalogPanelObject(panel: OPNPanelResult(id: "main-panel", title: "MAIN", sections: [section]))
    }
}
