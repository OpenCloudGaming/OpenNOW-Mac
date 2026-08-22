//
//  CatalogImageCache.swift
//  MacForceNow
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftData

struct CatalogCachedImageData: @unchecked Sendable {
    let data: Data
    let image: NSImage
    let decodedByteCount: Int
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
    nonisolated func prefetchPriority(_ urls: [URL], maxPixelSize: CGFloat = 1024) {
        guard !urls.isEmpty else { return }
        Task(priority: .userInitiated) { [weak self] in
            await self?.startPriorityPrefetch(urls, maxPixelSize: maxPixelSize)
        }
    }

    nonisolated func prefetch(_ urls: [URL]) {
        Task(priority: .background) { [weak self] in
            await self?.startPrefetch(urls)
        }
    }

    func image(for url: URL, maxPixelSize: CGFloat = 1920 * 2) async -> CatalogCachedImageData? {
        if let cached = memoryCache.image(for: url) {
            return cached
        }

        if let existingTask = inFlightLoads[url] {
            return await existingTask.value
        }

        let task = Task<CatalogCachedImageData?, Never>.detached(priority: .utility, operation: { [weak self] in
            guard let self else { return nil }
            return await self.loadImage(for: url, maxPixelSize: maxPixelSize)
        })
        inFlightLoads[url] = task
        let result = await task.value
        inFlightLoads[url] = nil
        return result
    }

    func statistics() -> CatalogImageCacheStatistics {
        guard let context = makeContext() else { return CatalogImageCacheStatistics(entryCount: 0, totalBytes: 0) }
        let descriptor = FetchDescriptor<CatalogImageCacheEntry>()
        guard let entries = try? context.fetch(descriptor) else { return CatalogImageCacheStatistics(entryCount: 0, totalBytes: 0) }
        return CatalogImageCacheStatistics(entryCount: entries.count, totalBytes: entries.reduce(0) { $0 + $1.byteCount })
    }

    func clear() -> Bool {
        guard let context = makeContext() else { return false }
        let descriptor = FetchDescriptor<CatalogImageCacheEntry>()
        guard let entries = try? context.fetch(descriptor) else { return false }
        for entry in entries {
            context.delete(entry)
        }
        do {
            try context.save()
            memoryCache.removeAll()
            prefetchQueue.removeAll()
            queuedPrefetchURLs.removeAll()
            priorityPrefetchQueue.removeAll()
            queuedPriorityPrefetchURLs.removeAll()
            prefetchTask?.cancel()
            prefetchTask = nil
            pruneThrottle.reset()
            return true
        } catch {
            return false
        }
    }

