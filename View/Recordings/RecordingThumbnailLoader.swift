import AppKit
import AVFoundation

/// Recording thumbnails, decoded off the main thread and cached by recording id.
///
/// Split out of `RecordingsView.swift`, which was at the 600-line ceiling: the loader is a cache
/// and a decode, not a view, so it is the part that should move.
@MainActor
enum RecordingThumbnailLoader {
    /// One entry per recording, each a 360x216 frame (~0.3MB decoded). The library shows ~13 rows
    /// at 1.0 uiScale (~9 at 1.5) with a screen or two of lazy-stack overscan, so 96 entries keep
    /// the whole visible working set resident while still evicting rows the user has scrolled past;
    /// 32MB is ~100 thumbnails, so the count is the binding limit and the cost budget is the real
    /// memory ceiling if a heavier entry ever lands here.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 96
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    /// The configured ceiling, exposed so the acceptance criterion (a limit above the visible
    /// working set) is asserted by `ImageCacheBudgetTests` rather than only commented.
    static var cacheBudget: (countLimit: Int, totalCostLimit: Int) {
        (cache.countLimit, cache.totalCostLimit)
    }

    static func thumbnail(for recording: StreamRecording) async -> NSImage? {
        let key = recording.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let decoded = await generateThumbnail(videoURL: recording.videoURL, durationSeconds: recording.durationSeconds)
        if let decoded { cache.setObject(decoded.image, forKey: key, cost: decoded.cost) }
        return decoded?.image
    }

    /// Returns the decoded frame with its real decoded size, which is what the cache charges for
    /// the entry - a limit is only enforced for entries written with a cost.
    private static func generateThumbnail(videoURL: URL, durationSeconds: Double) async -> (image: NSImage, cost: Int)? {
        await Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 216)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            let targetSeconds = max(0.2, min(max(durationSeconds * 0.18, 0.2), max(durationSeconds - 0.2, 0.2)))
            let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            let cgImage = await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    continuation.resume(returning: error == nil ? image : nil)
                }
            }
            guard let cgImage else { return nil }
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            return (image, cgImage.bytesPerRow * cgImage.height)
        }.value
    }
}
