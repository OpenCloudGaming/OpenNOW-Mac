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
    private struct PoolKey: Hashable {
        let width: Int
        let height: Int
        let format: OSType
    }

    private let lock = NSLock()
    private var session: VTPixelTransferSession?
    private var pools: [PoolKey: CVPixelBufferPool] = [:]

    /// `source` itself when it already has `format`, else a converted copy, or nil if the
    /// transfer fails.
    func convert(_ source: CVPixelBuffer, to format: OSType) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(source) != format else { return source }
        return transfer(source, to: format, width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
    }

    /// A scaled copy at most `maxHeight` tall with the aspect preserved, or `source` when it already
    /// fits. VideoToolbox scales it on the GPU.
    func scaled(_ source: CVPixelBuffer, maxHeight: Int) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        guard maxHeight > 0, sourceHeight > maxHeight, sourceWidth > 0, sourceHeight > 0 else { return source }
        let target = OPNVideoSize.capped(width: sourceWidth, height: sourceHeight, maxHeight: maxHeight)
        return transfer(source, to: CVPixelBufferGetPixelFormatType(source), width: target.width, height: target.height)
    }

    private func transfer(_ source: CVPixelBuffer, to format: OSType, width: Int, height: Int) -> CVPixelBuffer? {
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
        // Scaling is what a capped replay tier asks this session for; Normal is VideoToolbox's own
        // default and is set here so a later change to it cannot silently crop instead.
        VTSessionSetProperty(created, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        session = created
        return created
    }

    /// Pools are cached per shape and format: one frame can ask for a scaled pool and a converted
    /// pool in the same pass, and rebuilding a pool per frame is a per-frame allocation.
    private func ensurePool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let key = PoolKey(width: width, height: height, format: format)
        if let pool = pools[key] { return pool }
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
        if pools.count >= 4 { pools.removeAll(keepingCapacity: true) }
        pools[key] = created
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

/// The one place a source frame's encoded size is decided, so the replay quality tier, the scaler
/// and the settings page's disk estimate cannot disagree about it.
enum OPNVideoSize {
    /// Even dimensions with the aspect preserved, for encoders that require them.
    static func capped(width: Int, height: Int, maxHeight: Int) -> (width: Int, height: Int) {
        let sourceWidth = max(2, width)
        let sourceHeight = max(2, height)
        guard maxHeight > 0, sourceHeight > maxHeight else { return (sourceWidth, sourceHeight) }
        let targetHeight = maxHeight - (maxHeight % 2)
        let scaled = Double(sourceWidth) * Double(targetHeight) / Double(sourceHeight)
        return (max(2, even(scaled)), targetHeight)
    }

    /// Rounded down to the nearest even value; H.264 and HEVC both refuse odd dimensions.
    static func even(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return rounded % 2 == 0 ? rounded : rounded - 1
    }
}
