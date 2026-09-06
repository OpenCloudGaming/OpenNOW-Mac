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
