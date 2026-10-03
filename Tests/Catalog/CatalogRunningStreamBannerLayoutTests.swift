//  The running-stream banner's width, which is a page-geometry question rather than a banner one.
//
//  The banner is a top `safeAreaInset` on the catalog page's scroll view, and that region is the
//  scroll view's *frame*. A `ScrollView` is as wide as its widest content - a rail still on its
//  skeleton is a plain row of fixed-width tiles, so the content runs past the window - and the
//  banner was therefore laid out centred on that inflated width, which put only its right-hand end
//  on screen. The page clamps the scroll view to the page width; this is what says so.

import AppKit
import SwiftUI
import Testing
@testable import OpenNOW

@MainActor
@Suite struct CatalogRunningStreamBannerLayoutTests {
    private static let pageSize = CGSize(width: 900, height: 620)

    @Test func theBannerReachesBothEdgesOfThePageWhileARailRunsPastIt() throws {
        let bitmap = try renderRunningStreamPage()
        let leadingEdge = try pixel(bitmap, x: 0, y: 4)
        let trailingEdge = try pixel(bitmap, x: bitmap.pixelsWide - 1, y: 4)
        let pageBackground = try pixel(bitmap, x: 0, y: bitmap.pixelsHigh - 20)

        // Both ends of the top band are the banner's chrome ...
        #expect(
            sameColor(leadingEdge, trailingEdge),
            "the top band is two colours: \(description(leadingEdge)) at the leading edge, \(description(trailingEdge)) at the trailing one"
        )
        // ... and it is the banner, not the page showing through where the banner should be.
        #expect(
            !sameColor(leadingEdge, pageBackground),
            "the banner is missing from the leading edge of the page"
        )
    }

    /// The banner is the only thing pinned to the top of the page, and ImageRenderer is enough to
    /// rasterize it: the inset is drawn even though `ScrollView` content is not, and the layout that
    /// places it still runs against the content's width - which is the whole point.
    private func renderRunningStreamPage() throws -> NSBitmapImageRep {
        OPNDesign.applyTheme(accent: .cloudGreen, appearance: .dark, systemColorScheme: .dark)
        let viewModel = makeCatalogViewModelForTesting()
        // One rail, still loading: a plain row of six fixed-width tiles, which is what makes the
        // scroll content wider than the page.
        viewModel.cachedCatalogSections = [
            CatalogSectionModel(id: "loading", title: "Loading", games: [], kind: .catalog, isPlaceholder: true)
        ]
        viewModel.activeStreamConfiguration = StreamLaunchConfiguration(
            title: "The Witcher 3: Wild Hunt - Remastered",
            applicationID: "app-1",
            accessToken: "token",
            accountLinked: true,
            selectedStore: "STEAM"
        )

        let renderer = ImageRenderer(
            content: CatalogContentView(viewModel: viewModel, isActive: true)
                .frame(width: Self.pageSize.width, height: Self.pageSize.height)
        )
        renderer.scale = 1
        let image = try #require(renderer.cgImage, "the page did not render")
        return NSBitmapImageRep(cgImage: image)
    }

    private func pixel(_ bitmap: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
        try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), "no pixel at \(x),\(y)")
    }

    /// ImageRenderer rasterizes in its own colour space, so the palette's values do not come back
    /// unchanged; equality between two rendered pixels is what this test can rely on.
    private func sameColor(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        abs(lhs.redComponent - rhs.redComponent) < 0.01
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.01
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.01
    }

    private func description(_ color: NSColor) -> String {
        "(\(Int(color.redComponent * 255)),\(Int(color.greenComponent * 255)),\(Int(color.blueComponent * 255)))"
    }
}
