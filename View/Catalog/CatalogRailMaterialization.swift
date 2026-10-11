//  How many games a home rail materializes at once.
//
//  The home page is deliberately an eager `VStack` (see `CatalogContentView`), so every rail is
//  built on the first frame. Each rail handed its row a fixed `prefix(18)` of the section's games -
//  a number unrelated to the window it draws into. On the 2197pt-wide page the P0-2 baseline was
//  captured on, a wide rail shows six tiles, so eighteen was three screens the reader had to scroll
//  through tiles that were already built; on a 5120pt page the same eighteen is barely one screen.
//
//  The window is what a rail can display plus one screen of scroll-ahead, derived from the layout
//  constants the row draws with. It grows by one screen once the reader comes within half a screen
//  of its trailing edge, so the cap bounds the first frame without truncating the rail.
//

import CoreGraphics

enum CatalogRailMaterialization {
    /// Screens of scroll-ahead a rail materializes past the one it can display. One screen is what
    /// the row needs to keep its trailing edge filled while the reader scrolls toward it.
    static let scrollAheadScreens = 1

    /// One tile's slot in a rail: the tile plus the margins either side of it. `LazyHStack` spacing
    /// is zero, so this is the whole width one game claims.
    static func slotWidth(scale: CGFloat, density: CGFloat, isPoster: Bool) -> CGFloat {
        isPoster
            ? CatalogPosterLayout.slotWidth(scale: scale, density: density)
            : CatalogVendorLayout.wideTileWidth(scale: scale, density: density) + 2 * CatalogVendorLayout.tileHorizontalMargin(scale: scale)
    }

    /// The tiles a rail of `availableWidth` shows at once. Rounded up, so a partially visible tile
    /// counts: rounding down leaves a gap at the trailing edge that only the next tile could fill.
    static func tilesPerScreen(availableWidth: CGFloat, scale: CGFloat, density: CGFloat, isPoster: Bool) -> Int {
        let usableWidth = availableWidth - 2 * CatalogVendorLayout.carouselContainerMargin(scale: scale)
        let slot = slotWidth(scale: scale, density: density, isPoster: isPoster)
        guard usableWidth > 0, slot > 0 else { return 1 }
        return max(1, Int((usableWidth / slot).rounded(.up)))
    }

    /// The games a rail materializes before anything scrolls.
    static func initialEnd(gameCount: Int, tilesPerScreen: Int) -> Int {
        guard gameCount > 0 else { return 0 }
        return min(gameCount, max(tilesPerScreen, 1) * (1 + scrollAheadScreens))
    }

    /// The end of the materialized window: never before the initial window, never before a game the
    /// rail has to show (a selection the reader made, or the row's own arrow paging), and never past
    /// the rail.
    static func end(gameCount: Int, tilesPerScreen: Int, materialized: Int, required: Int) -> Int {
        let initial = initialEnd(gameCount: gameCount, tilesPerScreen: tilesPerScreen)
        return min(max(materialized, initial, required), gameCount)
    }

    /// One more screen, for a reader who has scrolled close to the window's trailing edge.
    static func grownEnd(gameCount: Int, tilesPerScreen: Int, current: Int) -> Int {
        let perScreen = max(tilesPerScreen, 1)
        let from = max(current, initialEnd(gameCount: gameCount, tilesPerScreen: perScreen))
        return min(from + perScreen, gameCount)
    }

    /// How close to the trailing edge the window grows. Half a screen: the screen that gets added
    /// lands while half a screen of travel is still left, so the growth is never visible, and the
    /// added screen puts the reader back outside the trigger instead of growing again immediately.
    static func trailingTriggerDistance(availableWidth: CGFloat, scale: CGFloat, density: CGFloat, isPoster: Bool) -> CGFloat {
        let perScreen = CGFloat(tilesPerScreen(availableWidth: availableWidth, scale: scale, density: density, isPoster: isPoster))
        return perScreen * slotWidth(scale: scale, density: density, isPoster: isPoster) / 2
    }

    /// The tiles every home rail materializes before the reader scrolls.
    static func firstFrameTileCount(gameCounts: [Int], availableWidth: CGFloat, scale: CGFloat, density: CGFloat, isPoster: Bool) -> Int {
        let perScreen = tilesPerScreen(availableWidth: availableWidth, scale: scale, density: density, isPoster: isPoster)
        return gameCounts.reduce(0) { $0 + initialEnd(gameCount: $1, tilesPerScreen: perScreen) }
    }

    /// Records the first-frame window for the rails on screen. Logged once per mount, when the
    /// page's width has settled: a bound nothing records is a bound nothing can hold anyone to.
    static func logFirstFrameWindow(sections: [CatalogSectionModel], availableWidth: CGFloat, scale: CGFloat, density: CGFloat, isPoster: Bool) {
        let perScreen = tilesPerScreen(availableWidth: availableWidth, scale: scale, density: density, isPoster: isPoster)
        let tiles = firstFrameTileCount(
            gameCounts: sections.map { min($0.games.count, CatalogSectionModel.maximumRailGameCount) },
            availableWidth: availableWidth,
            scale: scale,
            density: density,
            isPoster: isPoster
        )
        OPNLog.info(.catalog, "Home rails materialized firstFrameRails=\(sections.count) firstFrameTiles=\(tiles) tilesPerScreen=\(perScreen) width=\(Int(availableWidth))")
    }
}
