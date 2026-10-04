//  The running-stream banner's width: the page clamps its scroll view to the page, because the
//  banner's `safeAreaInset` region is that frame and a `ScrollView` is as wide as its content.

import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

@MainActor
@Suite struct CatalogRunningStreamBannerLayoutTests {
    private static let pageSize = CGSize(width: 900, height: 620)
    /// The banner is pinned to the top of the page, so row 4 is banner and the bottom row is bare page.
    private static let bannerSampleRow = 4
    private static let pageSampleRowFromBottom = 20
    /// ImageRenderer rasterizes in its own colour space, so rendered pixels are compared to each other.
    private static let channelTolerance = 0.01

    @Test func theBannerReachesBothEdgesOfThePageWhileARailRunsPastIt() throws {
        let bitmap = try renderRunningStreamPage()
        let leadingEdge = try renderedColor(in: bitmap, x: 0, y: Self.bannerSampleRow)
        let trailingEdge = try renderedColor(in: bitmap, x: bitmap.pixelsWide - 1, y: Self.bannerSampleRow)
        let pageBackground = try renderedColor(in: bitmap, x: 0, y: bitmap.pixelsHigh - Self.pageSampleRowFromBottom)

        // Both ends of the top band are the banner's chrome ...
        #expect(
            isSameColor(leadingEdge, trailingEdge),
            "the top band is two colours: \(rgbTriplet(of: leadingEdge)) leading, \(rgbTriplet(of: trailingEdge)) trailing"
        )
        // ... and it is the banner, not the page showing through where the banner should be.
        #expect(
            !isSameColor(leadingEdge, pageBackground),
            "the banner is missing from the leading edge of the page"
        )
    }

    /// ImageRenderer draws the inset even though it skips `ScrollView` content, and the layout that
    /// places that inset still runs against the content's width - which is the behaviour under test.
    private func renderRunningStreamPage() throws -> NSBitmapImageRep {
        let page = CatalogContentView(viewModel: try makeRunningStreamViewModel(), isActive: true)
            .frame(width: Self.pageSize.width, height: Self.pageSize.height)
        let renderer = ImageRenderer(content: page)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the page did not render")
        return NSBitmapImageRep(cgImage: image)
    }

    /// A running stream over a page whose only rail is still loading: a plain row of six fixed-width
    /// tiles, which is what makes the scroll content wider than the page.
    private func makeRunningStreamViewModel() throws -> CatalogViewModel {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        // Its own registry: the running stream is owned by the application now, and a shared one
        // would leak this session into every other test in the process.
        let viewModel = makeCatalogViewModelForTesting(
            sessionRegistry: OPNGameSessionRegistry(),
            sessionResultStore: OPNGameSessionResultStore()
        )
        viewModel.cachedCatalogSections = [
            CatalogSectionModel(id: "loading", title: "Loading", games: [], kind: .catalog, isPlaceholder: true)
        ]
        let session = try #require(makeOwnedGameSessionForTesting(viewModel))
        session.configuration = StreamLaunchConfiguration(
            title: "The Witcher 3: Wild Hunt - Remastered",
            applicationID: "app-1",
            accessToken: "token",
            accountLinked: true,
            selectedStore: "STEAM"
        )
        return viewModel
    }

    private func renderedColor(in bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), "no pixel at \(x),\(y)")
    }

    private func isSameColor(_ first: NSColor, _ second: NSColor) -> Bool {
        abs(first.redComponent - second.redComponent) < Self.channelTolerance
            && abs(first.greenComponent - second.greenComponent) < Self.channelTolerance
            && abs(first.blueComponent - second.blueComponent) < Self.channelTolerance
    }

    private func rgbTriplet(of color: NSColor) -> String {
        "(\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255)))"
    }
}
