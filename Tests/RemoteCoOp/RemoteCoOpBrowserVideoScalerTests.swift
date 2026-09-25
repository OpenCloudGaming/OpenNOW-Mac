import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import OpenNOW

/// A 5K seat cannot be H.264-encoded at source size, so the browser egress scales first. This proves
/// the scale factor and format normalisation, and that the scaled result is encodable downstream.
@Suite(.serialized) struct RemoteCoOpBrowserVideoScalerTests {
    private func makePixelBuffer(width: Int, height: Int, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess else {
            return nil
        }
        return pixelBuffer
    }

    @Test func capsTheLongEdgeAndPreservesAspect() {
        let fiveK = RemoteCoOpBrowserVideoScaler(sourceWidth: 5120, sourceHeight: 2880)
        #expect(fiveK.targetWidth == 1920)
        #expect(fiveK.targetHeight == 1080)

        let withinRange = RemoteCoOpBrowserVideoScaler(sourceWidth: 1280, sourceHeight: 720)
        #expect(withinRange.targetWidth == 1280)
        #expect(withinRange.targetHeight == 720)
    }

    @Test func keepsBothEdgesEven() {
        let odd = RemoteCoOpBrowserVideoScaler(sourceWidth: 1001, sourceHeight: 999)
        #expect(odd.targetWidth % 2 == 0)
        #expect(odd.targetHeight % 2 == 0)
        #expect(odd.targetWidth == 1000)
        #expect(odd.targetHeight == 998)
    }

    @Test func scalesToBiPlanarVideoRange() throws {
        let source = try #require(makePixelBuffer(width: 3840, height: 2160))
        let scaler = RemoteCoOpBrowserVideoScaler(sourceWidth: 3840, sourceHeight: 2160)
        let scaled = try #require(scaler.scale(source))

        #expect(CVPixelBufferGetWidth(scaled) == 1920)
        #expect(CVPixelBufferGetHeight(scaled) == 1080)
        #expect(CVPixelBufferGetPixelFormatType(scaled) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        // The scaled frame is what the browser's H.264 encoder actually receives, so prove it encodes.
        let transcoder = try RemoteCoOpBrowserVideoTranscoder(width: 1920, height: 1080, fps: 60, averageBitrate: 8_000_000)
        try transcoder.encode(scaled, presentationTime: CMTime(value: 0, timescale: 90_000))
        transcoder.invalidate()
    }

    @Test func scalesAnUltrawideLongEdge() throws {
        let source = try #require(makePixelBuffer(width: 5120, height: 2160))
        let scaler = RemoteCoOpBrowserVideoScaler(sourceWidth: 5120, sourceHeight: 2160)
        let scaled = try #require(scaler.scale(source))
        #expect(CVPixelBufferGetWidth(scaled) == 1920)
        #expect(CVPixelBufferGetHeight(scaled) == 810)
    }

    /// The seat decodes to 10-bit bi-planar (`xf20`), which is what the real host feeds the egress.
    /// H.264 needs 8-bit, so the scaler has to convert bit depth as well as size.
    @Test func scalesTenBitToEightBit() throws {
        let source = try #require(makePixelBuffer(width: 5120, height: 2160,
                                                  format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        let scaler = RemoteCoOpBrowserVideoScaler(sourceWidth: 5120, sourceHeight: 2160)
        let scaled = try #require(scaler.scale(source))
        #expect(CVPixelBufferGetWidth(scaled) == 1920)
        #expect(CVPixelBufferGetHeight(scaled) == 810)
        #expect(CVPixelBufferGetPixelFormatType(scaled) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        let transcoder = try RemoteCoOpBrowserVideoTranscoder(width: 1920, height: 810, fps: 60, averageBitrate: 8_000_000)
        try transcoder.encode(scaled, presentationTime: CMTime(value: 0, timescale: 90_000))
        transcoder.invalidate()
    }
}
