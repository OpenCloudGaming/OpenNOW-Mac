import CoreGraphics
import Testing
@testable import OpenNOW

private let landscapeRatio: CGFloat = 9.0 / 16.0
private let posterRatio: CGFloat = 1 / CatalogPosterLayout.aspectRatio

@Test func showAllTilesKeepTheShapeTheChosenHomeLayoutAsksFor() {
    let landscape = CatalogShowAllLayout.itemMetrics(forWidth: 1600, minTileWidth: 352, spacing: 16, tileHeightRatio: landscapeRatio)
    #expect(abs(landscape.itemSize.height - landscape.itemSize.width * 9 / 16) <= 1)

    let poster = CatalogShowAllLayout.itemMetrics(forWidth: 1600, minTileWidth: 208, spacing: 16, tileHeightRatio: posterRatio)
    #expect(abs(poster.itemSize.height - poster.itemSize.width * 1.5) <= 1)
    #expect(poster.itemSize.height > poster.itemSize.width)
}

@Test func narrowerPosterTilesFitMoreColumnsThanLandscapeOnes() {
    for width in [900.0, 1440.0, 2560.0, 5120.0] as [CGFloat] {
        let landscape = CatalogShowAllLayout.itemMetrics(forWidth: width, minTileWidth: 352, spacing: 16, tileHeightRatio: landscapeRatio)
        let poster = CatalogShowAllLayout.itemMetrics(forWidth: width, minTileWidth: 208, spacing: 16, tileHeightRatio: posterRatio)
        #expect(poster.columns > landscape.columns, "poster fits no more columns than landscape at \(width)pt")
    }
}

@Test func aGridNeverReportsFewerThanTwoColumnsOrANegativeTile() {
    for width in [0.0, 120.0, 320.0] as [CGFloat] {
        let metrics = CatalogShowAllLayout.itemMetrics(forWidth: width, minTileWidth: 208, spacing: 16, tileHeightRatio: posterRatio)
        #expect(metrics.columns >= 2)
        #expect(metrics.itemSize.width > 0)
        #expect(metrics.itemSize.height > 0)
    }
}

@Test func aDenserTileDensityYieldsAtLeastAsManyShowAllColumns() {
    // The grid never reads the density enum itself - the representable folds it into the
    // `minTileWidth` it hands the layout, so a smaller compact tile is what this exercises.
    let compactMinWidth = CatalogPosterLayout.posterTileWidth(scale: 1.0, density: 0.82)
    let comfortableMinWidth = CatalogPosterLayout.posterTileWidth(scale: 1.0, density: 1.0)
    let largeMinWidth = CatalogPosterLayout.posterTileWidth(scale: 1.0, density: 1.22)

    for width in [900.0, 1440.0, 2560.0, 5120.0] as [CGFloat] {
        let compact = CatalogShowAllLayout.itemMetrics(forWidth: width, minTileWidth: compactMinWidth, spacing: 16, tileHeightRatio: posterRatio)
        let comfortable = CatalogShowAllLayout.itemMetrics(forWidth: width, minTileWidth: comfortableMinWidth, spacing: 16, tileHeightRatio: posterRatio)
        let large = CatalogShowAllLayout.itemMetrics(forWidth: width, minTileWidth: largeMinWidth, spacing: 16, tileHeightRatio: posterRatio)
        #expect(compact.columns >= comfortable.columns)
        #expect(comfortable.columns >= large.columns)
    }
}

@Test func theInsetsLeaveRoomForEveryPointAHoveredTileGrowsBy() {
    let metrics = CatalogShowAllLayout.itemMetrics(forWidth: 1600, minTileWidth: 208, spacing: 16, tileHeightRatio: posterRatio)
    let growth = CatalogShowAllLayout.tileScaleFactor - 1
    #expect(metrics.horizontalInset >= metrics.itemSize.width * growth / 2)
    #expect(metrics.verticalInset >= metrics.itemSize.height * growth / 2)
}
