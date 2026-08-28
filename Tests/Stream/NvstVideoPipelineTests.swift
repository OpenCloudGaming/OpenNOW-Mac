import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import OpenNOW

/// Drives `NvstVideoPipeline` with real VideoToolbox decodes, because the recovery behavior under
/// test depends on how VideoToolbox actually fails: a hard decode failure used to count silently
/// toward a fatal threshold of 30 while every frame in the broken reference chain was rejected —
/// a measured ~141-frame (~1.2 s) outage per loss event on live 5K/120 sessions.
@Suite(.serialized)
struct NvstVideoPipelineTests {
    private static let width = 320
    private static let height = 240

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() { lock.lock(); raised = true; lock.unlock() }
        var isRaised: Bool { lock.lock(); defer { lock.unlock() }; return raised }
    }

    /// Polls a condition off the main thread; the pipeline decodes on its own serial queue.
    private func wait(seconds: Double, for condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(10_000)
        }
        return condition()
    }

    private func makePixelBuffer(fill: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Self.width, Self.height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, Int32(plane == 0 ? fill : 128), bytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Hardware-encodes real H.264 access units in Annex-B form, the way the reassembler would
    /// deliver them. Same construction as `NvstVideoToolboxDecoderTests`.
    private func encodeAnnexB(frameCount: Int) -> [Data] {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(Self.width), height: Int32(Self.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &session
        ) == noErr, let session else { return [] }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        defer { VTCompressionSessionInvalidate(session) }

        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var units: [Data] = []
            func append(_ unit: Data) { lock.lock(); units.append(unit); lock.unlock() }
            var snapshot: [Data] { lock.lock(); defer { lock.unlock() }; return units }
        }
        let sink = Sink()
        for index in 0..<frameCount {
            guard let pixelBuffer = makePixelBuffer(fill: UInt8(32 + index * 20)) else { return [] }
            let time = CMTime(value: CMTimeValue(index * 3000), timescale: 90_000)
            guard VTCompressionSessionEncodeFrame(
                session, imageBuffer: pixelBuffer,
                presentationTimeStamp: time,
                duration: CMTime(value: 3000, timescale: 90_000),
                frameProperties: nil, infoFlagsOut: nil,
                outputHandler: { status, _, sampleBuffer in
                    guard status == noErr, let sampleBuffer,
                          let unit = Self.annexB(from: sampleBuffer) else { return }
                    sink.append(unit)
                }
            ) == noErr else { return [] }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return sink.snapshot
    }

    private static func annexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var output = Data()
        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 4
        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalHeaderLength) == noErr {
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let pointer else { continue }
                output.append(startCode)
                output.append(Data(bytes: pointer, count: size))
            }
        }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let dataPointer else { return nil }
        let bytes = UnsafeRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + Int(nalHeaderLength) <= length {
            var nalLength = 0
            for index in 0..<Int(nalHeaderLength) {
                nalLength = (nalLength << 8) | Int(bytes[offset + index])
            }
            offset += Int(nalHeaderLength)
            guard nalLength > 0, offset + nalLength <= length else { break }
            output.append(startCode)
            output.append(Data(bytes: bytes.advanced(by: offset), count: nalLength))
            offset += nalLength
        }
        return output.isEmpty ? nil : output
    }

    private func accessUnit(_ bytes: Data, index: UInt32) -> NvstAccessUnit {
        NvstAccessUnit(
            frameIndex: index,
            firstStreamPacketIndex: index,
            rtpTimestamp: index * 3000,
            isKeyframe: NvstAnnexB.isKeyframe(bytes, codec: .h264),
            bytes: bytes
        )
    }

    /// A frame the decoder rejects outright must request a keyframe on the spot rather than
    /// waiting out the 30-failure fatal threshold, and the request must be throttled — a broken
    /// chain rejects every following frame and one keyframe repairs the whole run.
    @Test func aHardDecodeFailureRequestsAKeyframeImmediately() throws {
        let units = encodeAnnexB(frameCount: 3)
        try #require(units.count >= 2)
        let decoder = try NvstVideoToolboxDecoder(codec: .h264)
        let keyframeAsked = Flag()
        let fatal = Flag()
        let pipeline = NvstVideoPipeline(
            decoder: decoder,
            clock: NvstSessionClock(),
            frameTimeMicroseconds: 8333,
            logger: nil,
            mediaSink: nil,
            onKeyframeNeeded: { keyframeAsked.raise() },
            onFatalDecodeError: { _ in fatal.raise() }
        )
        // A clean keyframe first, so the failure is a mid-stream chain break rather than startup.
        pipeline.submit(accessUnit(units[0], index: 1))
        #expect(wait(seconds: 3, for: { decoder.decodedFrameCount + decoder.failedFrameCount >= 1 }))
        #expect(!keyframeAsked.isRaised)

        // A structurally broken delta frame: a slice NAL whose body is garbage. VideoToolbox
        // rejects it with -12909 in its ASYNCHRONOUS output handler — measured here and on live
        // 5K/120 sessions — so `decode` returns cleanly and the pipeline only sees the failure on
        // a later frame.
        var corrupt = Data([0x00, 0x00, 0x00, 0x01, 0x41])
        corrupt.append(Data(repeating: 0xff, count: 12))
        pipeline.submit(accessUnit(corrupt, index: 2))
        #expect(wait(seconds: 3, for: { decoder.failedFrameCount >= 1 }),
                "the corrupt frame should have failed decode")

        // The next frame through the pipeline observes the async failure and must ask for the
        // keyframe that repairs the chain.
        pipeline.submit(accessUnit(units[1], index: 3))
        #expect(wait(seconds: 3, for: { keyframeAsked.isRaised }),
                "an observed decode failure must raise onKeyframeNeeded")
        #expect(!fatal.isRaised)
    }
}
