import AppKit
import Foundation
import Testing
@testable import OpenNOW

/// Four caches reached review with neither a `countLimit` nor a `totalCostLimit`, so each grew to
/// whatever the working set happened to be. These pin the ceiling each surface declares.
@MainActor
struct ImageCacheBudgetTests {
    /// 13 rows are visible at 1.0 uiScale and ~9 at 1.5; 40 is a generous stand-in for the live grid
    /// working set on both surfaces, lazy-stack overscan included.
    private static let visibleGridWorkingSet = 40

    /// A 360pt-long-edge 16:9 thumbnail - the smallest entry either library cache stores.
    private static let thumbnailBytes = 360 * 203 * 4

    private static var resourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/OPN", isDirectory: true)
    }

    private static func budgets() -> [(name: String, budget: ImageCacheBudget)] {
        [
            ("VendorResourceImage", VendorResourceImage.cacheBudget),
            ("ScreenshotImageLoader", ScreenshotImageLoader.cacheBudget),
            ("RecordingThumbnailLoader", RecordingThumbnailLoader.cacheBudget),
            ("CatalogHeroImageMetadata", CatalogHeroImageMetadata.cacheBudget)
        ]
    }

    @Test func everyImageCacheDeclaresBothLimits() {
        for entry in Self.budgets() {
            #expect(entry.budget.countLimit > 0, "\(entry.name) has no count limit")
            #expect(entry.budget.totalCostLimit > 0, "\(entry.name) has no cost limit")
        }
    }

    /// A declared budget only bounds anything if the cache it builds is configured from it.
    @Test func aBoundedCacheAppliesTheBudgetItWasBuiltFrom() {
        let budget = ImageCacheBudget(countLimit: 7, totalCostLimit: 4_096)
        let cache: NSCache<NSString, NSImage> = budget.makeCache()
        #expect(cache.countLimit == 7)
        #expect(cache.totalCostLimit == 4_096)
    }

    @Test func screenshotLibraryBudgetExceedsTheVisibleGridWorkingSet() {
        let budget = ScreenshotImageLoader.cacheBudget
        #expect(budget.countLimit >= Self.visibleGridWorkingSet)
        #expect(budget.totalCostLimit >= Self.visibleGridWorkingSet * Self.thumbnailBytes)
    }

    @Test func recordingLibraryBudgetExceedsTheVisibleGridWorkingSet() {
        let budget = RecordingThumbnailLoader.cacheBudget
        #expect(budget.countLimit >= Self.visibleGridWorkingSet)
        #expect(budget.totalCostLimit >= Self.visibleGridWorkingSet * Self.thumbnailBytes)
    }

    /// The login wall renders its brand assets synchronously on first frame, so a miss inside the
    /// budget is a decode on the main thread. The whole prewarm set has to fit.
    @Test func loginWallBudgetHoldsTheWholeBrandAssetSet() throws {
        let assets = [
            ("logo", "png"),
            ("login-wall-background", "png"),
            ("login-wall-fallback-tile", "png"),
            ("logo-isolated", "svg"),
            ("hero-vignette", "svg"),
            ("avatar-generic", "svg"),
            ("arrow-left", "svg"),
            ("arrow-right", "svg")
        ]

        var totalBytes = 0
        for (name, fileExtension) in assets {
            let url = Self.resourcesDirectory.appendingPathComponent("\(name).\(fileExtension)")
            let image = try #require(NSImage(contentsOf: url), "\(name).\(fileExtension) did not load")
            let cost = VendorResourceImage.decodedByteCost(ofImageAt: url, image: image)
            #expect(cost > 0, "\(name).\(fileExtension) cost nothing")
            totalBytes += cost
        }

        let budget = VendorResourceImage.cacheBudget
        #expect(assets.count <= budget.countLimit)
        #expect(totalBytes <= budget.totalCostLimit, "the prewarm set (\(totalBytes) bytes) exceeds the budget")
    }

    /// A cost ceiling tighter than the count ceiling would evict entries the count limit still
    /// admits, which is exactly the thrash the limit exists to prevent.
    @Test func scrimColorCostBudgetCoversItsCountCeiling() {
        let budget = CatalogHeroImageMetadata.cacheBudget
        let payloadBytes = MemoryLayout<CatalogMarqueeScrimColor>.stride
        #expect(budget.totalCostLimit >= budget.countLimit * payloadBytes)
    }

    /// `NSImage(contentsOf:)` decodes lazily, so a rep-based cost reads as zero until the first
    /// draw. The cost has to come from the file's pixel dimensions instead.
    @Test func vendorCostComesFromFilePixelDimensionsNotARenderedRep() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 64,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)

        let image = try #require(NSImage(contentsOf: url))
        #expect(VendorResourceImage.decodedByteCost(ofImageAt: url, image: image) == 64 * 32 * 4)
    }

    /// A vector source with no pixel dimensions is charged at its declared size, and a declared
    /// size that is not a number must not trap the cost conversion.
    @Test func aSizeWithNoFiniteDimensionsStillCostsARealAmount() {
        let url = URL(fileURLWithPath: "/nowhere/absent.svg")
        let image = NSImage(size: NSSize(width: CGFloat.nan, height: CGFloat.infinity))
        #expect(VendorResourceImage.decodedByteCost(ofImageAt: url, image: image) > 0)
    }
}
