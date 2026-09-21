import Foundation
import Testing
@testable import OpenNOW

/// The home rails the reader arranges: the catalog offers them, the arrangement decides their order
/// and which are drawn, and a rail it has never seen still appears at the bottom.
@Suite(.serialized) @MainActor struct CatalogHomeCustomizationTests {
    @Test func identitiesAlreadyArrangedLeadAndUnseenOnesFollow() {
        let ordered = OPNHomeCustomization.orderedIdentities(
            ["unseen-a", "known-b", "unseen-c", "known-a"],
            by: ["known-a", "known-b"]
        )
        #expect(ordered == ["known-a", "known-b", "unseen-a", "unseen-c"])
    }

    @Test func anEmptyArrangementLeavesTheCatalogOrderUntouched() {
        let identities = ["a", "b", "c"]
        #expect(OPNHomeCustomization.orderedIdentities(identities, by: []) == identities)
    }

    @Test func movingARailDownPassesTheTargetAndMovingItUpLandsBeforeIt() {
        let down = OPNHomeCustomization.moving("a", to: "c", in: ["a", "b", "c", "d"])
        #expect(down == ["b", "c", "a", "d"])

        let up = OPNHomeCustomization.moving("d", to: "b", in: ["a", "b", "c", "d"])
        #expect(up == ["a", "d", "b", "c"])
    }

    @Test func movingARailOntoItselfChangesNothing() {
        let result = OPNHomeCustomization.moving("a", to: "a", in: ["a", "b"])
        #expect(result == nil)
    }

    @Test func hidingARailRemovesItFromHomeButKeepsItInTheCard() {
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeCatalogViewModelForTesting()
        model.mainPanels = [Self.panel(sectionID: "rail-a", title: "Alpha"), Self.panel(sectionID: "rail-b", title: "Beta")]

        model.setHomeRailVisible("rail-b", isVisible: false)

        #expect(model.catalogSections.map(\.id) == ["rail-a"])
        #expect(model.homeRailRows.contains { $0.id == "rail-b" && !$0.isVisible })
    }

    @Test func reorderingARailMovesItInTheHomeOrder() {
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeCatalogViewModelForTesting()
        model.mainPanels = [
            Self.panel(sectionID: "rail-a", title: "Alpha"),
            Self.panel(sectionID: "rail-b", title: "Beta"),
            Self.panel(sectionID: "rail-c", title: "Gamma"),
        ]
        #expect(model.catalogSections.map(\.id) == ["rail-a", "rail-b", "rail-c"])

        model.moveHomeRail("rail-c", to: "rail-a")

        #expect(model.catalogSections.map(\.id) == ["rail-c", "rail-a", "rail-b"])
    }

    @Test func aCategoryTheCatalogAddsLaterAppearsAtTheBottomAndStaysVisible() {
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeCatalogViewModelForTesting()
        model.mainPanels = [
            Self.panel(sectionID: "rail-a", title: "Alpha"),
            Self.panel(sectionID: "rail-b", title: "Beta"),
        ]
        model.homeRailArrangement = OPNHomeCustomization.Arrangement(order: ["rail-b", "rail-a"], hidden: [])
        #expect(model.catalogSections.map(\.id) == ["rail-b", "rail-a"])

        model.mainPanels.append(Self.panel(sectionID: "rail-c", title: "Gamma"))

        #expect(model.catalogSections.map(\.id) == ["rail-b", "rail-a", "rail-c"])
        #expect(model.homeRailRows.last?.id == "rail-c")
        #expect(model.homeRailRows.last?.isVisible == true)
    }

    @Test func hidingARailRevealsTheOneBehindTheTenRailCap() {
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeCatalogViewModelForTesting()
        model.mainPanels = (0..<12).map { Self.panel(sectionID: "rail-\($0)", title: "Rail \($0)") }
        #expect(model.catalogSections.count == CatalogViewModel.maximumHomeRailCount)

        model.setHomeRailVisible("rail-0", isVisible: false)

        #expect(model.catalogSections.count == CatalogViewModel.maximumHomeRailCount)
        #expect(!model.catalogSections.contains { $0.id == "rail-0" })
        #expect(model.catalogSections.contains { $0.id == "rail-10" })
    }

