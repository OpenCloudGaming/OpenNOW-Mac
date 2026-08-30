import CoreGraphics
import CoreVideo
import Foundation
import QuartzCore

/// Detected horizontal extent of real picture content inside a frame that the
/// server delivered with baked-in pillarbox columns.
///
/// GeForce NOW renders a 16:9-only game into the full requested canvas (a 21:9
/// stream carries a 3840x2160 image centred in 5120x2160) and encodes the side
/// bars as black pixels. Nothing in the WebRTC metadata describes where those
/// bars start, so the boundary has to be measured from the luma plane.
struct OPNPillarboxContentRect: Equatable {
    /// Left edge of picture content, as a fraction of frame width.
    var left: Double
    /// Right edge of picture content, as a fraction of frame width.
    var right: Double

    static let full = OPNPillarboxContentRect(left: 0, right: 1)

    var isFull: Bool { left <= 0.001 && right >= 0.999 }
    var width: Double { max(0, right - left) }
}

/// Measures pillarbox extent from the luma plane, then latches the result.
///
/// Detection is deliberately infrequent. A per-frame measurement would let the
/// bars "breathe" whenever a scene fades to black, because dark picture columns
/// are indistinguishable from bar columns by luma alone. Instead the boundary is
/// measured, snapped to a standard aspect ratio, and held until a slow re-confirm
/// disagrees several times in a row.
final class OPNPillarboxDetector {
    /// Aspect ratios worth snapping to. A measurement within `aspectSnapTolerance`
    /// of one of these is almost certainly that ratio plus rounding.
    /// 64:27 is the 21:9 ultrawide standard, needed for a 21:9 title pillarboxed
    /// inside a 32:9 canvas.
    private static let standardAspects: [Double] = [16.0 / 9.0, 16.0 / 10.0, 4.0 / 3.0, 3.0 / 2.0, 5.0 / 4.0, 64.0 / 27.0]
    private static let aspectSnapTolerance = 0.015

    /// Luma above the frame's black floor that marks a column as picture content.
    /// Normalised 0...1, so this is ~5 codes of 8-bit headroom.
    private static let contentLumaMargin = 0.02

    /// Darkest a column may be and still count as a genuine bar. Video-range black
    /// lands near 0.0625, so this leaves headroom for encoder noise without
    /// admitting merely-dim picture.
    private static let maximumBlackFloor = 0.12

    /// Rows sampled per measurement. The bars run the full frame height, so a
    /// sparse row sample is as decisive as a dense one and far cheaper.
    private static let sampledRows = 32

    /// Seconds between re-confirm measurements once a rect is latched.
    private static let confirmInterval: CFTimeInterval = 2.0

    /// Seconds between attempts before anything has latched. Without this a frame
    /// format the scan cannot read (software I420, say) would be re-scanned on
    /// every single frame instead of a few times a second.
    private static let initialInterval: CFTimeInterval = 0.25

    /// Consecutive agreeing measurements required before a rect is latched, whether
    /// that is the first latch or a replacement. Guards against a single dark frame
    /// latching a wrong rect.
    private static let confirmsBeforeLatch = 3

    private(set) var contentRect = OPNPillarboxContentRect.full

    private var latchedSize = CGSize.zero
    private var lastMeasurement: CFTimeInterval = 0
    private var pendingRect: OPNPillarboxContentRect?
    private var pendingCount = 0
    private var hasLatched = false

    /// Discards the latch. Call when the stream restarts or the frame size changes.
    func reset() {
        contentRect = .full
        latchedSize = .zero
        lastMeasurement = 0
        pendingRect = nil
        pendingCount = 0
        hasLatched = false
    }

    /// Measures `pixelBuffer` if a measurement is due, and updates `contentRect`.
    ///
    /// Returns `true` when `contentRect` changed, so callers can invalidate any
    /// geometry derived from it.
    @discardableResult
    func update(with pixelBuffer: CVPixelBuffer, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if size != latchedSize {
            reset()
            latchedSize = size
        } else if now - lastMeasurement < (hasLatched ? Self.confirmInterval : Self.initialInterval) {
            return false
        }
        lastMeasurement = now

        guard let measured = Self.measure(pixelBuffer) else { return false }
        let candidate = Self.snapToStandardAspect(measured, frameSize: size)

        // Every change needs repeated agreement, the first latch included. Latching
        // on a single measurement lets one unlucky dark frame at stream start hold a
        // wrong rect for seconds. Starting from `.full` means the cost of waiting is
        // only that bars stay black a moment longer, which is the safe direction.
        if hasLatched, Self.rectsMatch(candidate, contentRect) {
            pendingRect = nil
            pendingCount = 0
            return false
        }
        if let pending = pendingRect, Self.rectsMatch(pending, candidate) {
            pendingCount += 1
        } else {
            pendingRect = candidate
            pendingCount = 1
        }
        guard pendingCount >= Self.confirmsBeforeLatch else { return false }
        pendingRect = nil
        pendingCount = 0
        hasLatched = true
        return applyIfChanged(candidate)
    }

    private func applyIfChanged(_ rect: OPNPillarboxContentRect) -> Bool {
        guard !Self.rectsMatch(rect, contentRect) else { return false }
        contentRect = rect
        return true
    }

    private static func rectsMatch(_ a: OPNPillarboxContentRect, _ b: OPNPillarboxContentRect) -> Bool {
        abs(a.left - b.left) < 0.002 && abs(a.right - b.right) < 0.002
    }

    // MARK: - Measurement

