import CoreVideo
import Foundation
import VideoToolbox

/// Converts decoded surfaces into a pixel format a consumer can take, through
/// `VTPixelTransferSession` (hardware where the GPU has a path, otherwise Apple's SIMD converters).
///
/// Exists because the NVST decoder now emits what the bitstream is — `xf20`, `xf44`, 4:2:2 — and
/// two consumers downstream were written for NV12: libwebrtc's `RTCCVPixelBuffer` (Remote Co-Op
/// guests) reads only NV12 and BGRA, and the recorder's asset-writer adaptor is declared once from
/// the first frame. Each keeps one of these and converts only frames it cannot take as they are, so
/// the common 8-bit 4:2:0 session pays nothing.
final class OPNPixelBufferTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int, height: Int, format: OSType) = (0, 0, 0)

    /// `source` itself when it already has `format`, else a converted copy, or nil if the
    /// transfer fails.
    func convert(_ source: CVPixelBuffer, to format: OSType) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) != format else { return source }
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        guard width > 0, height > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let session = ensureSession(), let pool = ensurePool(width: width, height: height, format: format) else { return nil }
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess, let destination else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr else { return nil }
        // Colour tags travel with the frame; the destination pool knows nothing about them.
        CVBufferPropagateAttachments(source, destination)
        return destination
    }

    private func ensureSession() -> VTPixelTransferSession? {
        if let session { return session }
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created) == noErr, let created else { return nil }
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        return created
    }

    private func ensurePool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        if let pool, poolKey == (width, height, format) { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: format),
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: 3]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &created) == kCVReturnSuccess else { return nil }
        pool = created
        poolKey = (width, height, format)
        return created
    }

    /// The formats libwebrtc's `RTCCVPixelBuffer` can read (its `toI420` and crop/scale paths
    /// handle NV12 and 32-bit BGRA/ARGB and nothing else).
    static func isLibWebRTCReadable(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_32BGRA
            || format == kCVPixelFormatType_32ARGB
    }
}
