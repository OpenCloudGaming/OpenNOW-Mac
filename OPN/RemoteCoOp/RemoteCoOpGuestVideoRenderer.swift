import CoreMedia
import CoreVideo
import Foundation
import WebRTC

/// Remote Co-Op's video boundary: the one place a received track's RTC frame type becomes the native
/// frame every renderer consumes.
///
/// A guest's video arrives through a libwebrtc pipeline, so frames are handed over as
/// `RTCVideoFrame`s. The surface takes `OPNVideoFrame`s, so the conversion happens here, once, at
/// the edge rather than inside the renderer.
final class OPNRemoteCoOpGuestVideoRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let view: OPNMetalVideoView
    private let i420Converter = WebRTCI420BGRAConverter()
    private let lock = NSLock()
    private var bgraPool: CVPixelBufferPool?
    private var bgraPoolSize = CGSize.zero

    init(view: OPNMetalVideoView) {
        self.view = view
    }

    nonisolated func setSize(_ size: CGSize) {
        view.setSize(size)
    }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let native = nativeFrame(for: frame) else { return }
        view.renderFrame(native)
    }

    /// A decoded RTC frame as a native one. A `CVPixelBuffer`-backed frame passes through unread; a
    /// frame libwebrtc decoded itself arrives as I420 planes, which are converted to BGRA — the one
    /// format the texture source binds directly for a non-bi-planar buffer.
    private nonisolated func nativeFrame(for frame: RTCVideoFrame) -> OPNVideoFrame? {
        let presentationTime = CMTime(value: frame.timeStampNs, timescale: 1_000_000_000)
        let rotation = OPNVideoRotation(rtcRotation: frame.rotation)
        if let buffer = frame.buffer as? RTCCVPixelBuffer {
            return OPNVideoFrame(pixelBuffer: buffer.pixelBuffer,
                                 presentationTime: presentationTime,
                                 rotation: rotation)
        }
        lock.lock()
        defer { lock.unlock() }
        guard let i420 = frame.newI420().buffer as? RTCI420Buffer,
              let pixelBuffer = convertedBGRA(from: i420) else { return nil }
        return OPNVideoFrame(pixelBuffer: pixelBuffer,
                             presentationTime: presentationTime,
                             rotation: rotation)
    }

    /// Call with `lock` held.
    private func convertedBGRA(from i420: RTCI420Buffer) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        guard width > 0, height > 0 else { return nil }
        let pool = bgraPool(width: width, height: height)
        var pixelBuffer: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        return i420Converter.copy(i420, toBGRAOutput: pixelBuffer) ? pixelBuffer : nil
    }

    /// Call with `lock` held.
    private func bgraPool(width: Int, height: Int) -> CVPixelBufferPool? {
        let size = CGSize(width: width, height: height)
        if let bgraPool, bgraPoolSize == size { return bgraPool }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        bgraPool = pool
        bgraPoolSize = size
        return pool
    }
}

extension OPNVideoRotation {
    init(rtcRotation: RTCVideoRotation) {
        switch rtcRotation {
        case ._90: self = .clockwise90
        case ._180: self = .clockwise180
        case ._270: self = .clockwise270
        default: self = .none
        }
    }
}
