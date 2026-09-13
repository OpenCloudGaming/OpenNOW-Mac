import CoreGraphics
import Testing
@testable import OpenNOW

private let allDensities = OpenNOWThemePreferences.TileDensity.allCases.map(\.tileScale)

@Test func compactTileIsSmallerThanComfortableAndLargeIsBiggerAtEveryInterfaceScale() {
    for scale: CGFloat in [0.75, 1.0, 1.25, 1.5, 2.0] {
        let compactWideWidth = CatalogVendorLayout.wideTileWidth(scale: scale, density: OpenNOWThemePreferences.TileDensity.compact.tileScale)
        let comfortableWideWidth = CatalogVendorLayout.wideTileWidth(scale: scale, density: OpenNOWThemePreferences.TileDensity.comfortable.tileScale)
        let largeWideWidth = CatalogVendorLayout.wideTileWidth(scale: scale, density: OpenNOWThemePreferences.TileDensity.large.tileScale)
        #expect(compactWideWidth < comfortableWideWidth)
        #expect(largeWideWidth > comfortableWideWidth)

        let compactWideHeight = CatalogVendorLayout.wideTileHeight(scale: scale, density: OpenNOWThemePreferences.TileDensity.compact.tileScale)
        let comfortableWideHeight = CatalogVendorLayout.wideTileHeight(scale: scale, density: OpenNOWThemePreferences.TileDensity.comfortable.tileScale)
        let largeWideHeight = CatalogVendorLayout.wideTileHeight(scale: scale, density: OpenNOWThemePreferences.TileDensity.large.tileScale)
        #expect(compactWideHeight < comfortableWideHeight)
        #expect(largeWideHeight > comfortableWideHeight)

        let compactPosterWidth = CatalogPosterLayout.posterTileWidth(scale: scale, density: OpenNOWThemePreferences.TileDensity.compact.tileScale)
        let comfortablePosterWidth = CatalogPosterLayout.posterTileWidth(scale: scale, density: OpenNOWThemePreferences.TileDensity.comfortable.tileScale)
        let largePosterWidth = CatalogPosterLayout.posterTileWidth(scale: scale, density: OpenNOWThemePreferences.TileDensity.large.tileScale)
        #expect(compactPosterWidth < comfortablePosterWidth)
        #expect(largePosterWidth > comfortablePosterWidth)
    }
}

@Test func aPosterTileStaysTwoByThreeAtEveryDensity() {
    for density in allDensities {
        let width = CatalogPosterLayout.posterTileWidth(scale: 1.0, density: density)
        let height = CatalogPosterLayout.posterTileHeight(scale: 1.0, density: density)
        #expect(abs(height - width * 1.5) < 0.5)
    }
}

@Test func rowHeightStillEqualsTileHeightPlusBothMarginsAtEveryDensity() {
    for density in allDensities {
        let vendorRowHeight = CatalogVendorLayout.tileRowHeight(scale: 1, density: density)
        let vendorTileHeight = CatalogVendorLayout.wideTileHeight(scale: 1, density: density)
        let vendorTopMargin = CatalogVendorLayout.tileTopMargin(scale: 1)
        let vendorBottomMargin = CatalogVendorLayout.tileBottomMargin(scale: 1)
        #expect(vendorRowHeight == vendorTileHeight + vendorTopMargin + vendorBottomMargin)

        let posterRowHeight = CatalogPosterLayout.tileRowHeight(scale: 1, density: density)
        let posterTileHeight = CatalogPosterLayout.posterTileHeight(scale: 1, density: density)
        let posterTopMargin = CatalogPosterLayout.tileTopMargin(scale: 1)
        let posterBottomMargin = CatalogPosterLayout.tileBottomMargin(scale: 1)
        #expect(posterRowHeight == posterTileHeight + posterTopMargin + posterBottomMargin)
    }
}

@Test func aDenserSettingYieldsAtLeastAsManyColumnsAtTheSameWindowWidth() {
    for width: CGFloat in [900, 1440, 2560, 5120] {
        for scale: CGFloat in [1.0, 1.5] {
            let compactColumns = CatalogPosterLayout.columnCount(forWidth: width, scale: scale, density: OpenNOWThemePreferences.TileDensity.compact.tileScale)
            let comfortableColumns = CatalogPosterLayout.columnCount(forWidth: width, scale: scale, density: OpenNOWThemePreferences.TileDensity.comfortable.tileScale)
            let largeColumns = CatalogPosterLayout.columnCount(forWidth: width, scale: scale, density: OpenNOWThemePreferences.TileDensity.large.tileScale)
            #expect(compactColumns >= comfortableColumns)
            #expect(comfortableColumns >= largeColumns)
        }
    }
}

@Test func aComfortableDensityMatchesTheUndecoratedLayoutDefaults() {
    // density defaults to 1.0 so every existing call site (and test) that never passed one keeps
    // compiling and keeps its old size - comfortable is the preference's neutral point.
    let comfortableScale = OpenNOWThemePreferences.TileDensity.comfortable.tileScale
    #expect(comfortableScale == 1.0)
    #expect(CatalogVendorLayout.wideTileWidth(scale: 1.0) == CatalogVendorLayout.wideTileWidth(scale: 1.0, density: comfortableScale))
    #expect(CatalogPosterLayout.posterTileWidth(scale: 1.0) == CatalogPosterLayout.posterTileWidth(scale: 1.0, density: comfortableScale))
}
