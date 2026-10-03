import AppKit
import AVFoundation

/// Recording thumbnails, decoded off the main thread and cached by recording id. Split out of
/// `RecordingsView.swift`, which had reached the 600-line ceiling.
@MainActor
enum RecordingThumbnailLoader {
    /// 360x216 frames are ~0.3MB decoded; 96 entries covers the visible library with overscan, and
    /// 32MB is ~100 thumbnails, so the count is the binding limit.
    static let cacheBudget = ImageCacheBudget(countLimit: 96, totalCostLimit: 32 * 1024 * 1024)
    private static let cache: NSCache<NSString, NSImage> = cacheBudget.makeCache()

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
