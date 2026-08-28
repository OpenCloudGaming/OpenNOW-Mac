import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware decode for the Bifrost-free NVST video path: Annex-B access units in,
/// `CVPixelBuffer` out.
///
/// The session is (re)built whenever the stream's parameter sets change, which is what a
/// resolution or codec-profile switch looks like on the wire. Parameter sets are cached because
/// only keyframes carry them inline.
public final class NvstVideoToolboxDecoder: @unchecked Sendable {
    public enum DecoderError: LocalizedError, Equatable, Sendable {
        case unsupportedCodec(String)
        case missingParameterSets
        case formatDescriptionFailed(OSStatus)
        case sessionCreationFailed(OSStatus)
        case blockBufferFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case decodeFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unsupportedCodec(let codec): "NVST video codec \(codec) has no VideoToolbox decode path yet."
            case .missingParameterSets: "NVST video stream has not delivered a keyframe with parameter sets yet."
            case .formatDescriptionFailed(let status): "NVST decoder could not build a format description (OSStatus \(status))."
            case .sessionCreationFailed(let status): "NVST decoder could not create a decompression session (OSStatus \(status))."
            case .blockBufferFailed(let status): "NVST decoder could not wrap the access unit (OSStatus \(status))."
            case .sampleBufferFailed(let status): "NVST decoder could not build a sample buffer (OSStatus \(status))."
            case .decodeFailed(let status): "NVST decoder rejected a frame (OSStatus \(status))."
            }
        }
    }

    /// RTP media clock for NVST video.
    public static let clockRate: Int32 = 90_000

    /// Guards the session/format state. Never held across a VideoToolbox call: the output
    /// handler runs on a decode thread and takes `statsLock`, so holding one lock across both
    /// would deadlock against `VTDecompressionSessionWaitForAsynchronousFrames`.
    private let stateLock = NSLock()
    private let statsLock = NSLock()
    private let codec: NVSTVideoCodec
    private var parameterSets = NvstElementaryStream.ParameterSets()
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var decodedFrames: UInt64 = 0
    private var failedFrames: UInt64 = 0
    private var firstFailureStatus: OSStatus = noErr
    private var lastFailureStatus: OSStatus = noErr
    private var loggedFailures = 0
    private var loggedAccepted = 0
    static let maxLoggedAccepted = 6
    static let maxLoggedFailures = 12

    /// Set by the transport so a rejected access unit can describe itself, and so the frame the
    /// decoder could not use can be named back to the seat.
    public var onDecodeFailure: (@Sendable (UInt32, String) -> Void)?

    /// `bytes=N nals=[type:length, …]`, so a rejected access unit can be compared with an accepted
    /// one without a packet capture.
    static func accessUnitShape(_ bytes: Data, codec: NVSTVideoCodec) -> String {
        let buffer = [UInt8](bytes)
        let units = NvstAnnexB.nalUnits(bytes)
        let described = units.prefix(12).map { unit -> String in
            guard unit.offset < buffer.count else { return "?" }
            let header = buffer[unit.offset]
            let type: Int = switch codec {
            case .h264: Int(header & 0x1f)
            case .hevc: Int((header >> 1) & 0x3f)
            case .av1: Int(header)
            }
            let head = buffer[unit.offset..<min(unit.offset + 4, buffer.count)]
                .map { String(format: "%02x", $0) }.joined()
            return "\(type):\(unit.length):\(head)"
        }
        return "bytes=\(bytes.count) nals=[\(described.joined(separator: ", "))]"
    }

    public var onPixelBuffer: (@Sendable (CVPixelBuffer, CMTime, Bool) -> Void)?
    /// Fires on every asynchronous completion, success or failure, in submission order — distinct
    /// from `onPixelBuffer`, which only fires on success. This is what lets a caller match its own
    /// per-submission bookkeeping (a FIFO keyed on submission order) to the frame that bookkeeping
    /// was for, even across a decode failure that `onPixelBuffer` would otherwise skip silently.
    public var onDecodeCompleted: (@Sendable (Bool) -> Void)?

    public init(codec: NVSTVideoCodec) throws {
        guard codec == .h264 || codec == .hevc else {
            throw DecoderError.unsupportedCodec(codec.rawValue)
        }
        self.codec = codec
    }

    public var decodedFrameCount: UInt64 { statsLock.lock(); defer { statsLock.unlock() }; return decodedFrames }
    /// `WIDTHxHEIGHT` of the last decoded frame, or nil before the first one.
    public var decodedResolution: String? {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard decodedWidth > 0, decodedHeight > 0 else { return nil }
        return "\(decodedWidth)x\(decodedHeight)"
    }
    private var decodedWidth = 0
    private var decodedHeight = 0
    public var failedFrameCount: UInt64 { statsLock.lock(); defer { statsLock.unlock() }; return failedFrames }
    /// `first/last` OSStatus of the asynchronous decode failures, or "-" when there were none.
    public var failureStatusSummary: String {
        statsLock.lock()
        defer { statsLock.unlock() }
        guard firstFailureStatus != noErr || lastFailureStatus != noErr else { return "-" }
        return firstFailureStatus == lastFailureStatus ? "\(firstFailureStatus)" : "\(firstFailureStatus)/\(lastFailureStatus)"
    }

    public func invalidate() {
        stateLock.lock()
        let expiring = session
        session = nil
        formatDescription = nil
        parameterSets = NvstElementaryStream.ParameterSets()
        stateLock.unlock()
        Self.tearDown(expiring)
    }

    /// Decodes one access unit. Throws `missingParameterSets` until the first keyframe arrives,
    /// which is the normal state while the seat is still answering the initial PLI.
    public func decode(_ unit: NvstAccessUnit) throws {
        let decodeStart = DispatchTime.now().uptimeNanoseconds
        // One pass produces both the parameter sets and the length-prefixed sample. See
        // `NvstElementaryStream.prepare` for what this replaced.
        let prepared = NvstElementaryStream.prepare(unit.bytes, codec: codec)
        let incoming = prepared.parameterSets

        stateLock.lock()
        var expiring: VTDecompressionSession?
        if incoming.isComplete, incoming != parameterSets {
            parameterSets = incoming
            // New parameter sets mean new stream geometry: rebuild before decoding this frame.
            expiring = session
            session = nil
            formatDescription = nil
        }
        let sets = parameterSets
        var description = formatDescription
        stateLock.unlock()
        Self.tearDown(expiring)

        guard sets.isComplete else { throw DecoderError.missingParameterSets }
        if description == nil {
            description = try makeFormatDescription(sets)
        }
        guard let description else { throw DecoderError.missingParameterSets }

        stateLock.lock()
        formatDescription = description
        var active = session
        stateLock.unlock()
        if active == nil {
            active = try makeSession(formatDescription: description)
            stateLock.lock()
            // Another frame may have installed a session already; keep the first one.
            if let existing = session {
                let redundant = active
                active = existing
                stateLock.unlock()
                Self.tearDown(redundant)
            } else {
                session = active
                stateLock.unlock()
            }
        }
        guard let session = active else { throw DecoderError.sessionCreationFailed(-1) }

        let buildStart = DispatchTime.now().uptimeNanoseconds
        let sample = prepared.sample
        guard !sample.isEmpty else { return }
        let sampleBuffer = try makeSampleBuffer(
            sample: sample,
            formatDescription: description,
            presentationTime: CMTime(value: CMTimeValue(unit.rtpTimestamp), timescale: Self.clockRate)
        )
        let submitStart = DispatchTime.now().uptimeNanoseconds

        var flagsOut = VTDecodeInfoFlags()
        let isKeyframe = unit.isKeyframe
        // Described only when a report is actually going to be emitted. Building it eagerly walked
        // every NAL of every access unit — a per-frame scan of up to 112 KB whose result was thrown
        // away for all but the first handful of frames.
        let bytes = unit.bytes
        let codec = codec
        let shape: @Sendable () -> String = { Self.accessUnitShape(bytes, codec: codec) }
        let logFailure = onDecodeFailure
        let frameIndex = unit.frameIndex
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            // WebRTC's own VideoToolbox decoder (`RTCVideoDecoderH264.mm`, the path the vendored
            // WebRTC-based build uses) sets only `_EnableAsynchronousDecompression`. Temporal
            // processing buffers frames for B-frame reordering — pure added latency on a
            // low-latency cloud-gaming stream that encodes without B-frames.
            flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: &flagsOut,
            outputHandler: { [weak self] status, _, imageBuffer, presentationTime, _ in
                guard let self else { return }
                guard status == noErr, let imageBuffer else {
                    statsLock.lock()
                    failedFrames &+= 1
                    let shouldReport = loggedFailures < Self.maxLoggedFailures
                    if shouldReport { loggedFailures += 1 }
                    // Asynchronous decode reports its reason only here. Counting without it turns
                    // every decoder problem into the same unreadable number.
                    if firstFailureStatus == noErr { firstFailureStatus = status }
                    lastFailureStatus = status
                    statsLock.unlock()
                    if shouldReport {
                        logFailure?(frameIndex, "NVST decode rejected OSStatus \(status) frame=\(frameIndex) keyframe=\(isKeyframe) \(shape())")
                    }
                    onDecodeCompleted?(false)
                    return
                }
                onDecodeCompleted?(true)
                statsLock.lock()
                decodedFrames &+= 1
                // Measured from the decoded surface, not from what the negotiation asked for: a
                // seat that ignores the requested geometry is otherwise invisible here.
                decodedWidth = CVPixelBufferGetWidth(imageBuffer)
                decodedHeight = CVPixelBufferGetHeight(imageBuffer)
                let handler = onPixelBuffer
                let shouldReportAccepted = loggedAccepted < Self.maxLoggedAccepted
                if shouldReportAccepted { loggedAccepted += 1 }
                statsLock.unlock()
                // A rejected unit only means something next to an accepted one.
                if shouldReportAccepted {
                    logFailure?(0, "NVST decode accepted frame=\(frameIndex) keyframe=\(isKeyframe) \(shape())")
                }
                handler?(imageBuffer, presentationTime, isKeyframe)
            }
        )
        noteStageTimings(prepare: decodeStart, build: buildStart, submit: submitStart)
        guard status == noErr else {
            statsLock.lock()
            failedFrames &+= 1
            statsLock.unlock()
            // A rejected frame usually means the session lost its reference chain; force a
            // rebuild so the next keyframe can restart cleanly.
            stateLock.lock()
            let broken = self.session
            self.session = nil
            stateLock.unlock()
            Self.tearDown(broken)
            throw DecoderError.decodeFailed(status)
        }
    }

    /// Where `decode` actually spends its time. `submit` is VideoToolbox itself — it applies
    /// backpressure once its queue is full, so a rising submit time means the decoder, not our
    /// own work, is the limit. `prepare` and `build` are ours: the parameter-set scan and the
    /// Annex-B-to-sample-buffer copy.
    public struct StageTimings: Sendable, Equatable {
        public var prepareMilliseconds = 0.0
        public var buildMilliseconds = 0.0
        public var submitMilliseconds = 0.0
    }

    /// Peaks and means together: a peak names the worst stall, a mean names the steady-state cost
    /// that decides whether the client can keep up with the stream's frame rate at all.
    public var stageTimingSummary: String {
        statsLock.lock()
        defer { statsLock.unlock() }
        let frames = max(1, timedFrames)
        return String(format: "peak[prepare=%.1f build=%.1f submit=%.1f] mean[prepare=%.2f build=%.2f submit=%.2f]ms",
                      peakStages.prepareMilliseconds, peakStages.buildMilliseconds, peakStages.submitMilliseconds,
                      totalStages.prepareMilliseconds / Double(frames),
                      totalStages.buildMilliseconds / Double(frames),
                      totalStages.submitMilliseconds / Double(frames))
    }

    public var peakStageTimings: StageTimings { statsLock.lock(); defer { statsLock.unlock() }; return peakStages }
    private var peakStages = StageTimings()
    private var totalStages = StageTimings()
    private var timedFrames: UInt64 = 0

    private func noteStageTimings(prepare: UInt64, build: UInt64, submit: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let prepareMs = Self.milliseconds(from: prepare, to: build)
        let buildMs = Self.milliseconds(from: build, to: submit)
        let submitMs = Self.milliseconds(from: submit, to: now)
        statsLock.lock()
        peakStages.prepareMilliseconds = max(peakStages.prepareMilliseconds, prepareMs)
        peakStages.buildMilliseconds = max(peakStages.buildMilliseconds, buildMs)
        peakStages.submitMilliseconds = max(peakStages.submitMilliseconds, submitMs)
        totalStages.prepareMilliseconds += prepareMs
        totalStages.buildMilliseconds += buildMs
        totalStages.submitMilliseconds += submitMs
        timedFrames &+= 1
        statsLock.unlock()
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end > start ? Double(end - start) / 1_000_000 : 0
    }

    /// Blocks until the session's queued frames have drained, so it must never run under a lock
    /// the output handler needs.
    public func drain() {
        stateLock.lock()
        let active = session
        stateLock.unlock()
        guard let active else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(active)
    }

    // MARK: - Session

    private static func tearDown(_ session: VTDecompressionSession?) {
        guard let session else { return }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        VTDecompressionSessionInvalidate(session)
    }

    private func makeFormatDescription(_ sets: NvstElementaryStream.ParameterSets) throws -> CMVideoFormatDescription {
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
        return description
    }

    private func makeSession(formatDescription: CMVideoFormatDescription) throws -> VTDecompressionSession {
        // Ask for a full-range 4:2:0 biplanar surface backed by an IOSurface so the Metal
        // renderer can bind it without a copy.
        //
        // Tried requesting 10-bit output directly (2026-08-28) on the theory that VideoToolbox
        // truncating every 10-bit-negotiated frame (`color=10bit_420`, confirmed in
        // `OPNSessionManager` logs) down to 8-bit here was adding real per-frame cost — measured
        // decode mean was unchanged (7.74-7.75ms, identical to the 8-bit baseline), so the
        // truncation isn't the cost. Reverted rather than carry the downstream rendering risk
        // (this codebase's Metal path assumes 8-bit NV12 semantics) for no benefit.
        // Tried a pixel-buffer-pool-depth hint (`kCVPixelBufferPoolMinimumBufferCountKey`, 6
        // buffers) on 2026-08-28 to rule out decode completion stalling on a buffer the renderer
        // was still holding — measured decode mean unchanged (7.72ms, identical to no hint), so
        // pool starvation isn't the cost either. Reverted.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        // Ask for hardware explicitly rather than taking the default. VideoToolbox will fall back to
        // a software decoder without saying so, and a software HEVC decode at 5120x2160 cannot hold
        // 120 fps — which is indistinguishable, from the outside, from "decode is slow".
        let specification: [CFString: Any] = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ]
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &created
        )
        guard status == noErr, let created else { throw DecoderError.sessionCreationFailed(status) }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // And then verify it, because asking is not getting.
        var usingHardware: Unmanaged<CFTypeRef>?
        VTSessionCopyProperty(created,
                              key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: kCFAllocatorDefault,
                              valueOut: &usingHardware)
        let isHardware = (usingHardware?.takeRetainedValue() as? NSNumber)?.boolValue ?? false
        statsLock.lock()
        usesHardwareDecoder = isHardware
        statsLock.unlock()
        onDecodeFailure?(0, "NVST decoder session created codec=\(codec.rawValue) hardware=\(isHardware)")
        // Creating a hardware decompression session costs hundreds of milliseconds, and it happens
        // on the frame path — so a rebuild storm reads as random latency spikes. Counted so a spike
        // can be attributed to it instead of guessed at.
        statsLock.lock()
        sessionsCreated &+= 1
        statsLock.unlock()
        return created
    }

    /// How many decompression sessions this decoder has built. One per session is normal; more
    /// means the session is being torn down and rebuilt mid-stream.
    public var sessionCreationCount: UInt64 { statsLock.lock(); defer { statsLock.unlock() }; return sessionsCreated }
    /// Whether VideoToolbox actually gave us the hardware decoder.
    public var isHardwareAccelerated: Bool { statsLock.lock(); defer { statsLock.unlock() }; return usesHardwareDecoder }
    private var usesHardwareDecoder = false
    private var sessionsCreated: UInt64 = 0

    private func makeSampleBuffer(sample: Data,
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
}