    @Test func theJumpBackInToggleWritesThroughToItsOwnPreference() {
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeCatalogViewModelForTesting()
        let played = OPNCatalogGameObject(game: Self.gameInfo(id: "id-1", title: "Manor Lords"))
        model.catalogGames = [played]
        model.recentlyPlayed.record(title: "Manor Lords", appId: "id-1", store: "steam", playedAt: Date())
        #expect(model.catalogSections.first?.id == "jump-back-in")

        model.setHomeRailVisible(OPNHomeCustomization.jumpBackInRailID, isVisible: false)

        #expect(!model.catalogSections.contains { $0.id == "jump-back-in" })
        #expect(model.homeRailRows.first { $0.id == OPNHomeCustomization.jumpBackInRailID }?.isVisible == false)
        #expect(model.isHomeCustomized)
        #expect(OPNThemePreferences.isJumpBackInEnabled == false)

        model.resetHomeRailCustomization()
        #expect(OPNThemePreferences.isJumpBackInEnabled == true)
        #expect(!model.isHomeCustomized)
    }

    @Test func resettingRestoresTheCatalogOrderAndTurnsEveryRailBackOn() {
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeCatalogViewModelForTesting()
        model.mainPanels = [
            Self.panel(sectionID: "rail-a", title: "Alpha"),
            Self.panel(sectionID: "rail-b", title: "Beta"),
        ]
        model.moveHomeRail("rail-b", to: "rail-a")
        model.setHomeRailVisible("rail-a", isVisible: false)

        model.resetHomeRailCustomization()

        #expect(model.catalogSections.map(\.id) == ["rail-a", "rail-b"])
        #expect(model.homeRailRows.allSatisfy { $0.isVisible })
        #expect(!model.isHomeCustomized)
        #expect(!OPNHomeCustomization.arrangement.isCustom)
    }

    @Test func thePadShiftMovesARailOnePlaceAndStopsAtTheEnds() {
        defer { OPNHomeCustomization.arrangement = .default }
        let model = makeCatalogViewModelForTesting()
        model.mainPanels = [
            Self.panel(sectionID: "rail-a", title: "Alpha"),
            Self.panel(sectionID: "rail-b", title: "Beta"),
            Self.panel(sectionID: "rail-c", title: "Gamma"),
        ]

        model.shiftHomeRail("rail-a", by: 1)
        #expect(model.catalogSections.map(\.id) == ["rail-b", "rail-a", "rail-c"])

        model.shiftHomeRail("rail-a", by: -1)
        #expect(model.catalogSections.map(\.id) == ["rail-a", "rail-b", "rail-c"])

        model.shiftHomeRail("rail-c", by: 1)
        model.shiftHomeRail(OPNHomeCustomization.jumpBackInRailID, by: -1)
        #expect(model.catalogSections.map(\.id) == ["rail-a", "rail-b", "rail-c"])
        #expect(model.homeRailRows.first?.id == OPNHomeCustomization.jumpBackInRailID)
        #expect(model.homeRailRows.last?.id == "rail-c")
    }

    private static func panel(sectionID: String, title: String) -> OPNCatalogPanelObject {
        let game = gameInfo(id: "\(sectionID)-game", title: "\(title) Game")
        let section = OPNPanelSection(id: sectionID, title: title, games: [game])
        return OPNCatalogPanelObject(panel: OPNPanelResult(id: "main-panel", title: "MAIN", sections: [section]))
    }

    private static func gameInfo(id: String, title: String) -> OPNGameInfo {
        var game = OPNGameInfo()
        game.id = id
        game.title = title
        game.launchAppId = id
        game.variants = [OPNGameVariant(id: id, appStore: "STEAM", serviceStatus: "AVAILABLE", isPatching: false)]
        return game
    }
}
