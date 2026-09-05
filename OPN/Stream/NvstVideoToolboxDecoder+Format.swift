//  What the bitstream declares about itself and which output surface to ask VideoToolbox for.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

extension NvstVideoToolboxDecoder {

    /// What the bitstream's parameter sets declare about sample depth and chroma layout. Read from
    /// the `hvcC` record VideoToolbox builds out of the SPS, so it is the decoder's own view of the
    /// stream rather than what the session negotiation asked for.
    public struct BitstreamFormat: Equatable, Sendable {
        public enum Chroma: Int, Sendable {
            case monochrome = 0
            case yuv420 = 1
            case yuv422 = 2
            case yuv444 = 3
        }
        public var bitDepth = 8
        public var chroma = Chroma.yuv420

        public var isTenBit: Bool { bitDepth > 8 }
        public var summary: String {
            let layout: String = switch chroma {
            case .monochrome: "4:0:0"
            case .yuv420: "4:2:0"
            case .yuv422: "4:2:2"
            case .yuv444: "4:4:4"
            }
            return "\(bitDepth)-bit \(layout)"
        }
    }

    /// Reads depth and chroma layout out of the HEVC decoder configuration record (`hvcC`, ISO
    /// 14496-15 §8.3.3.1): byte 16 carries `chromaFormat` in its low two bits and byte 17
    /// `bitDepthLumaMinus8` in its low three. H.264 sessions on this service are 8-bit 4:2:0 —
    /// the 10-bit and 4:4:4 tiers are only offered on HEVC and AV1 — so `avcC` is not parsed.
    static func bitstreamFormat(from description: CMFormatDescription, codec: NVSTVideoCodec) -> BitstreamFormat {
        guard codec == .hevc,
              let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
              let record = atoms["hvcC"] as? Data else {
            return BitstreamFormat()
        }
        return bitstreamFormat(hvcC: record)
    }

    static func bitstreamFormat(hvcC record: Data) -> BitstreamFormat {
        guard record.count >= 19 else { return BitstreamFormat() }
        let bytes = [UInt8](record)
        var format = BitstreamFormat()
        format.chroma = BitstreamFormat.Chroma(rawValue: Int(bytes[16] & 0x3)) ?? .yuv420
        format.bitDepth = 8 + Int(bytes[17] & 0x7)
        return format
    }

    /// The `CVPixelBuffer` formats to ask VideoToolbox for, best first. Every entry is full range
    /// and bi-planar: the Metal path samples luma and interleaved chroma as two textures with the
    /// same normalised coordinates, so 4:2:2 and 4:4:4 chroma planes of any size bind unchanged,
    /// and full range is what the YCbCr shaders assume. A 10-bit stream asks for the matching
    /// 10-bit surface so the decoder no longer truncates every frame to 8 bits before the renderer
    /// sees it. The 8-bit 4:2:0 surface is always the last resort, because VideoToolbox will
    /// convert down to it from anything.
    static func preferredOutputPixelFormats(for format: BitstreamFormat) -> [OSType] {
        let fallback = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        var preferred: [OSType] = []
        switch (format.chroma, format.isTenBit) {
        case (.yuv444, true): preferred = [kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
        case (.yuv444, false): preferred = [kCVPixelFormatType_444YpCbCr8BiPlanarFullRange]
        case (.yuv422, true): preferred = [kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
        case (.yuv422, false): preferred = [kCVPixelFormatType_422YpCbCr8BiPlanarFullRange]
        case (_, true): preferred = [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
        default: preferred = []
        }
        return preferred + [fallback]
    }

    static func pixelFormatName(_ format: OSType) -> String {
        guard format != 0 else { return "-" }
        let bytes = [UInt8((format >> 24) & 0xff), UInt8((format >> 16) & 0xff), UInt8((format >> 8) & 0xff), UInt8(format & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", format)
    }

    func makeFormatDescription(_ sets: NvstElementaryStream.ParameterSets) throws -> CMVideoFormatDescription {
        let ordered = sets.ordered
        guard !ordered.isEmpty else { throw DecoderError.missingParameterSets }
        // One contiguous allocation so the pointer array stays valid for the whole call;
        // taking addresses out of per-element `withUnsafeBufferPointer` closures would dangle.
        let sizes = ordered.map(\.count)
        let total = sizes.reduce(0, +)
        let storage = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: total)
        defer { storage.deallocate() }
        var offset = 0
        var pointers: [UnsafePointer<UInt8>] = []
        for set in ordered {
            set.copyBytes(to: storage.baseAddress!.advanced(by: offset), count: set.count)
            pointers.append(UnsafePointer(storage.baseAddress!.advanced(by: offset)))
            offset += set.count
        }

        var description: CMFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in
                switch codec {
                case .hevc:
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                default:
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: pointerBuffer.count,
                        parameterSetPointers: pointerBuffer.baseAddress!,
                        parameterSetSizes: sizeBuffer.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &description
                    )
                }
            }
        }
        guard status == noErr, let description else { throw DecoderError.formatDescriptionFailed(status) }
        let format = Self.bitstreamFormat(from: description, codec: codec)
        statsLock.lock()
        currentBitstreamFormat = format
        statsLock.unlock()
        // The seat's parameter sets, verbatim, once per format description. Whether the decoder
        // may hold frames for reordering is written in the SPS (`sps_max_num_reorder_pics`, and
        // the VUI's bitstream restriction), and that decides how long a decoded frame waits inside
        // VideoToolbox before this app sees it.
        let hex = sets.ordered.map { data in data.map { String(format: "%02x", $0) }.joined() }.joined(separator: " ")
        onDecodeFailure?(0, "NVST parameter sets \(format.summary): \(hex)")
        return description
    }

    func makeSampleBuffer(sample: Data,
                                  formatDescription: CMVideoFormatDescription,
                                  presentationTime: CMTime) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        // The sample is already a contiguous `Data`; copying it into an `[UInt8]` first was a whole
        // extra pass over a 5K access unit for nothing. `CMBlockBufferReplaceDataBytes` copies from
        // whatever pointer it is given.
        let sampleCount = sample.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw DecoderError.blockBufferFailed(status) }
        status = sample.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: sampleCount)
        }
        guard status == noErr else { throw DecoderError.blockBufferFailed(status) }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = sampleCount
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw DecoderError.sampleBufferFailed(status) }
        return sampleBuffer
    }

    static func tearDown(_ session: VTDecompressionSession?) {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000 : 0
    }
}
