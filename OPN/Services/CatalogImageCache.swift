import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftData

/// A decoded catalog image, plus - only when a caller asked for it - the compressed bytes it came
/// from. The hero needs those bytes because the scrim colour lives in the image's EXIF user
/// comment, which decoding discards. Nothing else does, and retaining them for every tile kept a
/// full second copy of the catalog's artwork alive that the memory cache's cost accounting never
/// even saw.
struct CatalogCachedImageData: @unchecked Sendable {
    let sourceData: Data?
    let image: NSImage
    let decodedByteCount: Int

    var memoryCost: Int { decodedByteCount + (sourceData?.count ?? 0) }
}

struct CatalogImageCacheStatistics: Sendable {
    let entryCount: Int
    let totalBytes: Int
}

actor CatalogImageCache {
    static let shared = CatalogImageCache()

    nonisolated private let memoryCache = CatalogImageMemoryCache()
    nonisolated private let containerStore = CatalogImageCacheContainerStore()
    private var inFlightLoads: [URL: Task<CatalogCachedImageData?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchQueue: [URL] = []
    private var queuedPrefetchURLs: Set<URL> = []
    private var priorityPrefetchQueue: [URL] = []
    private var queuedPriorityPrefetchURLs: Set<URL> = []
    private var priorityPrefetchWorkers = 0
    private var pendingAccessHits: [String: Int] = [:]
    private var metadataFlushTask: Task<Void, Never>?

    private let metadataFlushInterval: TimeInterval = 30

    private let maximumCacheAge: TimeInterval = 14 * 24 * 60 * 60
    private let maximumStoredBytes = 512 * 1024 * 1024
    private let maximumStoredEntries = 2_000
    private let pruneStoreThreshold = 25
    private let maximumPriorityPrefetchWorkers = 5
    private let pruneInterval: TimeInterval = 60
    nonisolated private let pruneThrottle = CatalogImageCachePruneThrottle()

    private init() {}

    nonisolated func configure(container: ModelContainer) {
        containerStore.configure(container: container)
    }

    /// Fetches the images the first frame actually shows. The regular prefetch
    /// deliberately trickles at background priority with a sleep between items,
    /// which is right for scroll-ahead and far too slow for the hero and the
    /// first rail during the splash screen.
    /// `retainingSourceData` must match what the eventual reader asks for. The hero requests its
    /// bytes for the EXIF scrim, so prefetching its artwork without them stored an entry the hero
    /// could not use - it missed, and decoded the largest image in the app a second time, during
    /// launch, once per rotation game.
    nonisolated func prefetchPriority(_ urls: [URL], maxPixelSize: CGFloat = 1024, retainingSourceData: Bool = false) {
        guard !urls.isEmpty else { return }
        Task(priority: .userInitiated) { [weak self] in
            await self?.startPriorityPrefetch(urls, maxPixelSize: maxPixelSize, retainingSourceData: retainingSourceData)
        }
    }

    nonisolated func prefetch(_ urls: [URL]) {
        Task(priority: .background) { [weak self] in
            await self?.startPrefetch(urls)
        }
    }

    func image(for url: URL, maxPixelSize: CGFloat = 1920 * 2, retainingSourceData: Bool = false) async -> CatalogCachedImageData? {
        if let cached = memoryCache.image(for: url), !retainingSourceData || cached.sourceData != nil {
            return cached
        }

        if !retainingSourceData, let existingTask = inFlightLoads[url] {
            return await existingTask.value
        }

        let task = Task<CatalogCachedImageData?, Never>.detached(priority: .utility, operation: { [weak self] in
            guard let self else { return nil }
            return await self.loadImage(for: url, maxPixelSize: maxPixelSize, retainingSourceData: retainingSourceData)
        })
        inFlightLoads[url] = task
        let result = await task.value
        inFlightLoads[url] = nil
        return result
    }

    func statistics() -> CatalogImageCacheStatistics {
        let empty = CatalogImageCacheStatistics(entryCount: 0, totalBytes: 0)
        let result = containerStore.perform { context -> CatalogImageCacheStatistics in
            // Only `byteCount` is read, so the blobs stay unfaulted; this runs on the same queue
            // that gates image loading.
            var descriptor = FetchDescriptor<CatalogImageCacheEntry>()
            descriptor.propertiesToFetch = [\.byteCount]
            guard let entries = try? context.fetch(descriptor) else { return empty }
            return CatalogImageCacheStatistics(entryCount: entries.count, totalBytes: entries.reduce(0) { $0 + $1.byteCount })
        }
        return result ?? empty
    }

    func clear() -> Bool {
        let didClear = containerStore.perform { context -> Bool in
            let descriptor = FetchDescriptor<CatalogImageCacheEntry>()
            guard let entries = try? context.fetch(descriptor) else { return false }
            for entry in entries {
                context.delete(entry)
            }
            return (try? context.save()) != nil
        }
        guard didClear == true else { return false }
        memoryCache.removeAll()
        prefetchQueue.removeAll()
        queuedPrefetchURLs.removeAll()
        priorityPrefetchQueue.removeAll()
        queuedPriorityPrefetchURLs.removeAll()
        prefetchTask?.cancel()
        prefetchTask = nil
        pruneThrottle.reset()
        return true
    }

    private func startPriorityPrefetch(_ urls: [URL], maxPixelSize: CGFloat, retainingSourceData: Bool) {
        var didEnqueue = false
        for url in urls where !queuedPriorityPrefetchURLs.contains(url) {
            guard !hasCachedImage(for: url) else { continue }
            queuedPriorityPrefetchURLs.insert(url)
            priorityPrefetchQueue.append(url)
            didEnqueue = true
        }
        guard didEnqueue else { return }
        while priorityPrefetchWorkers < maximumPriorityPrefetchWorkers, priorityPrefetchWorkers < priorityPrefetchQueue.count {
            priorityPrefetchWorkers += 1
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                while let url = await self.nextPriorityPrefetchURL() {
                    _ = await self.image(for: url, maxPixelSize: maxPixelSize, retainingSourceData: retainingSourceData)
                }
                await self.priorityPrefetchWorkerDidFinish()
            }
        }
    }

    private func nextPriorityPrefetchURL() -> URL? {
        guard !priorityPrefetchQueue.isEmpty else { return nil }
        let url = priorityPrefetchQueue.removeFirst()
        queuedPriorityPrefetchURLs.remove(url)
        return url
    }

    private func priorityPrefetchWorkerDidFinish() {
        priorityPrefetchWorkers = max(priorityPrefetchWorkers - 1, 0)
    }

    private func startPrefetch(_ urls: [URL]) {
        let uniqueUrls = Array(Dictionary(grouping: urls, by: { $0 }).keys)
        guard !uniqueUrls.isEmpty else { return }
        for url in uniqueUrls where !queuedPrefetchURLs.contains(url) {
            queuedPrefetchURLs.insert(url)
            prefetchQueue.append(url)
        }
        startPrefetchTaskIfNeeded()
    }

    private func startPrefetchTaskIfNeeded() {
        guard prefetchTask == nil, !prefetchQueue.isEmpty else { return }
        prefetchTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            while let url = await self.nextPrefetchURL() {
                guard !Task.isCancelled else { return }
                if self.hasCachedImage(for: url) { continue }
                _ = await self.image(for: url, maxPixelSize: 768)
                try? await Task.sleep(nanoseconds: 35_000_000)
            }
            await self.prefetchDidFinish()
        }
    }

    private func nextPrefetchURL() -> URL? {
        guard !prefetchQueue.isEmpty else { return nil }
        let url = prefetchQueue.removeFirst()
        queuedPrefetchURLs.remove(url)
        return url
    }

    private func prefetchDidFinish() {
        prefetchTask = nil
        startPrefetchTaskIfNeeded()
    }

    nonisolated private func loadImage(for url: URL, maxPixelSize: CGFloat, retainingSourceData: Bool) async -> CatalogCachedImageData? {
        if let stored = await loadStoredImage(for: url, maxPixelSize: maxPixelSize, retainingSourceData: retainingSourceData) {
            if stored.isFresh {
                return stored.imageData
            }
            refreshStoredImage(for: url, eTag: stored.eTag, lastModified: stored.lastModified, maxPixelSize: maxPixelSize, retainingSourceData: retainingSourceData)
            return stored.imageData
        }
        return await downloadAndStoreImage(for: url, eTag: "", lastModified: "", maxPixelSize: maxPixelSize, retainingSourceData: retainingSourceData)
    }

    nonisolated private func loadStoredImage(for url: URL, maxPixelSize: CGFloat, retainingSourceData: Bool) async -> StoredImage? {
        let key = url.absoluteString
        // Only the row is read on the persistence queue; decoding is far too slow to hold it.
        let row = containerStore.perform { context -> StoredRow? in
            var descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { $0.url == key })
            descriptor.fetchLimit = 1
            guard let entry = try? context.fetch(descriptor).first else { return nil }
            return StoredRow(data: entry.data, updatedAt: entry.updatedAt, eTag: entry.eTag, lastModified: entry.lastModified)
        }
        guard let row = row.flatMap({ $0 }), let decoded = Self.downsampledImage(from: row.data, maxPixelSize: maxPixelSize) else { return nil }
        await deferAccessMetadataUpdate(for: url)
        let imageData = CatalogCachedImageData(sourceData: retainingSourceData ? row.data : nil, image: decoded.image, decodedByteCount: decoded.decodedByteCount)
        memoryCache.setImage(imageData, for: url)
        return StoredImage(imageData: imageData, isFresh: Date().timeIntervalSince(row.updatedAt) < maximumCacheAge, eTag: row.eTag, lastModified: row.lastModified)
    }

    // Access metadata is batched: a save per image access floods the store with
    // write transactions while the catalog scrolls, which is expensive and (before
    // the cache got its own container) invalidated every SwiftData-observing view.
    private func deferAccessMetadataUpdate(for url: URL) {
        pendingAccessHits[url.absoluteString, default: 0] += 1
        scheduleMetadataFlush()
    }

    private func scheduleMetadataFlush() {
        guard metadataFlushTask == nil else { return }
        metadataFlushTask = Task.detached(priority: .utility) { [weak self, metadataFlushInterval] in
            try? await Task.sleep(nanoseconds: UInt64(metadataFlushInterval * 1_000_000_000))
            guard let self, let hits = await self.drainPendingAccessHits() else { return }
            self.flushAccessMetadata(hits)
        }
    }

    private func drainPendingAccessHits() -> [String: Int]? {
        metadataFlushTask = nil
        guard !pendingAccessHits.isEmpty else { return nil }
        let hits = pendingAccessHits
        pendingAccessHits.removeAll()
        return hits
    }

    nonisolated private func flushAccessMetadata(_ hits: [String: Int]) {
        let keys = Array(hits.keys)
        containerStore.performAsync { context in
            let descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { keys.contains($0.url) })
            guard let entries = try? context.fetch(descriptor) else { return }
            let now = Date()
            for entry in entries {
                entry.lastAccessedAt = now
                entry.hitCount += hits[entry.url] ?? 0
            }
            try? context.save()
        }
    }

    nonisolated private func refreshStoredImage(for url: URL, eTag: String, lastModified: String, maxPixelSize: CGFloat, retainingSourceData: Bool) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.downloadAndStoreImage(for: url, eTag: eTag, lastModified: lastModified, maxPixelSize: maxPixelSize, retainingSourceData: retainingSourceData)
        }
    }

    nonisolated private func downloadAndStoreImage(for url: URL, eTag: String, lastModified: String, maxPixelSize: CGFloat, retainingSourceData: Bool) async -> CatalogCachedImageData? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        if !eTag.isEmpty { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        if !lastModified.isEmpty { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let networkStart = OPNNetworkLog.start(&request, operation: "catalog.image")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            OPNNetworkLog.finish(request, operation: "catalog.image", startedAt: networkStart, data: data, response: response, error: nil)
            guard let httpResponse = response as? HTTPURLResponse else {
                await MainActor.run { OpenNOWLog.warning(.cache, "Catalog image response was not HTTP url=\(url.absoluteString)") }
                return nil
            }
            if httpResponse.statusCode == 304 {
                markStoredImageFresh(for: url)
                await MainActor.run { OpenNOWLog.debug(.cache, "Catalog image cache validated url=\(url.absoluteString)") }
                return await loadStoredImage(for: url, maxPixelSize: maxPixelSize, retainingSourceData: retainingSourceData)?.imageData
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                await MainActor.run { OpenNOWLog.warning(.cache, "Catalog image download failed status=\(httpResponse.statusCode) url=\(url.absoluteString)") }
                return nil
            }
            guard let decoded = Self.downsampledImage(from: data, maxPixelSize: maxPixelSize) else {
                await MainActor.run { OpenNOWLog.warning(.cache, "Catalog image data could not be decoded url=\(url.absoluteString) bytes=\(data.count)") }
                return nil
            }
            let imageData = CatalogCachedImageData(sourceData: retainingSourceData ? data : nil, image: decoded.image, decodedByteCount: decoded.decodedByteCount)
            store(imageData: imageData, sourceData: data, response: httpResponse, for: url)
            await MainActor.run { OpenNOWLog.debug(.cache, "Catalog image cached url=\(url.absoluteString) bytes=\(data.count)") }
            return imageData
        } catch {
            OPNNetworkLog.finish(request, operation: "catalog.image", startedAt: networkStart, data: nil, response: nil, error: error)
            await MainActor.run { OpenNOWLog.warning(.cache, "Catalog image download threw url=\(url.absoluteString) error=\(error.localizedDescription)") }
            return nil
        }
    }

    nonisolated private func hasCachedImage(for url: URL) -> Bool {
        memoryCache.containsImage(for: url)
    }

    nonisolated private func markStoredImageFresh(for url: URL) {
        let key = url.absoluteString
        containerStore.performAsync { context in
            var descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { $0.url == key })
            descriptor.fetchLimit = 1
            guard let entry = try? context.fetch(descriptor).first else { return }
            let now = Date()
            entry.updatedAt = now
            entry.lastAccessedAt = now
            try? context.save()
        }
    }

    nonisolated private func store(imageData: CatalogCachedImageData, sourceData: Data, response: HTTPURLResponse, for url: URL) {
        let key = url.absoluteString
        let mimeType = response.mimeType ?? ""
        let eTag = response.value(forHTTPHeaderField: "ETag") ?? ""
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? ""
        memoryCache.setImage(imageData, for: url)
        // The decoded image is already in the memory cache, so callers need nothing from this; the
        // write (and the prune behind it) stays off the queue's critical path where up to five
        // prefetch workers are waiting to read.
        containerStore.performAsync { context in
            var descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { $0.url == key })
            descriptor.fetchLimit = 1
            let now = Date()
            let entry = (try? context.fetch(descriptor).first) ?? CatalogImageCacheEntry(url: key, data: sourceData)
            if entry.modelContext == nil {
                context.insert(entry)
            }
            entry.data = sourceData
            entry.mimeType = mimeType
            entry.eTag = eTag
            entry.lastModified = lastModified
            entry.byteCount = sourceData.count
            entry.updatedAt = now
            entry.lastAccessedAt = now
            try? context.save()
            // Same context, same queue turn: the prune can only ever see a settled store.
            self.pruneIfNeeded(context: context)
        }
    }

    nonisolated private func pruneIfNeeded(context: ModelContext) {
        // A prune does a full-table fetch + sort; running it per store turns a burst of image
        // downloads into O(n²) scan work. Throttle to every N stores or T seconds.
        guard pruneThrottle.shouldPrune(storeThreshold: pruneStoreThreshold, interval: pruneInterval) else { return }
        let descriptor = FetchDescriptor<CatalogImageCacheEntry>(sortBy: [SortDescriptor(\CatalogImageCacheEntry.lastAccessedAt, order: .reverse)])
        guard let entries = try? context.fetch(descriptor) else { return }
        var totalBytes = 0
        var entriesToDelete: [CatalogImageCacheEntry] = []
        for (index, entry) in entries.enumerated() {
            totalBytes += entry.byteCount
            if index >= maximumStoredEntries || totalBytes > maximumStoredBytes {
                entriesToDelete.append(entry)
            }
        }
        guard !entriesToDelete.isEmpty else { return }
        for entry in entriesToDelete {
            context.delete(entry)
        }
        try? context.save()
    }

    static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> (image: NSImage, decodedByteCount: Int)? {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                return (image, cgImage.bytesPerRow * cgImage.height)
            }
        }
        return rasterizedVectorImage(from: data, maxPixelSize: maxPixelSize)
    }

    /// ImageIO has no SVG decoder, but the store-definition and rating endpoints serve their small
    /// icons as `image/svg+xml`. `NSImage(data:)` does decode SVG, so rasterize through a bitmap
    /// rep instead. Vector sources are resolution-independent, so the intrinsic size is scaled up
    /// for retina headroom rather than merely clamped down to `maxPixelSize`.
    private static func rasterizedVectorImage(from data: Data, maxPixelSize: CGFloat) -> (image: NSImage, decodedByteCount: Int)? {
        guard let vectorImage = NSImage(data: data) else { return nil }
        var intrinsicSize = vectorImage.size
        var largestArea: CGFloat = 0
        for representation in vectorImage.representations {
            let size = representation.size
            let area = size.width * size.height
            if size.width > 0, size.height > 0, area > largestArea {
                largestArea = area
                intrinsicSize = size
            }
        }
        guard intrinsicSize.width > 0, intrinsicSize.height > 0 else { return nil }
        let vectorUpscaleLimit: CGFloat = 8
        let scale = min(vectorUpscaleLimit, maxPixelSize / max(intrinsicSize.width, intrinsicSize.height))
        let pixelWidth = max(1, Int((intrinsicSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((intrinsicSize.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        vectorImage.draw(in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: pixelWidth, height: pixelHeight))
        return (image, bitmap.bytesPerRow * pixelHeight)
    }

    private struct StoredImage {
        let imageData: CatalogCachedImageData
        let isFresh: Bool
        let eTag: String
        let lastModified: String
    }

    /// A plain copy of the fields a load needs, so no `ModelContext`-bound object escapes the
    /// persistence queue.
    private struct StoredRow {
        let data: Data
        let updatedAt: Date
        let eTag: String
        let lastModified: String
    }
}

nonisolated private final class CatalogImageCachePruneThrottle: @unchecked Sendable {
    let lock = NSLock()
    private var storesSincePrune = 0
    private var lastPruneDate = Date.distantPast

    func shouldPrune(storeThreshold: Int, interval: TimeInterval) -> Bool {
        lock.withLock {
            storesSincePrune += 1
            let now = Date()
            guard storesSincePrune >= storeThreshold || now.timeIntervalSince(lastPruneDate) >= interval else { return false }
            storesSincePrune = 0
            lastPruneDate = now
            return true
        }
    }

    func reset() {
        lock.withLock {
            storesSincePrune = 0
            lastPruneDate = .distantPast
        }
    }
}

/// Owns the cache's `ModelContainer` and is the only place a `ModelContext` is created or used.
///
/// Every image store previously built its own context on whatever cooperative thread it landed on.
/// Those contexts then raced each other - one inserting a freshly downloaded entry while another's
/// prune deleted rows out from under it - and SwiftData surfaced that as a `swift_dynamicCast`
/// failure deep inside `ModelContext.save()`, i.e. a hard crash rather than a thrown error. A
/// context is not safe to use concurrently against a shared container, so all of that work is
/// funnelled onto one serial queue here.
///
/// The queue is deliberately not the cache actor: routing persistence back through the actor is
/// what caused the shared-container stall this cache was split out to avoid.
nonisolated private final class CatalogImageCacheContainerStore: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.opennow.catalog-image-cache.persistence")
    /// Only ever touched on `queue`, which is also the only thing that serialises it - no separate
    /// lock, and one context reused for the process lifetime now that nothing else can reach it.
    private var modelContainer: ModelContainer?
    private var context: ModelContext?

    func configure(container: ModelContainer) {
        queue.async { [self] in
            modelContainer = container
            context = nil
        }
    }

    /// Runs `work` against the queue's context and waits for the result. Returns nil when no
    /// container has been configured yet, the same "cache unavailable" outcome callers handle.
    func perform<T>(_ work: (ModelContext) -> T) -> T? {
        queue.sync {
            guard let context = resolvedContext() else { return nil }
            return work(context)
        }
    }

    /// For writes whose result nobody waits on. Keeps image loads off the queue's critical path.
    ///
    /// `work` is `@Sendable` because `queue.async` requires it: the closure outlives this call and
    /// crosses onto the persistence queue, so anything it captures has to be safe to send. Every
    /// caller captures only value types today (the fetch keys, the encoded bytes, the header
    /// strings); the annotation is what makes the compiler keep it that way, rather than letting a
    /// future caller quietly capture a model object and race the context this queue exists to
    /// serialise. `ModelContext` itself is not Sendable, but it arrives as a parameter from inside
    /// the queue rather than being captured, which is exactly the arrangement that stays safe.
    func performAsync(_ work: @escaping @Sendable (ModelContext) -> Void) {
        queue.async { [self] in
            guard let context = resolvedContext() else { return }
            work(context)
        }
    }

    private func resolvedContext() -> ModelContext? {
        if let context { return context }
        guard let modelContainer else { return nil }
        let context = ModelContext(modelContainer)
        self.context = context
        return context
    }
}

nonisolated private final class CatalogImageMemoryCache: @unchecked Sendable {
    private let cache = NSCache<NSURL, CatalogCachedImageBox>()

    init() {
        cache.countLimit = 384
        cache.totalCostLimit = 160 * 1024 * 1024
    }

    func image(for url: URL) -> CatalogCachedImageData? {
        cache.object(forKey: url as NSURL)?.value
    }

    func setImage(_ imageData: CatalogCachedImageData, for url: URL) {
        cache.setObject(CatalogCachedImageBox(value: imageData), forKey: url as NSURL, cost: imageData.memoryCost)
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    func containsImage(for url: URL) -> Bool {
        cache.object(forKey: url as NSURL) != nil
    }
}

nonisolated private final class CatalogCachedImageBox {
    let value: CatalogCachedImageData

    init(value: CatalogCachedImageData) {
        self.value = value
    }
}
