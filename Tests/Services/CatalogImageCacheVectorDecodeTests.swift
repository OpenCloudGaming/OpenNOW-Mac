import AppKit
import Foundation
import Testing
@testable import OpenNOW

struct CatalogImageCacheVectorDecodeTests {
    private let storeIconSVG = Data("""
    <svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
    <rect width="24" height="24" fill="#107C10"/>
    </svg>
    """.utf8)

    @Test func svgDecodesThroughVectorFallbackWithRetinaHeadroom() {
        let decoded = CatalogImageCache.downsampledImage(from: storeIconSVG, maxPixelSize: 3840)
        #expect(decoded?.image.size == NSSize(width: 192, height: 192))
        #expect(decoded?.decodedByteCount ?? 0 > 0)
    }

    @Test func svgDecodeRespectsMaxPixelSize() {
        let decoded = CatalogImageCache.downsampledImage(from: storeIconSVG, maxPixelSize: 48)
        #expect(decoded?.image.size == NSSize(width: 48, height: 48))
    }

    /// The rating badge's rung, at 58 x 76pt on a 2x screen. The vector path scales its bitmap up to
    /// the rung, so this is the number that decides whether the mark reads sharp or blurred.
    @Test func theRatingBadgeRungRasterisesTheSvgAtItsDrawnDevicePixels() {
        let rung = CatalogArtworkResolution.decodeRung(forPointSize: 76, displayScale: 2)
        let decoded = CatalogImageCache.downsampledImage(from: storeIconSVG, maxPixelSize: rung)
        #expect(rung == 152)
        #expect(decoded?.image.size == NSSize(width: 152, height: 152))
    }

    /// A content-rating mark is a portrait SVG around 80 x 161. The old shared default let the vector
    /// path scale it to the 8x ceiling - a ~3.3MB raster for a 58 x 76pt badge - where the badge's own
    /// rung rasterises it at the height it is drawn at. The decode is the whole memory cost here, so
    /// the two numbers are the change.
    @Test func theBadgeRungReplacesTheEightTimesUpscaleOfTheBannerDefault() throws {
        let ratingMarkSVG = Data("""
        <svg width="80" height="161" viewBox="0 0 80 161" xmlns="http://www.w3.org/2000/svg">
        <rect width="80" height="161" fill="#000000"/>
        </svg>
        """.utf8)

        let banner = try #require(CatalogImageCache.downsampledImage(from: ratingMarkSVG, maxPixelSize: 1920 * 2))
        let badgeRung = CatalogArtworkResolution.decodeRung(forPointSize: 76, displayScale: 2)
        let badge = try #require(CatalogImageCache.downsampledImage(from: ratingMarkSVG, maxPixelSize: badgeRung))

        #expect(banner.image.size == NSSize(width: 640, height: 1288))
        #expect(badge.image.size == NSSize(width: 76, height: 152))
        #expect(banner.decodedByteCount > badge.decodedByteCount * 50)
    }

    @Test func rasterDataStillDecodesViaImageIOWithoutUpscaling() throws {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 40,
            pixelsHigh: 20,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
        let decoded = CatalogImageCache.downsampledImage(from: pngData, maxPixelSize: 3840)
        #expect(decoded?.image.size == NSSize(width: 40, height: 20))
    }
}
