import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Host-side H.264 transcoder for a browser guest.
///
/// The seat streams HEVC, which browsers generally cannot decode, so a browser guest is sent an
/// H.264 re-encode of the decoded picture while native guests keep the source stream. One session
/// serves one browser guest and is created only while one is connected, so a native-only session
/// pays nothing for it.
///
/// Output is what WebCodecs wants: an `avcC` record for `VideoDecoder.configure`, then length-prefixed
/// (AVCC) access units — not Annex-B, which is the wire format the native path uses.
public final class RemoteCoOpBrowserVideoTranscoder: @unchecked Sendable {
    public struct AccessUnit: Sendable {
        public let data: Data
        public let isKeyframe: Bool
        public let presentationTime: CMTime
    }

    public enum TranscoderError: LocalizedError, Equatable {
        case sessionCreationFailed(OSStatus)
        case propertyFailed(OSStatus)
        case encodeFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let status): "Could not create the H.264 encoder (status \(status))."
            case .propertyFailed(let status): "Could not configure the H.264 encoder (status \(status))."
            case .encodeFailed(let status): "H.264 encode failed (status \(status))."
            }
        }
    }

    /// The `avcC` record a WebCodecs `VideoDecoder.configure` needs, available once the first
    /// keyframe has produced the parameter sets.
    public private(set) var avcC: Data?
    /// Called on VideoToolbox's callback queue with each encoded access unit.
    public var onAccessUnit: (@Sendable (AccessUnit) -> Void)?

    public let width: Int
    public let height: Int

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var isInvalidated = false

    public init(width: Int, height: Int, fps: Int, averageBitrate: Int) throws {
        self.width = max(2, width)
        self.height = max(2, height)
        var session: VTCompressionSession?
        let encoderSpecification: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        let created = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(self.width),
            height: Int32(self.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: encoderSpecification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard created == noErr, let session else { throw TranscoderError.sessionCreationFailed(created) }
        self.session = session
        var status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        if status == noErr {
            // No reordering: a browser renderer must not wait for a later frame to show this one.
            status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        }
        if status == noErr {
            status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }
        if status == noErr {
            status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        }
        if status == noErr {
            status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: averageBitrate))
        }
        if status == noErr {
            status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2))
        }
        if status == noErr {
            // Belt and braces with the forced keyframes: a periodic IDR even if no source keyframe
            // arrives, so a browser guest that missed its first one always recovers within a couple of
            // seconds.
            status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps * 2))
        }
        guard status == noErr else {
            VTCompressionSessionInvalidate(session)
            self.session = nil
            throw TranscoderError.propertyFailed(status)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    /// Encodes one decoded frame. Throws only on submission failure; the access unit itself arrives
    /// later on `onAccessUnit`. `forceKeyframe` makes this frame an IDR, used to line the transcode's
    /// keyframes up with the source's.
    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool = false) throws {
        lock.lock()
        let session = self.session
        let isValid = !isInvalidated
        lock.unlock()
        guard isValid, let session else { throw TranscoderError.encodeFailed(-1) }
        let frameProperties = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: frameProperties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.emit(sampleBuffer)
        }
        guard status == noErr else { throw TranscoderError.encodeFailed(status) }
    }

    /// Flushes pending frames, then tears the session down.
    public func invalidate() {
        lock.lock()
        guard !isInvalidated, let session else { lock.unlock(); return }
        isInvalidated = true
        self.session = nil
        lock.unlock()
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func emit(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        recordAvcCIfNeeded(from: formatDescription)
        guard let data = Self.avccData(from: blockBuffer) else { return }
        let unit = AccessUnit(data: data,
                              isKeyframe: Self.isKeyframe(sampleBuffer),
                              presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onAccessUnit?(unit)
    }

    private func recordAvcCIfNeeded(from formatDescription: CMFormatDescription) {
        lock.lock()
        let alreadyHave = avcC != nil
        lock.unlock()
        guard !alreadyHave else { return }
        guard let record = Self.avcC(from: formatDescription) else { return }
        lock.lock()
        if avcC == nil { avcC = record }
        lock.unlock()
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// The sample buffer's payload is already AVCC (length-prefixed NAL units) for H.264.
    private static func avccData(from blockBuffer: CMBlockBuffer) -> Data? {
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer, length > 0 else { return nil }
        return Data(bytes: pointer, count: length)
    }

    /// Builds the `AVCDecoderConfigurationRecord` (ISO 14496-15 §5.2.4.1) from the SPS and PPS.
    static func avcC(from formatDescription: CMFormatDescription) -> Data? {
        var sps: UnsafePointer<UInt8>?
        var spsSize = 0
        var pps: UnsafePointer<UInt8>?
        var ppsSize = 0
        var parameterSetCount = 0
        var nalLengthSize: Int32 = 4
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0, parameterSetPointerOut: &sps, parameterSetSizeOut: &spsSize, parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: &nalLengthSize) == noErr,
              CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 1, parameterSetPointerOut: &pps, parameterSetSizeOut: &ppsSize, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
              let sps, let pps, spsSize >= 4, ppsSize > 0 else { return nil }

        var bytes: [UInt8] = []
        bytes.append(1)                 // configurationVersion
        bytes.append(sps[1])            // AVCProfileIndication
        bytes.append(sps[2])            // profile_compatibility
        bytes.append(sps[3])            // AVCLevelIndication
        bytes.append(0xFF)              // lengthSizeMinusOne = 3 (4-byte lengths)
        bytes.append(0xE1)              // numOfSequenceParameterSets = 1
        bytes.append(UInt8((spsSize >> 8) & 0xFF))
        bytes.append(UInt8(spsSize & 0xFF))
        bytes.append(contentsOf: UnsafeBufferPointer(start: sps, count: spsSize))
        bytes.append(1)                 // numOfPictureParameterSets
        bytes.append(UInt8((ppsSize >> 8) & 0xFF))
        bytes.append(UInt8(ppsSize & 0xFF))
        bytes.append(contentsOf: UnsafeBufferPointer(start: pps, count: ppsSize))
        return Data(bytes)
    }
}
