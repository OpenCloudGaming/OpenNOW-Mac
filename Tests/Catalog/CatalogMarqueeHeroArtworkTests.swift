import Foundation
import Testing
@testable import OpenNOW

/// The marquee hero is the one image whose CDN width and decode rung have to be the same number:
/// `CatalogImageLoadKey` carries `maxPixelSize`, so a decode at any other rung is a different load
/// and a memory-cache miss for the entry the launch prefetch warmed - the largest artwork on the
/// home screen is then fetched and decoded a second time during launch. The view used to inherit the
/// cache's 3840 default while both prefetches warmed 1920.
struct CatalogMarqueeHeroArtworkTests {
    @Test func theHeroDecodeRungIsTheWidthItsURLIsRequestedAt() {
        #expect(CatalogMarqueeHeroArtwork.decodeRung == CGFloat(CatalogMarqueeHeroArtwork.requestWidth))
    }

    @Test func theHeroRungIsNotTheFourThousandDefaultItUsedToInherit() {
        #expect(CatalogMarqueeHeroArtwork.requestWidth == 1920)
        #expect(CatalogMarqueeHeroArtwork.decodeRung == 1920)
    }
}