    /// Bytes each luma sample occupies in plane 0 of a biplanar frame.
    ///
    /// Chroma subsampling does not change the luma container, but bit depth does:
    /// the 10-bit formats (`x420` for 4:2:0, `x444` for 4:4:4) carry each sample in
    /// the high bits of a 16-bit word, the 8-bit ones in a single byte. Reading a
    /// 16-bit plane a byte at a time yields the sample *low* bits — encoder noise,
    /// not luma — and covers only half the row, so the scan has to branch on the real
    /// container width rather than on a 4:2:0-only format allowlist.
    static func lumaBytesPerSample(_ pixelBuffer: CVPixelBuffer) -> Int {
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return 2
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
            return 1
        default:
            // Unknown format: infer from the stride. Row padding never doubles a row
            // at streaming widths, so two bytes per pixel means a 16-bit container.
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            return width > 0 && bytesPerRow / width >= 2 ? 2 : 1
        }
    }

    /// Scans the luma plane and returns the content extent, or nil if unreadable.
    static func measure(_ pixelBuffer: CVPixelBuffer) -> OPNPillarboxContentRect? {
        let isBiPlanar = CVPixelBufferGetPlaneCount(pixelBuffer) >= 2
        let isTenBit = lumaBytesPerSample(pixelBuffer) == 2
        guard isBiPlanar else { return nil }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        guard width > 1, height > 1 else { return nil }

        guard let columnSums = columnMeanLuma(base: base,
                                              width: width,
                                              height: height,
                                              bytesPerRow: bytesPerRow,
                                              isTenBit: isTenBit) else { return nil }

        // Derive the black floor from the frame itself rather than assuming a
        // range. Video-range black sits at ~0.0625, full-range at 0.0, and a
        // measured floor handles both without branching on the format flags.
        guard let blackFloor = columnSums.min() else { return nil }

        // Only believe in bars when the darkest column is actually near-black.
        // Otherwise the floor is just the dimmest *picture* column, and on a frame
        // with a brightness gradient the dim edge would be read as a bar.
        guard blackFloor <= maximumBlackFloor else { return .full }

        let threshold = blackFloor + contentLumaMargin

        // Per-column *mean* is the decisive statistic here. Encoder noise puts
        // isolated bright pixels well inside the black bars (peaks over 0.3 have
        // been measured), so a max- or any-pixel-based test finds "content" at
        // column zero and detects nothing.
        // No column clears the threshold: a uniformly dark frame, not a read
        // failure. Report full width so the caller latches "no bars" and stops
        // rescanning, rather than retrying forever.
        guard let firstContent = (0..<width).first(where: { columnSums[$0] > threshold }),
              let lastContent = (0..<width).reversed().first(where: { columnSums[$0] > threshold }),
              lastContent > firstContent else {
            return .full
        }

        return OPNPillarboxContentRect(
            left: Double(firstContent) / Double(width),
            right: Double(lastContent + 1) / Double(width)
        )
    }

    /// Mean luma per column over a sampled subset of rows, normalised to 0...1. Nil when no row
    /// could be read.
    private static func columnMeanLuma(base: UnsafeMutableRawPointer,
                                       width: Int,
                                       height: Int,
                                       bytesPerRow: Int,
                                       isTenBit: Bool) -> [Double]? {
        let rowStep = max(1, height / sampledRows)
        var rowCount = 0
        var columnSums = [Double](repeating: 0, count: width)

        if isTenBit {
            let scale = 1.0 / 65535.0
            for y in stride(from: 0, to: height, by: rowStep) {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
                for x in 0..<width { columnSums[x] += Double(row[x]) * scale }
                rowCount += 1
            }
        } else {
            let scale = 1.0 / 255.0
            for y in stride(from: 0, to: height, by: rowStep) {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { columnSums[x] += Double(row[x]) * scale }
                rowCount += 1
            }
        }
        guard rowCount > 0 else { return nil }

        let inverseRows = 1.0 / Double(rowCount)
        for x in 0..<width { columnSums[x] *= inverseRows }
        return columnSums
    }

    /// Nudges a measured rect onto a standard aspect ratio when it is within
    /// tolerance, keeping the content centred. Removes the pixel of jitter that
    /// threshold choice introduces at the boundary.
    ///
    /// A measurement matching no standard ratio is rejected as `.full` rather than
    /// trusted. Genuine pillarbox is always some standard ratio inside the canvas,
    /// so an odd width means the scan found dark *picture* — a vignette, a dark UI
    /// panel, a night scene — not a bar. Returning the raw rect there is what makes
    /// the fill mirror content that should have been left alone.
    static func snapToStandardAspect(_ rect: OPNPillarboxContentRect, frameSize: CGSize) -> OPNPillarboxContentRect {
        guard frameSize.width > 0, frameSize.height > 0, rect.width > 0 else { return .full }
        let contentWidth = rect.width * Double(frameSize.width)
        let measuredAspect = contentWidth / Double(frameSize.height)
        guard let match = standardAspects.min(by: { abs($0 - measuredAspect) < abs($1 - measuredAspect) }),
              abs(match - measuredAspect) / match <= aspectSnapTolerance else {
            return .full
        }
        let snappedWidth = (match * Double(frameSize.height)) / Double(frameSize.width)
        guard snappedWidth <= 1.0 else { return .full }
        let inset = (1.0 - snappedWidth) / 2.0
        return OPNPillarboxContentRect(left: inset, right: 1.0 - inset)
    }
}
