import CoreMedia
import QuartzCore
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import OpenNOW

/// Round-trips real hardware-encoded bitstreams through the Bifrost-free decode path. Hand-rolled
/// SPS/PPS bytes would only prove the parser; encoding first proves the whole VideoToolbox path —
/// parameter-set extraction, Annex-B → AVCC conversion, format description, and decode.
@Suite(.serialized)
struct NvstVideoToolboxDecoderTests {
    private static let width = 320
    private static let height = 240

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [(width: Int, height: Int, keyframe: Bool)] = []
        func append(_ pixelBuffer: CVPixelBuffer, keyframe: Bool) {
            lock.lock()
            buffers.append((CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), keyframe))
            lock.unlock()
        }
        var snapshot: [(width: Int, height: Int, keyframe: Bool)] { lock.lock(); defer { lock.unlock() }; return buffers }
    }

    private func makePixelBuffer(fill: UInt8) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Self.width, Self.height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)
            memset(base, Int32(plane == 0 ? fill : 128), bytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Encodes `frameCount` frames and returns them as Annex-B access units, the way the NVST
    /// reassembler would deliver them.
    private func encodeAnnexB(codec: CMVideoCodecType, frameCount: Int) -> [Data] {
        var session: VTCompressionSession?
        let created = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(Self.width),
            height: Int32(Self.height),
            codecType: codec,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard created == noErr, let session else { return [] }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        defer {
            VTCompressionSessionInvalidate(session)
        }

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
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: time,
                duration: CMTime(value: 3000, timescale: 90_000),
                frameProperties: nil,
                infoFlagsOut: nil,
                outputHandler: { status, _, sampleBuffer in
                    guard status == noErr, let sampleBuffer, let unit = Self.annexB(from: sampleBuffer) else { return }
                    sink.append(unit)
                }
            )
            guard status == noErr else { return [] }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return sink.snapshot
    }

    /// Rebuilds an Annex-B access unit from an encoded sample: the format description's parameter
    /// sets followed by the length-prefixed NAL units, all start-code delimited.
    private static func annexB(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let startCode = Data([0x00, 0x00, 0x00, 0x01])
        var output = Data()

        let codecType = CMFormatDescriptionGetMediaSubType(formatDescription)
        var parameterSetCount = 0
        var nalHeaderLength: Int32 = 4
        let readParameterSet: (Int, UnsafeMutablePointer<UnsafePointer<UInt8>?>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int>?, UnsafeMutablePointer<Int32>?) -> OSStatus = { index, pointerOut, sizeOut, countOut, headerOut in
            if codecType == kCMVideoCodecType_HEVC {
                return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(formatDescription, parameterSetIndex: index, parameterSetPointerOut: pointerOut, parameterSetSizeOut: sizeOut, parameterSetCountOut: countOut, nalUnitHeaderLengthOut: headerOut)
            }
            return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: index, parameterSetPointerOut: pointerOut, parameterSetSizeOut: sizeOut, parameterSetCountOut: countOut, nalUnitHeaderLengthOut: headerOut)
        }
        if readParameterSet(0, nil, nil, &parameterSetCount, &nalHeaderLength) == noErr {
            for index in 0..<parameterSetCount {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                guard readParameterSet(index, &pointer, &size, nil, nil) == noErr, let pointer else { continue }
                output.append(startCode)
                output.append(Data(bytes: pointer, count: size))
            }
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
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

    private func accessUnit(_ bytes: Data, index: UInt32, codec: NVSTVideoCodec) -> NvstAccessUnit {
        NvstAccessUnit(
            frameIndex: index,
            firstStreamPacketIndex: index,
            rtpTimestamp: index * 3000,
            isKeyframe: NvstAnnexB.isKeyframe(bytes, codec: codec),
            bytes: bytes
        )
    }

    @Test func hardwareEncodedH264RoundTripsBackToPixelBuffers() throws {
        let units = encodeAnnexB(codec: kCMVideoCodecType_H264, frameCount: 4)
        try #require(!units.isEmpty)
        // The first access unit must carry SPS+PPS, which is what makes the format description.
        let firstSets = NvstElementaryStream.parameterSets(in: units[0], codec: .h264)
        #expect(firstSets.isComplete)

        let collector = Collector()
        let decoder = try NvstVideoToolboxDecoder(codec: .h264)
        decoder.onPixelBuffer = { pixelBuffer, _, keyframe in
            collector.append(pixelBuffer, keyframe: keyframe)
        }
        for (index, bytes) in units.enumerated() {
            try decoder.decode(accessUnit(bytes, index: UInt32(index), codec: .h264))
        }
        decoder.drain()

        let decoded = collector.snapshot
        #expect(decoded.count == units.count)
        #expect(decoded.allSatisfy { $0.width == Self.width && $0.height == Self.height })
        #expect(decoder.decodedFrameCount == UInt64(units.count))
        #expect(decoder.failedFrameCount == 0)
        #expect(decoded.first?.keyframe == true)
    }

    @Test func hardwareEncodedHevcRoundTripsBackToPixelBuffers() throws {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else { return }
        let units = encodeAnnexB(codec: kCMVideoCodecType_HEVC, frameCount: 2)
        try #require(!units.isEmpty)
        let sets = NvstElementaryStream.parameterSets(in: units[0], codec: .hevc)
        // HEVC needs VPS as well, and it must be ordered VPS, SPS, PPS for VideoToolbox.
        #expect(!sets.videoParameterSets.isEmpty)
        #expect(sets.ordered.count >= 3)

        let collector = Collector()
        let decoder = try NvstVideoToolboxDecoder(codec: .hevc)
        decoder.onPixelBuffer = { pixelBuffer, _, keyframe in
            collector.append(pixelBuffer, keyframe: keyframe)
        }
        for (index, bytes) in units.enumerated() {
            try decoder.decode(accessUnit(bytes, index: UInt32(index), codec: .hevc))
        }
        decoder.drain()
        #expect(collector.snapshot.count == units.count)
    }

    @Test func decodingBeforeTheFirstKeyframeFailsWithoutCrashing() throws {
        let decoder = try NvstVideoToolboxDecoder(codec: .h264)
        // A delta slice with no parameter sets: the seat has not answered the PLI yet.
        let delta = accessUnit(Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9a, 0x20]), index: 0, codec: .h264)
        #expect(throws: NvstVideoToolboxDecoder.DecoderError.missingParameterSets) {
            try decoder.decode(delta)
        }
        #expect(decoder.decodedFrameCount == 0)
    }

    @Test func av1HasNoDecodePathYet() {
        // Upstream self-limits to H.264 receive; AV1 needs an av1C format description we do not
        // synthesize yet, so the decoder refuses rather than silently rendering nothing.
        #expect(throws: NvstVideoToolboxDecoder.DecoderError.unsupportedCodec("AV1")) {
            _ = try NvstVideoToolboxDecoder(codec: .av1)
        }
    }
}

