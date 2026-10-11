import Foundation
import Testing
@testable import OpenNOW

/// Pins the collection icon picker's search ranking, so moving the name normalisation to catalog
/// load stays a pure move of work: the weights and the rules behind them are unchanged.
@Suite struct CollectionSymbolSearchTests {
    private let allCategoryID = OPNCollectionSymbolCatalog.allCategoryID

    /// The picker's catalog loads from the app bundle, which the SwiftPM test runner does not carry,
    /// so the assertions below run against the inline fallback set.
    private func assertInlineCatalogIsLoaded() {
        #expect(OPNCollectionSymbolCatalog.symbols.count < 1_000)
    }

    @Test func theSearchFieldsAreDerivedFromTheName() {
        let symbol = OPNCollectionSymbol(name: "Arrow.Forward.Circle.Fill", category: "arrows", keywords: [])
        #expect(symbol.searchName == "arrow.forward.circle.fill")
        #expect(symbol.searchTokens == ["arrow", "forward", "circle", "fill"])
    }

    @Test func anExactTokenOutranksAPrefixWhichOutranksASubstring() {
        assertInlineCatalogIsLoaded()
        // "star" is a whole token of "star.fill" (token weight) and only a prefix of the "stars"
        // token in the two other matches (token-prefix weight), so the head of the list is the token rule.
        #expect(OPNCollectionSymbolCatalog.search("star", categoryID: allCategoryID).map(\.name)
                == ["star.fill", "moon.stars.fill", "wand.and.stars"])

        // "game" is only a prefix of the "gamecontroller" token (token-prefix weight).
        #expect(OPNCollectionSymbolCatalog.search("game", categoryID: allCategoryID).map(\.name)
                == ["gamecontroller.fill"])

        // "ontroll" appears inside the name but in no token (name-substring weight).
        #expect(OPNCollectionSymbolCatalog.search("ontroll", categoryID: allCategoryID).map(\.name)
                == ["gamecontroller.fill"])
    }

    @Test func everyTermHasToMatchForASymbolToRank() {
        assertInlineCatalogIsLoaded()
        #expect(OPNCollectionSymbolCatalog.search("star fill", categoryID: allCategoryID).map(\.name)
                == ["star.fill", "moon.stars.fill"])
        // "star" matches and "zzz" does not, so the symbol is rejected.
        #expect(OPNCollectionSymbolCatalog.search("star zzz", categoryID: allCategoryID).isEmpty)
    }

    @Test func aCategoryOnlyMatchStillRanks() {
        assertInlineCatalogIsLoaded()
        #expect(OPNCollectionSymbolCatalog.search("gaming", categoryID: allCategoryID).map(\.name)
                == ["arcade.stick", "chess.piece.knight.fill", "dice.fill", "gamecontroller.fill"])
    }

    @Test func searchIsCaseInsensitive() {
        assertInlineCatalogIsLoaded()
        #expect(OPNCollectionSymbolCatalog.search("STAR", categoryID: allCategoryID).map(\.name)
                == OPNCollectionSymbolCatalog.search("star", categoryID: allCategoryID).map(\.name))
    }

    @Test func anEmptyQueryReturnsTheCategoryUnchanged() {
        assertInlineCatalogIsLoaded()
        #expect(OPNCollectionSymbolCatalog.search("", categoryID: "gaming").map(\.name)
                == OPNCollectionSymbolCatalog.symbols(in: "gaming").map(\.name))
        #expect(OPNCollectionSymbolCatalog.search("   ", categoryID: "gaming").map(\.name)
                == OPNCollectionSymbolCatalog.symbols(in: "gaming").map(\.name))
    }

    @Test func tiesAreBrokenByNameSoTheOrderIsStable() {
        assertInlineCatalogIsLoaded()
        let results = OPNCollectionSymbolCatalog.search("fill", categoryID: "gaming").map(\.name)
        #expect(results == ["chess.piece.knight.fill", "dice.fill", "gamecontroller.fill"])
        #expect(results == results.sorted())
    }
}
