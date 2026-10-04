import Foundation
import Testing
@testable import OpenNOW

/// The rung is the whole cost for the SVG surfaces - the rating badge and the store icons - because
/// the vector path rasterises up to it. These pin the two properties that make a rung correct: one
/// source pixel per device pixel, and a rung that moves with Interface Scale.
struct CatalogArtworkRungTests {
    @Test func aRungCarriesOneSourcePixelPerDevicePixel() {
        #expect(CatalogArtworkResolution.decodeRung(forPointSize: 76, displayScale: 1) == 76)
        #expect(CatalogArtworkResolution.decodeRung(forPointSize: 76, displayScale: 2) == 152)
    }

    @Test func aRungMovesWithInterfaceScale() {
        let base = CatalogArtworkResolution.decodeRung(forPointSize: 76, displayScale: 2)
        let scaled = CatalogArtworkResolution.decodeRung(forPointSize: 76 * 1.5, displayScale: 2)
        #expect(base == 152)
        #expect(scaled == 228)
    }

    @Test func aRungNeverCollapsesBelowOnePixel() {
        #expect(CatalogArtworkResolution.decodeRung(forPointSize: 0, displayScale: 2) == 1)
    }

    /// The store picker draws a store icon at 14-20pt and Settings draws the same icon at 42pt. They
    /// share a URL, and the memory cache is keyed by URL rather than by rung, so the picker asks for
    /// Settings' rung: a smaller one would let whichever decoded first decide for both.
    @Test func everySurfaceDrawingAStoreIconAsksForTheLargestSurfacesRung() {
        #expect(CatalogStoreIconArtwork.decodeRung(scale: 1, displayScale: 2) == 84)
        #expect(CatalogStoreIconArtwork.decodeRung(scale: 1.5, displayScale: 2) == 126)
    }

    /// The marquee hero is the one asset whose CDN width and decode rung are both baked into a load
    /// key that carries the rung: the launch prefetch and the rotation prewarm warm one entry, and a
    /// view reading at any other rung misses it and decodes the largest artwork on the home screen
    /// again. The view used to take the shared 3840 default while both warmers decoded 1920.
    @Test func theMarqueeHeroDecodeRungIsTheWidthItsURLIsRequestedAt() {
        #expect(CatalogMarqueeArtwork.decodePixelSize == CGFloat(CatalogMarqueeArtwork.requestWidth))
        #expect(CatalogMarqueeArtwork.decodePixelSize == 1920)
    }
}