    private func startPriorityPrefetch(_ urls: [URL], maxPixelSize: CGFloat) {
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
                    _ = await self.image(for: url, maxPixelSize: maxPixelSize)
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

    nonisolated private func loadImage(for url: URL, maxPixelSize: CGFloat) async -> CatalogCachedImageData? {
        if let stored = await loadStoredImage(for: url, maxPixelSize: maxPixelSize) {
            if stored.isFresh {
                return stored.imageData
            }
            refreshStoredImage(for: url, eTag: stored.eTag, lastModified: stored.lastModified, maxPixelSize: maxPixelSize)
            return stored.imageData
        }
        return await downloadAndStoreImage(for: url, eTag: "", lastModified: "", maxPixelSize: maxPixelSize)
    }

    nonisolated private func loadStoredImage(for url: URL, maxPixelSize: CGFloat) async -> StoredImage? {
        guard let context = makeContext() else { return nil }
        let key = url.absoluteString
        var descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { $0.url == key })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first,
              let decoded = Self.downsampledImage(from: entry.data, maxPixelSize: maxPixelSize) else { return nil }
        await deferAccessMetadataUpdate(for: url)
        let imageData = CatalogCachedImageData(data: entry.data, image: decoded.image, decodedByteCount: decoded.decodedByteCount)
        memoryCache.setImage(imageData, for: url)
        return StoredImage(imageData: imageData, isFresh: Date().timeIntervalSince(entry.updatedAt) < maximumCacheAge, eTag: entry.eTag, lastModified: entry.lastModified)
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
        guard let context = makeContext() else { return }
        let keys = Array(hits.keys)
        let descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { keys.contains($0.url) })
        guard let entries = try? context.fetch(descriptor) else { return }
        let now = Date()
        for entry in entries {
            entry.lastAccessedAt = now
            entry.hitCount += hits[entry.url] ?? 0
        }
        try? context.save()
    }

    nonisolated private func refreshStoredImage(for url: URL, eTag: String, lastModified: String, maxPixelSize: CGFloat) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await self.downloadAndStoreImage(for: url, eTag: eTag, lastModified: lastModified, maxPixelSize: maxPixelSize)
        }
    }

    nonisolated private func downloadAndStoreImage(for url: URL, eTag: String, lastModified: String, maxPixelSize: CGFloat) async -> CatalogCachedImageData? {
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
                await MainActor.run { MacForceNowLog.warning(.cache, "Catalog image response was not HTTP url=\(url.absoluteString)") }
                return nil
            }
            if httpResponse.statusCode == 304 {
                markStoredImageFresh(for: url)
                await MainActor.run { MacForceNowLog.debug(.cache, "Catalog image cache validated url=\(url.absoluteString)") }
                return await loadStoredImage(for: url, maxPixelSize: maxPixelSize)?.imageData
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                await MainActor.run { MacForceNowLog.warning(.cache, "Catalog image download failed status=\(httpResponse.statusCode) url=\(url.absoluteString)") }
                return nil
            }
            guard let decoded = Self.downsampledImage(from: data, maxPixelSize: maxPixelSize) else {
                await MainActor.run { MacForceNowLog.warning(.cache, "Catalog image data could not be decoded url=\(url.absoluteString) bytes=\(data.count)") }
                return nil
            }
            let imageData = CatalogCachedImageData(data: data, image: decoded.image, decodedByteCount: decoded.decodedByteCount)
            store(imageData: imageData, response: httpResponse, for: url)
            await MainActor.run { MacForceNowLog.debug(.cache, "Catalog image cached url=\(url.absoluteString) bytes=\(data.count)") }
            return imageData
        } catch {
            OPNNetworkLog.finish(request, operation: "catalog.image", startedAt: networkStart, data: nil, response: nil, error: error)
            await MainActor.run { MacForceNowLog.warning(.cache, "Catalog image download threw url=\(url.absoluteString) error=\(error.localizedDescription)") }
            return nil
        }
    }

    nonisolated private func hasCachedImage(for url: URL) -> Bool {
        memoryCache.containsImage(for: url)
    }

    nonisolated private func markStoredImageFresh(for url: URL) {
        guard let context = makeContext() else { return }
        let key = url.absoluteString
        var descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { $0.url == key })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return }
        let now = Date()
        entry.updatedAt = now
        entry.lastAccessedAt = now
        try? context.save()
    }

    nonisolated private func store(imageData: CatalogCachedImageData, response: HTTPURLResponse, for url: URL) {
        guard let context = makeContext() else { return }
        let key = url.absoluteString
        var descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { $0.url == key })
        descriptor.fetchLimit = 1
        let now = Date()
        let entry = (try? context.fetch(descriptor).first) ?? CatalogImageCacheEntry(url: key, data: imageData.data)
        if entry.modelContext == nil {
            context.insert(entry)
        }
        entry.data = imageData.data
        entry.mimeType = response.mimeType ?? ""
        entry.eTag = response.value(forHTTPHeaderField: "ETag") ?? ""
        entry.lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? ""
        entry.byteCount = imageData.data.count
        entry.updatedAt = now
        entry.lastAccessedAt = now
        memoryCache.setImage(imageData, for: url)
        try? context.save()
        pruneIfNeeded(context: context)
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

    nonisolated private func makeContext() -> ModelContext? {
        guard let modelContainer = containerStore.container() else { return nil }
        return ModelContext(modelContainer)
    }

    private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> (image: NSImage, decodedByteCount: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (image, cgImage.bytesPerRow * cgImage.height)
    }

    private struct StoredImage {
        let imageData: CatalogCachedImageData
        let isFresh: Bool
        let eTag: String
        let lastModified: String
    }
}

nonisolated private final class CatalogImageCachePruneThrottle: @unchecked Sendable {
    private let lock = NSLock()
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

nonisolated private final class CatalogImageCacheContainerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var modelContainer: ModelContainer?

    func configure(container: ModelContainer) {
        lock.withLock {
            modelContainer = container
        }
    }

    func container() -> ModelContainer? {
        lock.withLock { modelContainer }
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
        cache.setObject(CatalogCachedImageBox(value: imageData), forKey: url as NSURL, cost: imageData.decodedByteCount)
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