// MARK: - Output format selection

extension NvstVideoToolboxDecoderTests {
    /// A minimal `hvcC` (ISO 14496-15 §8.3.3.1): 22 header bytes, no arrays. Byte 16 is
    /// `chromaFormat`, byte 17 `bitDepthLumaMinus8`, byte 18 `bitDepthChromaMinus8`, each with
    /// the reserved high bits set the way encoders write them.
    private func hvcC(chroma: UInt8, lumaDepthMinus8: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 23)
        bytes[0] = 1
        bytes[1] = 0x02 // Main10 profile idc
        bytes[16] = 0xfc | chroma
        bytes[17] = 0xf8 | lumaDepthMinus8
        bytes[18] = 0xf8 | lumaDepthMinus8
        return Data(bytes)
    }

    @Test func hvcCRecordDeclaresDepthAndChroma() {
        let ten420 = NvstVideoToolboxDecoder.bitstreamFormat(hvcC: hvcC(chroma: 1, lumaDepthMinus8: 2))
        #expect(ten420.bitDepth == 10)
        #expect(ten420.chroma == .yuv420)
        #expect(ten420.isTenBit)
        #expect(ten420.summary == "10-bit 4:2:0")

        let eight444 = NvstVideoToolboxDecoder.bitstreamFormat(hvcC: hvcC(chroma: 3, lumaDepthMinus8: 0))
        #expect(eight444.bitDepth == 8)
        #expect(eight444.chroma == .yuv444)
        #expect(eight444.summary == "8-bit 4:4:4")

        // Too short to carry the depth bytes: the 8-bit 4:2:0 default, never a crash.
        let short = NvstVideoToolboxDecoder.bitstreamFormat(hvcC: Data([1, 2, 3]))
        #expect(short == NvstVideoToolboxDecoder.BitstreamFormat())
    }

    @Test func outputFormatFollowsTheBitstreamAndAlwaysEndsInEightBit420() {
        typealias Format = NvstVideoToolboxDecoder.BitstreamFormat
        let fallback = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        let eight = NvstVideoToolboxDecoder.preferredOutputPixelFormats(for: Format())
        #expect(eight == [fallback])

        let ten = NvstVideoToolboxDecoder.preferredOutputPixelFormats(for: Format(bitDepth: 10, chroma: .yuv420))
        #expect(ten.first == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        #expect(ten.last == fallback)

        let ten444 = NvstVideoToolboxDecoder.preferredOutputPixelFormats(for: Format(bitDepth: 10, chroma: .yuv444))
        #expect(ten444.first == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        // A 4:4:4 surface the decoder cannot produce still keeps the 10 bits before giving them up.
        #expect(ten444.contains(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange))
        #expect(ten444.last == fallback)

        let eight444 = NvstVideoToolboxDecoder.preferredOutputPixelFormats(for: Format(bitDepth: 8, chroma: .yuv444))
        #expect(eight444 == [kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, fallback])
    }

    @Test func pixelFormatNamesAreTheFourCharacterCodes() {
        #expect(NvstVideoToolboxDecoder.pixelFormatName(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) == "xf20")
        #expect(NvstVideoToolboxDecoder.pixelFormatName(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) == "420f")
        #expect(NvstVideoToolboxDecoder.pixelFormatName(0) == "-")
    }

    /// Encodes real 10-bit HEVC and checks the decoder both reads the depth off the parameter sets
    /// and hands back a 10-bit surface — the truncation to NV12 this path used to do is exactly
    /// what this guards against.
    @Test func tenBitHevcDecodesToATenBitSurface() throws {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else { return }
        let units = encodeTenBitHevcAnnexB(frameCount: 2)
        // Every Apple silicon encoder produces Main10; an empty result is a broken test, not a skip.
        try #require(!units.isEmpty)

        final class FormatCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var formats: [OSType] = []
            func append(_ pixelBuffer: CVPixelBuffer) { lock.lock(); formats.append(CVPixelBufferGetPixelFormatType(pixelBuffer)); lock.unlock() }
            var snapshot: [OSType] { lock.lock(); defer { lock.unlock() }; return formats }
        }
        let collector = FormatCollector()
        let decoder = try NvstVideoToolboxDecoder(codec: .hevc)
        decoder.onPixelBuffer = { pixelBuffer, _, _ in collector.append(pixelBuffer) }
        for (index, bytes) in units.enumerated() {
            try decoder.decode(accessUnit(bytes, index: UInt32(index), codec: .hevc))
        }
        decoder.drain()

        #expect(decoder.bitstreamFormat?.bitDepth == 10)
        #expect(decoder.bitstreamFormat?.chroma == .yuv420)
        #expect(decoder.outputPixelFormatName == "xf20")
        let formats = collector.snapshot
        #expect(formats.count == units.count)
        #expect(formats.allSatisfy { $0 == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange })
    }

    /// Main10 HEVC from a P010 source. Returns nothing when the encoder declines 10-bit.
    private func encodeTenBitHevcAnnexB(frameCount: Int) -> [Data] {
        var session: VTCompressionSession?
        let created = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(Self.width),
            height: Int32(Self.height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard created == noErr, let session else { return [] }
        defer { VTCompressionSessionInvalidate(session) }
        guard VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main10_AutoLevel) == noErr else { return [] }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var units: [Data] = []
            func append(_ unit: Data) { lock.lock(); units.append(unit); lock.unlock() }
            var snapshot: [Data] { lock.lock(); defer { lock.unlock() }; return units }
        }
        let sink = Sink()
        for index in 0..<frameCount {
            guard let pixelBuffer = makeTenBitPixelBuffer(fill: UInt16(200 + index * 40)) else { return [] }
            let time = CMTime(value: CMTimeValue(index * 3000), timescale: 90_000)
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: time,
                duration: CMTime(value: 3000, timescale: 90_000),
                frameProperties: nil,
                infoFlagsOut: nil,
                outputHandler: { status, _, sampleBuffer in
                    guard status == noErr, let sampleBuffer, let unit = Self.annexB(from: sampleBuffer) else { return }
                    sink.append(unit)
                }
            )
            guard status == noErr else { return [] }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        return sink.snapshot
    }

    private func makeTenBitPixelBuffer(fill: UInt16) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Self.width, Self.height,
                                  kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                  attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane) / 2
            // P010 keeps its 10 bits in the high bits of each 16-bit sample.
            let value: UInt16 = (plane == 0 ? fill : 512) << 6
            base.withMemoryRebound(to: UInt16.self, capacity: count) { pointer in
                for index in 0..<count { pointer[index] = value }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}

