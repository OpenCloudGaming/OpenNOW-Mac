//
//  CatalogImageCacheEntry.swift
//  MacForceNow
//

import Foundation
import SwiftData

@Model
final class CatalogImageCacheEntry {
    @Attribute(.unique) var url: String
    @Attribute(.externalStorage) var data: Data
    var mimeType: String
    var eTag: String
    var lastModified: String
    var byteCount: Int
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date
    var hitCount: Int

    init(
        url: String,
        data: Data,
        mimeType: String = "",
        eTag: String = "",
        lastModified: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAccessedAt: Date = Date(),
        hitCount: Int = 0
    ) {
        self.url = url
        self.data = data
        self.mimeType = mimeType
        self.eTag = eTag
        self.lastModified = lastModified
        self.byteCount = data.count
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
        self.hitCount = hitCount
    }
}
