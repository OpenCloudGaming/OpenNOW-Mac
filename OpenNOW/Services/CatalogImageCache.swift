//
//  CatalogImageCache.swift
//  OpenNOW
//

import AppKit
import Foundation
import OpenNOWTelemetry
import SwiftData

struct CatalogCachedImageData: @unchecked Sendable {
    let data: Data
    let image: NSImage
}

struct CatalogImageCacheStatistics: Sendable {
    let entryCount: Int
    let totalBytes: Int
}

actor CatalogImageCache {
    static let shared = CatalogImageCache()

    private let memoryCache = NSCache<NSURL, CatalogCachedImageBox>()
    private let containerStore = CatalogImageCacheContainerStore()
    private var inFlightLoads: [URL: Task<CatalogCachedImageData?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchQueue: [URL] = []
    private var queuedPrefetchURLs: Set<URL> = []

    private let maximumCacheAge: TimeInterval = 14 * 24 * 60 * 60
    private let maximumStoredBytes = 512 * 1024 * 1024
    private let maximumStoredEntries = 2_000

    private init() {
        memoryCache.countLimit = 512
        memoryCache.totalCostLimit = 128 * 1024 * 1024
    }

    nonisolated func configure(container: ModelContainer) {
        containerStore.configure(container: container)
    }

    nonisolated func prefetch(_ urls: [URL]) {
        Task(priority: .background) { [weak self] in
            await self?.startPrefetch(urls)
        }
    }

    func image(for url: URL) async -> CatalogCachedImageData? {
        if let cached = memoryCache.object(forKey: url as NSURL) {
            return cached.value
        }

        if let existingTask = inFlightLoads[url] {
            return await existingTask.value
        }

        let task = Task<CatalogCachedImageData?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadImage(for: url)
        }
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
            memoryCache.removeAllObjects()
            prefetchQueue.removeAll()
            queuedPrefetchURLs.removeAll()
            prefetchTask?.cancel()
            prefetchTask = nil
            return true
        } catch {
            return false
        }
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
                if await self.hasCachedImage(for: url) { continue }
                _ = await self.image(for: url)
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

    private func loadImage(for url: URL) async -> CatalogCachedImageData? {
        if let stored = loadStoredImage(for: url) {
            if stored.isFresh {
                return stored.imageData
            }
            refreshStoredImage(for: url, eTag: stored.eTag, lastModified: stored.lastModified)
            return stored.imageData
        }
        return await downloadAndStoreImage(for: url, eTag: "", lastModified: "")
    }

    private func loadStoredImage(for url: URL) -> StoredImage? {
        guard let context = makeContext() else { return nil }
        let key = url.absoluteString
        var descriptor = FetchDescriptor<CatalogImageCacheEntry>(predicate: #Predicate { $0.url == key })
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first,
              let image = NSImage(data: entry.data) else { return nil }
        entry.lastAccessedAt = Date()
        entry.hitCount += 1
        try? context.save()
        let imageData = CatalogCachedImageData(data: entry.data, image: image)
        memoryCache.setObject(CatalogCachedImageBox(value: imageData), forKey: url as NSURL, cost: entry.byteCount)
        return StoredImage(imageData: imageData, isFresh: Date().timeIntervalSince(entry.updatedAt) < maximumCacheAge, eTag: entry.eTag, lastModified: entry.lastModified)
    }

    private func refreshStoredImage(for url: URL, eTag: String, lastModified: String) {
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            _ = await self.downloadAndStoreImage(for: url, eTag: eTag, lastModified: lastModified)
        }
    }

    private func downloadAndStoreImage(for url: URL, eTag: String, lastModified: String) async -> CatalogCachedImageData? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        if !eTag.isEmpty { request.setValue(eTag, forHTTPHeaderField: "If-None-Match") }
        if !lastModified.isEmpty { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        let networkStart = OPNNetworkLog.start(request, operation: "catalog.image")
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
                return loadStoredImage(for: url)?.imageData
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                await MainActor.run { OpenNOWLog.warning(.cache, "Catalog image download failed status=\(httpResponse.statusCode) url=\(url.absoluteString)") }
                return nil
            }
            guard let image = NSImage(data: data) else {
                await MainActor.run { OpenNOWLog.warning(.cache, "Catalog image data could not be decoded url=\(url.absoluteString) bytes=\(data.count)") }
                return nil
            }
            let imageData = CatalogCachedImageData(data: data, image: image)
            store(imageData: imageData, response: httpResponse, for: url)
            await MainActor.run { OpenNOWLog.debug(.cache, "Catalog image cached url=\(url.absoluteString) bytes=\(data.count)") }
            return imageData
        } catch {
            OPNNetworkLog.finish(request, operation: "catalog.image", startedAt: networkStart, data: nil, response: nil, error: error)
            await MainActor.run { OpenNOWLog.warning(.cache, "Catalog image download threw url=\(url.absoluteString) error=\(error.localizedDescription)") }
            return nil
        }
    }

    private func hasCachedImage(for url: URL) -> Bool {
        memoryCache.object(forKey: url as NSURL) != nil
    }

    private func markStoredImageFresh(for url: URL) {
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

    private func store(imageData: CatalogCachedImageData, response: HTTPURLResponse, for url: URL) {
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
        memoryCache.setObject(CatalogCachedImageBox(value: imageData), forKey: url as NSURL, cost: imageData.data.count)
        try? context.save()
        pruneIfNeeded(context: context)
    }

    private func pruneIfNeeded(context: ModelContext) {
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

    private func makeContext() -> ModelContext? {
        guard let modelContainer = containerStore.container() else { return nil }
        return ModelContext(modelContainer)
    }

    private struct StoredImage {
        let imageData: CatalogCachedImageData
        let isFresh: Bool
        let eTag: String
        let lastModified: String
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

nonisolated private final class CatalogCachedImageBox {
    let value: CatalogCachedImageData

    init(value: CatalogCachedImageData) {
        self.value = value
    }
}