// MARK: - Output latency

extension NvstVideoToolboxDecoderTests {
    /// Does an asynchronously decoded frame come out on its own, or only once the next frame is
    /// submitted? Live sessions (2026-09-05) measured "decode" at almost exactly one frame
    /// interval at every resolution — 8.1 ms at ~122 fps, 9.2–9.4 ms at ~105 fps — which is the
    /// signature of a decoder holding one frame for reordering. A frame that takes 300 ms to
    /// appear here is being held.
    @Test func asynchronousDecodeOutputsWithoutWaitingForTheNextFrame() throws {
        guard VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) else { return }
        let units = encodeAnnexB(codec: kCMVideoCodecType_HEVC, frameCount: 3)
        try #require(units.count == 3)
        final class Arrivals: @unchecked Sendable {
            private let lock = NSLock()
            private var times: [CFTimeInterval] = []
            func note() { lock.lock(); times.append(CACurrentMediaTime()); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return times.count }
        }
        let arrivals = Arrivals()
        let decoder = try NvstVideoToolboxDecoder(codec: .hevc)
        decoder.onPixelBuffer = { _, _, _ in arrivals.note() }

        try decoder.decode(accessUnit(units[0], index: 0, codec: .hevc))
        let submitted = CACurrentMediaTime()
        while arrivals.count < 1, CACurrentMediaTime() - submitted < 0.3 { usleep(1000) }
        let firstAlone = arrivals.count
        let firstLatencyMs = (CACurrentMediaTime() - submitted) * 1000

        try decoder.decode(accessUnit(units[1], index: 1, codec: .hevc))
        let secondSubmitted = CACurrentMediaTime()
        while arrivals.count < 2, CACurrentMediaTime() - secondSubmitted < 0.3 { usleep(1000) }
        let afterSecond = arrivals.count
        decoder.drain()
        print("VT async: first frame alone arrived=\(firstAlone) after \(String(format: "%.1f", firstLatencyMs)) ms; after second submit arrived=\(afterSecond)")
        // The keyframe must come out on its own; if it only shows up once frame 2 is in, every
        // frame of a live stream is delayed by one frame interval before this app ever sees it.
        #expect(firstAlone == 1, "first frame held until the next submit: reorder hold")
        #expect(afterSecond == 2)
    }
}
