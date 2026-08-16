import CoreVideo
import Foundation
import Testing
@testable import MacForceNow

/// Builds an NV12 luma plane with `barFraction` of the width blacked out on each
/// side, standing in for the pillarbox GeForce NOW bakes into 16:9-only titles.
private func makeNV12(width: Int, height: Int, barFraction: Double) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              nil, &buffer) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let barWidth = Int(Double(width) * barFraction)
    for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
            // 16 is video-range black; 128 stands in for mid-grey picture.
            row[x] = (x < barWidth || x >= width - barWidth) ? 16 : 128
        }
    }
    return buffer
}

/// Luma ramp across the full width, with no bars at all.
private func makeGradient(width: Int, height: Int) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                              nil, &buffer) == kCVReturnSuccess, let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width { row[x] = UInt8(80 + (150 * x) / width) }
    }
    return buffer
}

private let ultrawide = CGSize(width: 5120, height: 2160)

@Suite("Pillarbox aspect snapping")
struct PillarboxSnapTests {
    @Test("An exact 16:9 measurement is preserved")
    func exactSixteenNine() {
        let snapped = OPNPillarboxDetector.snapToStandardAspect(
            OPNPillarboxContentRect(left: 0.125, right: 0.875), frameSize: ultrawide)
        #expect(abs(snapped.left - 0.125) < 1e-6)
        #expect(abs(snapped.right - 0.875) < 1e-6)
    }

    @Test("Threshold jitter of a few pixels snaps back onto 16:9")
    func jitterSnapsBack() {
        let snapped = OPNPillarboxDetector.snapToStandardAspect(
            OPNPillarboxContentRect(left: 614.0 / 5120.0, right: 1.0 - 620.0 / 5120.0),
            frameSize: ultrawide)
        #expect(abs(snapped.left - 0.125) < 1e-6)
        #expect(abs(snapped.right - 0.875) < 1e-6)
    }

    /// Trusting a non-standard width is what makes the fill mirror real picture.
    @Test("A width matching no standard ratio is rejected")
    func nonStandardWidthRejected() {
        let snapped = OPNPillarboxDetector.snapToStandardAspect(
            OPNPillarboxContentRect(left: 0.05, right: 0.95), frameSize: ultrawide)
        #expect(snapped.isFull)
    }

    @Test("Genuine full-width ultrawide content is left alone")
    func fullWidthStaysFull() {
        #expect(OPNPillarboxDetector.snapToStandardAspect(.full, frameSize: ultrawide).isFull)
    }
}

@Suite("Pillarbox luma scan")
struct PillarboxScanTests {
    @Test("Bars are found at the expected fractions")
    func findsBars() throws {
        let buffer = try #require(makeNV12(width: 5120, height: 2160, barFraction: 0.125))
        let measured = try #require(OPNPillarboxDetector.measure(buffer))
        #expect(abs(measured.left - 0.125) < 0.002)
        #expect(abs(measured.right - 0.875) < 0.002)
    }

    @Test("A frame with no bars measures as full width")
    func noBars() throws {
        let buffer = try #require(makeNV12(width: 5120, height: 2160, barFraction: 0.0))
        let measured = try #require(OPNPillarboxDetector.measure(buffer))
        #expect(measured.isFull)
    }

    /// The darkest column of a gradient is still picture, not a bar.
    @Test("A brightness gradient is not read as bars")
    func gradientNotBars() throws {
        let buffer = try #require(makeGradient(width: 5120, height: 2160))
        let measured = try #require(OPNPillarboxDetector.measure(buffer))
        #expect(measured.isFull)
    }

    @Test("An entirely black frame produces no fill")
    func allBlack() throws {
        let buffer = try #require(makeNV12(width: 5120, height: 2160, barFraction: 0.5))
        let measured = try #require(OPNPillarboxDetector.measure(buffer))
        #expect(measured.isFull)
    }
}

@Suite("Pillarbox latching")
struct PillarboxLatchTests {
    /// One unlucky dark frame at stream start must not hold a wrong rect.
    @Test("A single measurement does not latch")
    func singleMeasurementDoesNotLatch() throws {
        let buffer = try #require(makeNV12(width: 5120, height: 2160, barFraction: 0.125))
        let detector = OPNPillarboxDetector()
        detector.update(with: buffer, now: 0.0)
        #expect(detector.contentRect.isFull)
    }

    @Test("Repeated agreement latches the measured rect")
    func repeatedAgreementLatches() throws {
        let buffer = try #require(makeNV12(width: 5120, height: 2160, barFraction: 0.125))
        let detector = OPNPillarboxDetector()
        for tick in 0..<3 { detector.update(with: buffer, now: Double(tick)) }
        #expect(abs(detector.contentRect.left - 0.125) < 0.002)
        #expect(abs(detector.contentRect.right - 0.875) < 0.002)
    }
}
