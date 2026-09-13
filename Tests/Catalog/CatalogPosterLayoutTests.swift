import CoreGraphics
import Testing
@testable import OpenNOW

@Test func aPosterTileIsTwoByThreeAtEveryInterfaceScale() {
    for scale: CGFloat in [0.75, 1.0, 1.25, 1.5, 2.0] {
        let width = CatalogPosterLayout.posterTileWidth(scale: scale)
        let height = CatalogPosterLayout.posterTileHeight(scale: scale)
        #expect(abs(height - width * 1.5) < 0.5)
    }

    let widthAtOne = CatalogPosterLayout.posterTileWidth(scale: 1.0)
    let widthAtOneAndHalf = CatalogPosterLayout.posterTileWidth(scale: 1.5)
    #expect(widthAtOneAndHalf == widthAtOne * 1.5)
}

@Test func aPosterRowReservesBothMarginsSoAHoveredTileDoesNotCloseTheGapBelow() {
    let rowHeight = CatalogPosterLayout.tileRowHeight(scale: 1)
    let tileHeight = CatalogPosterLayout.posterTileHeight(scale: 1)
    let topMargin = CatalogPosterLayout.tileTopMargin(scale: 1)
    let bottomMargin = CatalogPosterLayout.tileBottomMargin(scale: 1)

    #expect(rowHeight == tileHeight + topMargin + bottomMargin)
    #expect(topMargin == bottomMargin)
}

@Test func hoverGrowthStopsShortOfTheNeighbouringPoster() {
    // A LazyHStack paints children in index order and ignores zIndex, so growth past the slot
    // boundary would visually overlap the next poster with no way to reorder around it.
    let slotWidth = CatalogPosterLayout.slotWidth(scale: 1)
    let tileWidth = CatalogPosterLayout.posterTileWidth(scale: 1)
    #expect(CatalogPosterLayout.tileScaleFactor <= slotWidth / tileWidth)
}

@Test func aPosterTileKeepsItsShapeAcrossEveryTileDensity() {
    for density: CGFloat in [0.82, 1.0, 1.22] {
        let width = CatalogPosterLayout.posterTileWidth(scale: 1.0, density: density)
        let height = CatalogPosterLayout.posterTileHeight(scale: 1.0, density: density)
        #expect(abs(height - width * 1.5) < 0.5)
    }
}

@Test func aDenserPosterRowStillReservesBothMarginsUnscaled() {
    for density: CGFloat in [0.82, 1.0, 1.22] {
        let rowHeight = CatalogPosterLayout.tileRowHeight(scale: 1, density: density)
        let tileHeight = CatalogPosterLayout.posterTileHeight(scale: 1, density: density)
        let topMargin = CatalogPosterLayout.tileTopMargin(scale: 1)
        let bottomMargin = CatalogPosterLayout.tileBottomMargin(scale: 1)
        #expect(rowHeight == tileHeight + topMargin + bottomMargin)
    }
}

@Test func aRailNeverReportsFewerThanOneColumnAndNeverShrinksAsTheWindowGrows() {
    #expect(CatalogPosterLayout.columnCount(forWidth: 0, scale: 1.0) == 1)
    #expect(CatalogPosterLayout.columnCount(forWidth: 320, scale: 1.0) >= 1)

    let widths: [CGFloat] = [600, 900, 1440, 2560, 5120]
    for scale: CGFloat in [1.0, 1.5] {
        var previousCount = 0
        for width in widths {
            let count = CatalogPosterLayout.columnCount(forWidth: width, scale: scale)
            #expect(count >= previousCount)
            previousCount = count
        }
    }

    #expect(
        CatalogPosterLayout.columnCount(forWidth: 2560, scale: 1.5)
            <= CatalogPosterLayout.columnCount(forWidth: 2560, scale: 1.0)
    )
}
