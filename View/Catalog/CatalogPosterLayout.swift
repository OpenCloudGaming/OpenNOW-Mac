import CoreGraphics

enum CatalogPosterLayout {
    static let aspectRatio: CGFloat = 2.0 / 3.0
    /// Hover growth stops just short of the neighbouring tile: a 208pt tile in a 224pt slot means
    /// anything past 224/208 = 1.077 crosses into the tile beside it, which a `LazyHStack` cannot reorder.
    static let tileScaleFactor: CGFloat = 1.06

    private static let basePosterTileWidth: CGFloat = 208
    private static let baseTileHorizontalMargin: CGFloat = 8
    private static let baseTileTopMargin: CGFloat = 12
    private static let baseTrayHeight: CGFloat = 36

    /// `density` scales the tile alone (Tile Density preference); margins stay Interface Scale's
    /// territory, so the poster keeps its 2:3 shape and the row height still equals tile height
    /// plus both margins at any density.
    static func posterTileWidth(scale: CGFloat, density: CGFloat = 1.0) -> CGFloat { basePosterTileWidth * scale * density }
    static func posterTileHeight(scale: CGFloat, density: CGFloat = 1.0) -> CGFloat { posterTileWidth(scale: scale, density: density) / aspectRatio }
    static func tileHorizontalMargin(scale: CGFloat) -> CGFloat { baseTileHorizontalMargin * scale }
    static func tileTopMargin(scale: CGFloat) -> CGFloat { baseTileTopMargin * scale }
    /// Matches the top margin so a hovered tile's growth is symmetric, same reason as
    /// `CatalogVendorLayout.tileBottomMargin`.
    static func tileBottomMargin(scale: CGFloat) -> CGFloat { baseTileTopMargin * scale }
    static func trayHeight(scale: CGFloat) -> CGFloat { baseTrayHeight * scale }

    static func slotWidth(scale: CGFloat, density: CGFloat = 1.0) -> CGFloat {
        posterTileWidth(scale: scale, density: density) + 2 * tileHorizontalMargin(scale: scale)
    }

    /// Height one tile claims in a rail, both margins included.
    static func tileRowHeight(scale: CGFloat, density: CGFloat = 1.0) -> CGFloat {
        posterTileHeight(scale: scale, density: density) + tileTopMargin(scale: scale) + tileBottomMargin(scale: scale)
    }

    static func columnCount(forWidth width: CGFloat, scale: CGFloat, density: CGFloat = 1.0) -> Int {
        guard width > 0 else { return 1 }
        let usableWidth = width - 2 * CatalogVendorLayout.carouselContainerMargin(scale: scale)
        return max(1, Int(usableWidth / slotWidth(scale: scale, density: density)))
    }
}
