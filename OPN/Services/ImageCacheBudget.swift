import Foundation

/// Decoded-byte ceiling for an image cache, sized to what the surface can display.
struct ImageCacheBudget {
    let countLimit: Int
    let totalCostLimit: Int

    /// Builds a cache with both limits applied, so an image cache cannot start out unbounded.
    /// `NSCache` ignores `totalCostLimit` for entries written without a cost, so inserts must pass one.
    func makeCache<KeyType: AnyObject, ObjectType: AnyObject>() -> NSCache<KeyType, ObjectType> {
        let cache = NSCache<KeyType, ObjectType>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        return cache
    }
}
