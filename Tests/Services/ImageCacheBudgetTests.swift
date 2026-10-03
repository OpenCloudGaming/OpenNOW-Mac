import AppKit
import Foundation
import Testing
@testable import OpenNOW

/// Four caches reached review with neither a `countLimit` nor a `totalCostLimit`, so each grew to
/// whatever the working set happened to be until the OS applied memory pressure. A limit is only
/// real when the writes charge for it - `NSCache` ignores `totalCostLimit` for entries written
/// without a cost - so these pin the ceiling *and* the decoded-byte cost behind it.
///
/// The live visual checks in the acceptance criteria (no change at uiScale 1.0/1.25/1.5, no scroll
/// thrash) need a running app. What can be asserted here is the invariant they rest on: each
/// ceiling is above the working set that surface can actually display.
@MainActor
struct ImageCacheBudgetTests {
    /// 13 rows are visible at 1.0 uiScale and ~9 at 1.5, and the library lists are `LazyVStack`s
    /// that keep a screen or two of overscan. 40 is a deliberately generous stand-in for the live
    /// grid working set on both surfaces.
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

    private static func budgets() -> [(name: String, budget: (countLimit: Int, totalCostLimit: Int))] {
        [
            ("VendorResourceImage", VendorResourceImage.cacheBudget),
            ("ScreenshotImageLoader", ScreenshotImageLoader.cacheBudget),
            ("RecordingThumbnailLoader", RecordingThumbnailLoader.cacheBudget),
            ("CatalogHeroImageMetadata", CatalogHeroImageMetadata.cacheBudget)
        ]
    }

    @Test func everyBoundedCacheSetsBothLimits() {
        for entry in Self.budgets() {
            #expect(entry.budget.countLimit > 0, "\(entry.name) has no count limit")
            #expect(entry.budget.totalCostLimit > 0, "\(entry.name) has no cost limit")
        }
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
    /// admits, which is exactly the thrash the limit exists to prevent. The scrim entry is three
    /// Doubles, so the two ceilings have to agree.
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
}
