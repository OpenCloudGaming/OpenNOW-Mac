import CoreGraphics
import CoreMedia
import CoreVideo

/// How a decoded picture is turned before it is displayed, in this app's own vocabulary rather than
/// a peer library's.
enum OPNVideoRotation: Int, Sendable {
    case none = 0
    case clockwise90 = 90
    case clockwise180 = 180
    case clockwise270 = 270

    /// Whether the rotation exchanges width and height.
    var swapsDimensions: Bool { self == .clockwise90 || self == .clockwise270 }
}

/// A decoded video frame with no peer-library types: the buffer, its timing and its geometry.
///
/// This is the type every NVST renderer, enhancement pass, snapshot path and diagnostic consumes.
/// RTC frame types exist only at Remote Co-Op's edges, where a received video track or a guest peer
/// is involved; that boundary converts once, here.
struct OPNVideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// The seat's capture time where the source carries one, `.invalid` where it does not.
    let presentationTime: CMTime
    let rotation: OPNVideoRotation
    let isKeyframe: Bool

    init(pixelBuffer: CVPixelBuffer,
         presentationTime: CMTime = .invalid,
         rotation: OPNVideoRotation = .none,
         isKeyframe: Bool = false) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.rotation = rotation
        self.isKeyframe = isKeyframe
    }

    /// The coded surface's width in display orientation: swapped for a quarter turn.
    var width: Int {
        let coded = CVPixelBufferGetWidth(pixelBuffer)
        return rotation.swapsDimensions ? CVPixelBufferGetHeight(pixelBuffer) : coded
    }

    var height: Int {
        let coded = CVPixelBufferGetHeight(pixelBuffer)
        return rotation.swapsDimensions ? CVPixelBufferGetWidth(pixelBuffer) : coded
    }

    /// Capture time in nanoseconds, the unit the renderers' cadence diagnostics and the guest relay
    /// expect. Zero when the source carries no usable timestamp.
    var timestampNs: Int64 {
        guard presentationTime.isValid else { return 0 }
        let scaled = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        return scaled.isValid ? scaled.value : 0
    }

    /// The geometry the surface is letterboxed to and that absolute pointer coordinates are measured
    /// against.
    ///
    /// VideoToolbox attaches a clean aperture when the coded frame is padded out to a macroblock
    /// multiple — a 1080p H.264 stream is coded 1920x1088 and displayed 1920x1080 — and returns the
    /// full buffer rect when there is nothing to trim. Row padding never reaches here at all: that
    /// lives in `bytesPerRow`, not in the width.
    var displaySize: CGSize {
        let clean = CVImageBufferGetCleanRect(pixelBuffer)
        guard clean.width >= 1, clean.height >= 1 else {
            return CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        }
        return CGSize(width: clean.width.rounded(), height: clean.height.rounded())
    }
}
