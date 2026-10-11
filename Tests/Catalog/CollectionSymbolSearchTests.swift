import Foundation
import Testing
@testable import OpenNOW

/// Pins the collection icon picker's search ranking.
///
/// `matchScore` used to lowercase and split the symbol name on every symbol on every keystroke;
/// those two values are now derived once per symbol when the catalog loads. These tests hold the
/// scoring semantics still so that change stays a pure move of work, and so the branches of the
/// scoring are covered rather than only the end-to-end ordering.
@Suite struct CollectionSymbolSearchTests {
    private let all = OPNCollectionSymbolCatalog.allCategoryID

    /// The picker's catalog loads from the app bundle, which the SwiftPM test runner does not carry,
    /// so the assertions below run against the inline fallback set. Asserted rather than assumed: if
    /// the resource is ever added to the SwiftPM target, this fails with a clear reason instead of a
    /// confusing name mismatch further down.
    private func requireInlineCatalog() {
        #expect(OPNCollectionSymbolCatalog.symbols.count < 1_000)
    }

    @Test func theNormalisedNameAndTokensAreDerivedFromTheName() {
        let symbol = OPNCollectionSymbol(name: "Arrow.Forward.Circle.Fill", category: "arrows", keywords: [])
        #expect(symbol.searchName == "arrow.forward.circle.fill")
        #expect(symbol.searchTokens == ["arrow", "forward", "circle", "fill"])
    }

    @Test func anExactTokenOutranksAPrefixWhichOutranksASubstring() {
        requireInlineCatalog()
        // "star" is a whole token of "star.fill" (+100) and only a prefix of the "stars" token in
        // the two other matches (+60), so the head of the list is the token rule and nothing else.
        #expect(OPNCollectionSymbolCatalog.search("star", categoryID: all).map(\.name)
                == ["star.fill", "moon.stars.fill", "wand.and.stars"])

        // "game" is only a prefix of the "gamecontroller" token (+60).
        #expect(OPNCollectionSymbolCatalog.search("game", categoryID: all).map(\.name) == ["gamecontroller.fill"])

        // "ontroll" appears inside the name but in no token (+30).
        #expect(OPNCollectionSymbolCatalog.search("ontroll", categoryID: all).map(\.name) == ["gamecontroller.fill"])
    }

    @Test func everyTermHasToMatchForASymbolToRank() {
        requireInlineCatalog()
        #expect(OPNCollectionSymbolCatalog.search("star fill", categoryID: all).map(\.name)
                == ["star.fill", "moon.stars.fill"])
        // "star" matches, "zzz" does not, and a symbol has to satisfy all of them.
        #expect(OPNCollectionSymbolCatalog.search("star zzz", categoryID: all).isEmpty)
    }

    @Test func theCategoryIsTheWeakestMatchAndStillRanks() {
        requireInlineCatalog()
        #expect(OPNCollectionSymbolCatalog.search("gaming", categoryID: all).map(\.name)
                == ["arcade.stick", "chess.piece.knight.fill", "dice.fill", "gamecontroller.fill"])
    }

    @Test func searchIsCaseInsensitiveOnBothSidesOfTheComparison() {
        requireInlineCatalog()
        #expect(OPNCollectionSymbolCatalog.search("STAR", categoryID: all).map(\.name)
                == OPNCollectionSymbolCatalog.search("star", categoryID: all).map(\.name))
    }

    @Test func anEmptyQueryReturnsTheCategoryUnchanged() {
        requireInlineCatalog()
        #expect(OPNCollectionSymbolCatalog.search("", categoryID: "gaming").map(\.name)
                == OPNCollectionSymbolCatalog.symbols(in: "gaming").map(\.name))
        #expect(OPNCollectionSymbolCatalog.search("   ", categoryID: "gaming").map(\.name)
                == OPNCollectionSymbolCatalog.symbols(in: "gaming").map(\.name))
    }

    @Test func tiesAreBrokenByNameSoTheOrderIsStable() {
        requireInlineCatalog()
        let results = OPNCollectionSymbolCatalog.search("fill", categoryID: "gaming").map(\.name)
        #expect(results == ["chess.piece.knight.fill", "dice.fill", "gamecontroller.fill"])
        #expect(results == results.sorted())
    }
}
