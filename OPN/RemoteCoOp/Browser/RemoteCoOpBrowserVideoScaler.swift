import CoreVideo
import Foundation
import VideoToolbox

/// Scales a decoded seat frame to a browser-encodable size, and normalises its pixel format.
///
/// A seat streams at its own resolution - 5K HEVC is ordinary - and a hardware H.264 encoder tops out
/// well below that, so the browser egress encodes a scaled copy rather than the seat's frame. The long
/// edge is capped and the aspect ratio preserved, and the result is always 8-bit bi-planar video-range,
/// which is the format the hardware H.264 encoder takes whatever the seat sent (10-bit, 4:4:4, full
/// range).
final class RemoteCoOpBrowserVideoScaler: @unchecked Sendable {
    let targetWidth: Int
    let targetHeight: Int

    private let lock = NSLock()
    private var transferSession: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?

    init(sourceWidth: Int, sourceHeight: Int, maximumDimension: Int = 1920) {
        let longEdge = max(1, max(sourceWidth, sourceHeight))
        let scale = longEdge > maximumDimension ? Double(maximumDimension) / Double(longEdge) : 1
        // Even dimensions: chroma is subsampled, and an odd edge makes the encoder reject the frame.
        func even(_ value: Int) -> Int { max(2, Int((Double(value) * scale).rounded()) & ~1) }
        targetWidth = even(max(1, sourceWidth))
        targetHeight = even(max(1, sourceHeight))
    }

    /// A pooled destination buffer holding the scaled frame, or the source unchanged when it is
    /// already exactly the target size.
    func scale(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard let transferSession = transferSession ?? makeTransferSession() else { return nil }
        guard let destination = makeDestination() else { return nil }
        guard VTPixelTransferSessionTransferImage(transferSession, from: source, to: destination) == noErr else {
            return nil
        }
        return destination
    }

    private func makeTransferSession() -> VTPixelTransferSession? {
        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr else {
            return nil
        }
        transferSession = session
        return session
    }

    private func makeDestination() -> CVPixelBuffer? {
        if pool == nil {
            let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
            let bufferAttributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                kCVPixelBufferWidthKey: NSNumber(value: targetWidth),
                kCVPixelBufferHeightKey: NSNumber(value: targetHeight),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, bufferAttributes as CFDictionary, &created) == kCVReturnSuccess else {
                return nil
            }
            pool = created
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }
}
