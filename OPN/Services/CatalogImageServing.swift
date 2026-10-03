import Foundation

protocol CatalogImageServing: Sendable {
    nonisolated func prefetch(_ urls: [URL])
    nonisolated func prefetchPriority(_ urls: [URL], maxPixelSize: CGFloat, retainingSourceData: Bool)
    /// Queues artwork behind the priority set: decoded one at a time at background priority, so a
    /// slide that is not on screen yet warms without competing with the frame that is.
    nonisolated func prewarmDeferred(_ urls: [URL], maxPixelSize: CGFloat, retainingSourceData: Bool)
    /// `retainingSourceData` keeps the compressed bytes alongside the decoded image. Only callers
    /// that read the file's metadata (the hero, for its EXIF scrim colour) should ask for it -
    /// every retained copy is a second, full-size allocation held for the life of the cache entry.
    func image(for url: URL, maxPixelSize: CGFloat, retainingSourceData: Bool) async -> CatalogCachedImageData?
    /// Loads artwork on the reserved first-frame lane: the launch hero and the prefetch that warms
    /// the first rail. On-demand tile decodes cannot occupy that lane, so the artwork the first
    /// frame is waiting on never queues behind a screenful of tiles.
    func firstFrameImage(for url: URL, maxPixelSize: CGFloat, retainingSourceData: Bool) async -> CatalogCachedImageData?
    func statistics() async -> CatalogImageCacheStatistics
    func clear() async -> Bool
}

extension CatalogImageCache: CatalogImageServing {}

private let catalogImageServingDefaultMaxPixelSize: CGFloat = 1920 * 2

extension CatalogImageServing {
    func image(for url: URL, maxPixelSize: CGFloat) async -> CatalogCachedImageData? {
        await image(for: url, maxPixelSize: maxPixelSize, retainingSourceData: false)
    }

    func image(for url: URL, retainingSourceData: Bool = false) async -> CatalogCachedImageData? {
        await image(for: url, maxPixelSize: catalogImageServingDefaultMaxPixelSize, retainingSourceData: retainingSourceData)
    }

    func firstFrameImage(for url: URL, maxPixelSize: CGFloat) async -> CatalogCachedImageData? {
        await firstFrameImage(for: url, maxPixelSize: maxPixelSize, retainingSourceData: false)
    }

    func firstFrameImage(for url: URL, retainingSourceData: Bool = false) async -> CatalogCachedImageData? {
        await firstFrameImage(for: url, maxPixelSize: catalogImageServingDefaultMaxPixelSize, retainingSourceData: retainingSourceData)
    }
}
