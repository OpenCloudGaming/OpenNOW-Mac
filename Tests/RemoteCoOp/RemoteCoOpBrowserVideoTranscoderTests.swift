import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
@testable import OpenNOW

/// Counts decoded frames from the decompression session's C callback.
private final class BrowserDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

private let browserDecoderOutput: VTDecompressionOutputCallback = { refcon, _, status, _, imageBuffer, _, _ in
    guard status == noErr, imageBuffer != nil, let refcon else { return }
    Unmanaged<BrowserDecodeCounter>.fromOpaque(refcon).takeUnretainedValue().increment()
}

/// The browser guest is sent an H.264 re-encode of the decoded picture, framed the way WebCodecs
/// needs it: an `avcC` record plus length-prefixed (AVCC) access units. This proves a real decoder can
/// read that output, so the browser-boundary format is right before any network code exists.
@Suite(.serialized) struct RemoteCoOpBrowserVideoTranscoderTests {
    private static let width = 320
    private static let height = 240

    private final class UnitCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var units: [RemoteCoOpBrowserVideoTranscoder.AccessUnit] = []
        func append(_ unit: RemoteCoOpBrowserVideoTranscoder.AccessUnit) { lock.lock(); units.append(unit); lock.unlock() }
        var snapshot: [RemoteCoOpBrowserVideoTranscoder.AccessUnit] { lock.lock(); defer { lock.unlock() }; return units }
    }

    private func makePixelBuffer(fill: UInt8) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
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

    @Test func transcodedFramesDecodeAtTheBrowserBoundary() throws {
        let transcoder = try RemoteCoOpBrowserVideoTranscoder(width: Self.width, height: Self.height, fps: 30, averageBitrate: 1_500_000)
        let collector = UnitCollector()
        transcoder.onAccessUnit = { collector.append($0) }

        for index in 0..<6 {
            let buffer = try #require(makePixelBuffer(fill: UInt8(30 + index * 20)))
            try transcoder.encode(buffer, presentationTime: CMTime(value: CMTimeValue(index * 3000), timescale: 90_000))
        }
        transcoder.invalidate()

        let deadline = Date().addingTimeInterval(3)
        while collector.snapshot.isEmpty, Date() < deadline { usleep(5_000) }
        let units = collector.snapshot
        try #require(!units.isEmpty, "the transcoder produced no access units")

        let avcC = try #require(transcoder.avcC, "no avcC record was produced")

        // Decode with a real VTDecompressionSession, the same boundary a browser's VideoDecoder sits at.
        let description = try Self.formatDescription(fromAvcC: avcC)
        let decoded = try Self.decode(units: units, formatDescription: description)

        #expect(decoded >= 1, "no frame decoded from \(units.count) transcoded units")
        #expect(units.contains { $0.isKeyframe }, "no keyframe was emitted")
    }

    /// A source keyframe must be able to force a transcode keyframe, so a browser guest that missed
    /// the encoder's very first IDR can still start.
    @Test func aForcedKeyframeIsEmitted() throws {
        let transcoder = try RemoteCoOpBrowserVideoTranscoder(width: Self.width, height: Self.height, fps: 30, averageBitrate: 1_500_000)
        let collector = UnitCollector()
        transcoder.onAccessUnit = { collector.append($0) }

        for index in 0..<4 {
            let buffer = try #require(makePixelBuffer(fill: UInt8(30 + index * 20)))
            try transcoder.encode(buffer, presentationTime: CMTime(value: CMTimeValue(index * 3000), timescale: 90_000))
        }
        let forced = try #require(makePixelBuffer(fill: 220))
        try transcoder.encode(forced, presentationTime: CMTime(value: 12_000, timescale: 90_000), forceKeyframe: true)
        transcoder.invalidate()

        let deadline = Date().addingTimeInterval(3)
        while collector.snapshot.count < 5, Date() < deadline { usleep(5_000) }
        let units = collector.snapshot
        #expect(units.count >= 5)
        #expect(units.last?.isKeyframe == true, "the forced frame was not emitted as a keyframe")
    }

    @Test func aLargeSessionUsesTheRequestedDimensions() throws {        let transcoder = try RemoteCoOpBrowserVideoTranscoder(width: 1280, height: 720, fps: 60, averageBitrate: 8_000_000)
        #expect(transcoder.width == 1280)
        #expect(transcoder.height == 720)
        transcoder.invalidate()
    }

    // MARK: - Helpers

    private static func formatDescription(fromAvcC avcC: Data) throws -> CMFormatDescription {
        let (sps, pps) = try parameterSets(fromAvcC: avcC)
        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw -> OSStatus in
            pps.withUnsafeBytes { ppsRaw -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsRaw.bindMemory(to: UInt8.self).baseAddress!,
                    ppsRaw.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes: [Int] = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }
        guard status == noErr, let description else { throw NSError(domain: "transcoder", code: Int(status)) }
        return description
    }

    private static func parameterSets(fromAvcC avcC: Data) throws -> (sps: Data, pps: Data) {
        let bytes = [UInt8](avcC)
        guard bytes.count > 7, bytes[0] == 1 else { throw NSError(domain: "transcoder", code: 1) }
        var offset = 5
        let spsCount = Int(bytes[offset] & 0x1F); offset += 1
        guard spsCount >= 1 else { throw NSError(domain: "transcoder", code: 2) }
        let spsLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]); offset += 2
        let sps = Data(bytes[offset..<offset + spsLength]); offset += spsLength
        let ppsCount = Int(bytes[offset]); offset += 1
        guard ppsCount >= 1 else { throw NSError(domain: "transcoder", code: 3) }
        let ppsLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1]); offset += 2
        let pps = Data(bytes[offset..<offset + ppsLength])
        return (sps, pps)
    }

    private static func decode(units: [RemoteCoOpBrowserVideoTranscoder.AccessUnit],
                               formatDescription: CMFormatDescription) throws -> Int {
        let counter = BrowserDecodeCounter()
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: browserDecoderOutput,
            decompressionOutputRefCon: Unmanaged.passUnretained(counter).toOpaque()
        )
        var session: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: &record,
            decompressionSessionOut: &session
        )
        guard created == noErr, let session else { throw NSError(domain: "transcoder", code: Int(created)) }
        defer { VTDecompressionSessionInvalidate(session) }

        for unit in units {
            guard let sampleBuffer = makeSampleBuffer(unit: unit, formatDescription: formatDescription) else { continue }
            _ = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sampleBuffer,
                flags: [._EnableAsynchronousDecompression],
                frameRefcon: nil,
                infoFlagsOut: nil
            )
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return counter.count
    }

    private static func makeSampleBuffer(unit: RemoteCoOpBrowserVideoTranscoder.AccessUnit,
                                         formatDescription: CMFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let data = unit.data
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let blockBuffer else { return nil }
        data.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
        }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: unit.presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }
}
