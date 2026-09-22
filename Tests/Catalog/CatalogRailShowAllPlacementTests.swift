import CoreGraphics
import Testing
@testable import OpenNOW

private func landscapeContentWidth(itemCount: Int) -> CGFloat {
    let slot = CatalogVendorLayout.wideTileWidth(scale: 1, density: 1) + CatalogVendorLayout.tileHorizontalMargin(scale: 1) * 2
    return CatalogVendorLayout.carouselContainerMargin(scale: 1) * 2 + CGFloat(itemCount) * slot
}

private func posterContentWidth(itemCount: Int) -> CGFloat {
    let slot = CatalogPosterLayout.slotWidth(scale: 1, density: 1)
    return CatalogVendorLayout.carouselContainerMargin(scale: 1) * 2 + CGFloat(itemCount) * slot
}

@Test func headerLinkHidesWhileTheEndOfRowShowAllTileIsVisible() {
    // A short landscape rail: every tile including the end-of-row Show All fits, so the header link
    // would be a second route to the action already on screen.
    let content = landscapeContentWidth(itemCount: 3)
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: content, contentWidth: content) == false)
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: content + 600, contentWidth: content) == false)
}

@Test func headerLinkAppearsOnceTheRowOverflowsTheViewport() {
    let landscape = landscapeContentWidth(itemCount: 18)
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: landscape - 1, contentWidth: landscape))
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: landscape - 800, contentWidth: landscape))

    let poster = posterContentWidth(itemCount: 18)
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: poster - 1, contentWidth: poster))
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: poster - 800, contentWidth: poster))
}

@Test func headerLinkStaysVisibleUntilTheWidthIsMeasured() {
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: 0, contentWidth: 1000))
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: -1, contentWidth: 1000))
}

@Test func headerLinkIgnoresSubPointRoundingAtTheBreakEven() {
    let content: CGFloat = 1600
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: content, contentWidth: content) == false)
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: content + 0.4, contentWidth: content) == false)
    #expect(CatalogRailShowAllPlacement.showsHeaderLink(availableWidth: content - 2, contentWidth: content))
}
