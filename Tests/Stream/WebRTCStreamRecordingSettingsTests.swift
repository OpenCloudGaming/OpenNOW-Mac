//  The writer's pure encoder decisions: which pixel format the adaptor declares, which codec can
//  encode a given frame size, and what the automatic bitrate resolves to. No file is written here.
//  Split out of WebRTCStreamRecordingTests.swift, which is a suite of live recording runs.
//

import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import OpenNOW

@Suite("WebRTCStreamRecordingSettings")
struct WebRTCStreamRecordingSettingsTests {
    @Test("the writer keeps the decoder's pixel format and picks a codec that can encode it")
    func writerKeepsDecoderPixelFormatAndPicksEncodableCodec() throws {
        let nv12 = try #require(Self.makeNV12Frame(width: 16, height: 16))
        let bgra = try #require(Self.makeBGRAFrame(width: 16, height: 16))
        // NV12 goes to the encoder untouched; anything else has already been converted to BGRA by
        // the time it reaches the writer.
        #expect(WebRTCStreamRecorder.adaptorPixelFormat(for: nv12) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        #expect(WebRTCStreamRecorder.adaptorPixelFormat(for: bgra) == kCVPixelFormatType_32BGRA)

        // H.264 hardware encode stops short of NVST's 5K, so that resolution has to be HEVC.
        #expect(WebRTCStreamRecorder.videoCodec(width: 1920, height: 1080) == .h264)
        #expect(WebRTCStreamRecorder.videoCodec(width: 3840, height: 2160) == .h264)
        #expect(WebRTCStreamRecorder.videoCodec(width: 5120, height: 2160) == .hevc)
    }

    @Test("the automatic bitrate is capped so 5K120 does not ask for 166 Mbps")
    func automaticBitrateIsCappedAtHighResolutions() {
        let recorder = WebRTCStreamRecorder()
        func automaticBitrate(width: Int, height: Int, fps: Int) -> Int {
            let configuration = WebRTCStreamRecordingConfiguration(
                title: "Bitrate Regression",
                applicationID: "100",
                width: width,
                height: height,
                fps: fps,
                videoBitrateMbps: 0,
                audioBitrateKbps: 128,
                enhancedVideoEnabled: false
            )
            let settings = recorder.videoSettings(configuration: configuration, width: width, height: height)
            let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
            return compression?[AVVideoAverageBitRateKey] as? Int ?? 0
        }

        #expect(automaticBitrate(width: 1920, height: 1080, fps: 60) == 1920 * 1080 * 60 / 8)
        #expect(automaticBitrate(width: 5120, height: 2160, fps: 120) == WebRTCStreamRecorder.automaticVideoBitrateCeiling)
        // An explicit setting is the user's call and stays uncapped.
        let explicit = WebRTCStreamRecordingConfiguration(
            title: "Bitrate Regression",
            applicationID: "100",
            width: 5120,
            height: 2160,
            fps: 120,
            videoBitrateMbps: 150,
            audioBitrateKbps: 128,
            enhancedVideoEnabled: false
        )
        let settings = recorder.videoSettings(configuration: explicit, width: 5120, height: 2160)
        let compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        #expect(compression?[AVVideoAverageBitRateKey] as? Int == 150_000_000)
    }

    private static func makeNV12Frame(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }

    private static func makeBGRAFrame(width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess else { return nil }
        return pixelBuffer
    }
}
