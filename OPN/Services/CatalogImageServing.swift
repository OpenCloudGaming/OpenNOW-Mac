//
//  CatalogImageServing.swift
//  OpenNOW
//

import Foundation

protocol CatalogImageServing: Sendable {
    nonisolated func prefetch(_ urls: [URL])
    func image(for url: URL, maxPixelSize: CGFloat) async -> CatalogCachedImageData?
    func statistics() async -> CatalogImageCacheStatistics
    func clear() async -> Bool
}

extension CatalogImageCache: CatalogImageServing {}

private let catalogImageServingDefaultMaxPixelSize: CGFloat = 1920 * 2

extension CatalogImageServing {
    func image(for url: URL) async -> CatalogCachedImageData? {
        await image(for: url, maxPixelSize: catalogImageServingDefaultMaxPixelSize)
    }
}
