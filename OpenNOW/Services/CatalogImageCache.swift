//
//  CatalogImageCache.swift
//  OpenNOW
//

import AppKit
import Foundation
import SwiftData

struct CatalogCachedImageData: Sendable {
    let data: Data
    let image: NSImage
}

@MainActor
final class CatalogImageCache {
    static let shared = CatalogImageCache()

    private let memoryCache = NSCache<NSURL, CatalogCachedImageBox>()
    private var modelContainer: ModelContainer?
    private var inFlightLoads: [URL: Task<CatalogCachedImageData?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?

    private let maximumCacheAge: TimeInterval = 14 * 24 * 60 * 60
    private let maximumStoredBytes = 512 * 1024 * 1024
    private let maximumStoredEntries = 2_000

    private init() {
        memoryCache.countLimit = 512
        memoryCache.totalCostLimit = 128 * 1024 * 1024
    }

    func configure(container: ModelContainer) {
        modelContainer = container
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

    func prefetch(_ urls: [URL]) {
        let uniqueUrls = Array(Dictionary(grouping: urls, by: { $0 }).keys)
        guard !uniqueUrls.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            for url in uniqueUrls {
                guard !Task.isCancelled else { return }
                if self.memoryCache.object(forKey: url as NSURL) != nil { continue }
                _ = await self.image(for: url)
                try? await Task.sleep(nanoseconds: 35_000_000)
            }
        }
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

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                OpenNOWLog.warning(.cache, "Catalog image response was not HTTP url=\(url.absoluteString)")
                return nil
            }
            if httpResponse.statusCode == 304 {
                markStoredImageFresh(for: url)
                OpenNOWLog.debug(.cache, "Catalog image cache validated url=\(url.absoluteString)")
                return loadStoredImage(for: url)?.imageData
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                OpenNOWLog.warning(.cache, "Catalog image download failed status=\(httpResponse.statusCode) url=\(url.absoluteString)")
                return nil
            }
            guard let image = NSImage(data: data) else {
                OpenNOWLog.warning(.cache, "Catalog image data could not be decoded url=\(url.absoluteString) bytes=\(data.count)")
                return nil
            }
            let imageData = CatalogCachedImageData(data: data, image: image)
            store(imageData: imageData, response: httpResponse, for: url)
            OpenNOWLog.debug(.cache, "Catalog image cached url=\(url.absoluteString) bytes=\(data.count)")
            return imageData
        } catch {
            OpenNOWLog.warning(.cache, "Catalog image download threw url=\(url.absoluteString) error=\(error.localizedDescription)")
            return nil
        }
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
        guard let modelContainer else { return nil }
        return ModelContext(modelContainer)
    }

    private struct StoredImage {
        let imageData: CatalogCachedImageData
        let isFresh: Bool
        let eTag: String
        let lastModified: String
    }
}

private final class CatalogCachedImageBox {
    let value: CatalogCachedImageData

    init(value: CatalogCachedImageData) {
        self.value = value
    }
}
