import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// A rendered frame about to be written. `CGImage` is immutable and internally synchronized, so the
/// wrapper carries it across the decode thread and the writer task without further copying.
public struct StreamScreenshotImage: @unchecked Sendable {
    public let cgImage: CGImage

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }
}

/// The bridge between the video decode path and the screenshot button.
///
/// Every decoded frame reaches `deliver` on whichever thread decodes it, and does almost nothing
/// unless a capture is waiting: one uncontended lock. A capture registers a continuation and the
/// *next* frame is rendered to a `CGImage` on the decode thread - GPU work, so a still frame costs
/// no meaningful decode time - and handed back. A timeout keeps a paused stream from hanging the
/// button forever.
public final class StreamScreenshotCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingContinuation: CheckedContinuation<StreamScreenshotImage?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let context: CIContext

    public init() {
        // A Metal-backed context renders on the GPU. Intermediates are not cached: a screenshot is
        // one render of one frame, so the cache would only hold onto an image nobody reuses.
        context = CIContext(options: [.cacheIntermediates: false])
    }

    /// Waits for the next decoded frame and renders it. Returns nil when the timeout elapses or the
    /// capture is already pending or cancelled.
    public func capture(timeout: Duration = .seconds(2)) async -> StreamScreenshotImage? {
        await withCheckedContinuation { continuation in
            let task = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.resolve(nil)
            }
            lock.withLock {
                if pendingContinuation != nil {
                    continuation.resume(returning: nil)
                    task.cancel()
                    return
                }
                pendingContinuation = continuation
                timeoutTask = task
            }
        }
    }

    /// Called once per decoded frame. Renders only while a capture is waiting.
    public func deliver(_ pixelBuffer: CVPixelBuffer) {
        let isWaiting = lock.withLock { pendingContinuation != nil }
        guard isWaiting else { return }
        guard let image = render(pixelBuffer) else {
            resolve(nil)
            return
        }
        resolve(StreamScreenshotImage(cgImage: image))
    }

    /// Whether a capture is waiting. Lets a transport skip the format conversion the `deliver` call
    /// would throw away when nothing is waiting.
    public var hasPendingCapture: Bool {
        lock.withLock { pendingContinuation != nil }
    }

    /// Drops a waiting capture, e.g. when the stream tears down before a frame arrives.
    public func cancel() {
        resolve(nil)
    }

    private func resolve(_ image: StreamScreenshotImage?) {
        let (continuation, task) = lock.withLock {
            let continuation = pendingContinuation
            let task = timeoutTask
            pendingContinuation = nil
            timeoutTask = nil
            return (continuation, task)
        }
        task?.cancel()
        continuation?.resume(returning: image)
    }

    private func render(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard !image.extent.isEmpty else { return nil }
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
