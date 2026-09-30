import AudioToolbox
import Foundation

/// Decodes the seat's Opus audio to interleaved 32-bit float PCM.
///
/// macOS decodes Opus itself — `kAudioFormatOpus` is in `AudioFormatGetProperty`'s decodable list
/// and an `AudioConverter` from Opus to float PCM builds cleanly — so nothing has to be vendored
/// for this.
///
/// The seat sends 48 kHz stereo, or multistream surround, in 5 ms frames — a measured RTP timestamp step of 240 at ~200
/// packets a second — and that step is exactly the frame count, so it is passed in rather than
/// guessed.
///
/// The frame count has to be exact. `AudioConverterFillComplexBuffer` treats an input callback
/// that supplies no packet as end-of-stream and latches: asking for more frames than one packet
/// holds decodes the first packet and then returns nothing for every packet after it. Requesting
/// precisely one packet's worth means the callback is never asked past what it has.
public final class NvstOpusDecoder: @unchecked Sendable {
    public enum DecoderError: LocalizedError, Equatable, Sendable {
        case converterUnavailable(OSStatus)
        case decodeFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .converterUnavailable(let status): "Could not create an Opus decoder (status \(status))."
            case .decodeFailed(let status): "Opus decode failed (status \(status))."
            }
        }
    }

    public static let sampleRate: Double = 48000

    /// The seat's game audio frame: 5 ms at 48 kHz, which is the `x-nv-aqos.packetDuration:5` the
    /// session negotiates and the RTP timestamp step measured on the wire.
    public static let seatFramesPerPacket = 240

    /// Packets a decoder may consume without producing a single frame before the layout is judged
    /// undecodable here. Opus has a priming delay, so the first packets legitimately produce
    /// nothing; 20 packets is 100 ms, which is short enough to be heard as a click rather than as
    /// silence.
    public static let unproductivePacketLimit = 20

    /// Whether this macOS can build a decoder for `layout` at all.
    ///
    /// A multistream (RFC 7845 channel-mapping family 1) `OpusHead` is not accepted everywhere the
    /// app runs: on macOS 15–26 `AudioConverterNew` refuses the six-channel stream format and the
    /// cookie is rejected with `kAudioConverterErr_FormatNotSupported` (`fmt?`), and the same build
    /// succeeds on macOS 27. The seat's offer is therefore no evidence that the audio can be
    /// decoded here, and the layout a session negotiates is gated on this probe rather than on the
    /// negotiated count alone. See `NvstOpusMultistreamLayout.negotiated`.
    public static func canDecode(layout: NvstOpusMultistreamLayout,
                                 framesPerPacket: Int = seatFramesPerPacket) -> Bool {
        guard layout.isSurround else { return true }
        guard let converter = try? makeConverter(layout: layout, framesPerPacket: framesPerPacket) else { return false }
        AudioConverterDispose(converter)
        return true
    }

    /// The converter for `layout`, with the `OpusHead` magic cookie already set, or the status that
    /// refused it. Split out of `init` so `canDecode` can ask the same question the decoder answers.
    private static func makeConverter(layout: NvstOpusMultistreamLayout,
                                      framesPerPacket: Int) throws -> AudioConverterRef {
        let channels = UInt32(layout.channels)
        var source = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var destination = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var created: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &created)
        guard status == noErr, let created else { throw DecoderError.converterUnavailable(status) }

        // Without an `OpusHead` magic cookie the decoder rejects every packet with 'bada'
        // (`kAudioCodecBadDataError`) — including packets that reference libopus decodes without a
        // single error. Nothing in the AudioToolbox headers says a cookie is required; it simply is.
        let cookie = opusHeadCookie(layout: layout, sampleRate: UInt32(sampleRate))
        let cookieStatus = cookie.withUnsafeBytes { raw in
            AudioConverterSetProperty(created, kAudioConverterDecompressionMagicCookie,
                                      UInt32(raw.count), raw.baseAddress!)
        }
        guard cookieStatus == noErr else {
            AudioConverterDispose(created)
            throw DecoderError.converterUnavailable(cookieStatus)
        }
        return created
    }

    private let converter: AudioConverterRef
    let lock = NSLock()
    private var output: [Float]

    private var decodedPacketCount: UInt64 = 0
    private var decodedFrameCount: UInt64 = 0
    private var failedPacketCount: UInt64 = 0
    private var oversizedPacketCount: UInt64 = 0
    private var lastFailureStatus: OSStatus = 0
    /// Frames produced per packet, which is how the seat's real frame duration is observed rather
    /// than assumed.
    private var framesPerPacketCounts: [Int: UInt64] = [:]

    /// Every counter is written under `lock` on the decode queue and read from telemetry threads,
    /// so the reads take the lock too.
    public var decodedPackets: UInt64 { lock.lock(); defer { lock.unlock() }; return decodedPacketCount }
    public var decodedFrames: UInt64 { lock.lock(); defer { lock.unlock() }; return decodedFrameCount }
    public var failedPackets: UInt64 { lock.lock(); defer { lock.unlock() }; return failedPacketCount }
    public var oversizedPackets: UInt64 { lock.lock(); defer { lock.unlock() }; return oversizedPacketCount }
    public var lastFailure: OSStatus { lock.lock(); defer { lock.unlock() }; return lastFailureStatus }
    public var framesPerPacketSeen: [Int: UInt64] { lock.lock(); defer { lock.unlock() }; return framesPerPacketCounts }

    /// True once this decoder has consumed `unproductivePacketLimit` packets without producing a
    /// single frame. That is what a family 1 decoder does when the seat described a surround layout
    /// and then sent stereo — it rejects every packet with 'bada' — and it is also what an accepted
    /// but unusable cookie looks like, so the two need no separate handling.
    public var hasProducedNoAudio: Bool {
        lock.lock()
        defer { lock.unlock() }
        return decodedFrameCount == 0 && decodedPacketCount >= Self.unproductivePacketLimit
    }

    /// RFC 7845's identification header: magic, version, channel count, pre-skip, input sample
    /// rate, output gain, channel-mapping family, and for family 1 the stream table.
    static func opusHeadCookie(layout: NvstOpusMultistreamLayout, sampleRate: UInt32) -> Data {
        var writer = NvstByteWriter(capacity: 21 + layout.mapping.count)
        writer.bytes(Data("OpusHead".utf8))
        writer.u8(1)
        writer.u8(UInt8(clamping: layout.channels))
        writer.zeroes(2)
        writer.u32LE(sampleRate)
        writer.zeroes(2)
        guard layout.isSurround else {
            writer.u8(0)
            return writer.data
        }
        writer.u8(1)
        writer.u8(UInt8(clamping: layout.streams))
        writer.u8(UInt8(clamping: layout.coupledStreams))
        writer.bytes(Data(layout.mapping))
        return writer.data
    }

    public let framesPerPacket: Int
    public let layout: NvstOpusMultistreamLayout
    public var channels: Int { layout.channels }

    /// - Parameter framesPerPacket: samples per channel in each packet — the stream's RTP timestamp
    ///   step. `seatFramesPerPacket` is 5 ms at 48 kHz, which is what the seat sends.
    public init(framesPerPacket: Int = NvstOpusDecoder.seatFramesPerPacket,
                layout: NvstOpusMultistreamLayout = .stereo) throws {
        self.framesPerPacket = framesPerPacket
        self.layout = layout
        converter = try Self.makeConverter(layout: layout, framesPerPacket: framesPerPacket)
        output = [Float](repeating: 0, count: max(framesPerPacket, 1) * layout.channels)
        queue = Queue(capacity: 4096, channels: UInt32(layout.channels))
    }

    deinit { AudioConverterDispose(converter) }

    /// Returned by the input callback when the queue is dry. `AudioConverterFillComplexBuffer`
    /// treats a callback that supplies no packet *and reports success* as end-of-stream and latches
    /// — every later packet then decodes to nothing. Reporting an error instead leaves the
    /// converter's state intact, so the next packet resumes the stream. Opus also has a decoder
    /// delay, so producing one packet's worth of output genuinely needs more than one packet in
    /// hand; the callback being asked twice is normal, not a fault.
    static let noDataAvailable: OSStatus = -13579

    /// Holds packets waiting to be decoded, plus a stable buffer to hand the converter.
    ///
    /// The buffer matters: the converter keeps the pointer it is given until it is finished with
    /// the packet, so it cannot point into a `Data` whose storage the queue may move. Copying into
    /// an allocation the queue owns also lets each invocation consume exactly one packet — an
    /// earlier version removed the head and immediately re-inserted it, which happened to work only
    /// because the converter never asked twice within one call.
    final class Queue {
        var packets: [Data] = []
        var consumedPackets: UInt64 = 0
        let channels: UInt32
        /// The converter keeps this pointer for the whole fill, so it must outlive the input
        /// callback: a dedicated allocation instead of a pointer into a closure scope.
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        let scratch: UnsafeMutablePointer<UInt8>
        let capacity: Int

        init(capacity: Int, channels: UInt32) {
            self.capacity = capacity
            self.channels = channels
            scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        }

        deinit {
            scratch.deallocate()
            description.deallocate()
        }
    }

    /// An Opus packet cannot exceed 1275 bytes per frame and stream; the seat's measure about 51 in
    /// stereo and about 520 in 5.1.
    let queue: Queue

    /// Hands the converter the next queued packet. Static so it is not rebuilt on every call and
    /// `decode` stays readable; `context` is the unretained `Queue`.
    private static let inputProc: AudioConverterComplexInputDataProc = { _, packetCount, data, descriptions, context in
        let queue = Unmanaged<Queue>.fromOpaque(context!).takeUnretainedValue()
        guard !queue.packets.isEmpty else {
            packetCount.pointee = 0
            return NvstOpusDecoder.noDataAvailable
        }
        let next = queue.packets.removeFirst()
        queue.consumedPackets += 1
        let count = next.count
        next.copyBytes(to: queue.scratch, count: count)
        queue.description.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(count)
        )
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(queue.scratch)
        data.pointee.mBuffers.mDataByteSize = UInt32(count)
        data.pointee.mBuffers.mNumberChannels = queue.channels
        data.pointee.mNumberBuffers = 1
        descriptions?.pointee = queue.description
        packetCount.pointee = 1
        return noErr
    }

    /// One converter pass into `output`. `frames` is in-out: capacity in, frames produced out.
    /// The caller already holds `lock`.
    private func fillLocked(frames: inout UInt32) -> OSStatus {
        var status: OSStatus = noErr
        output.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(layout.channels),
                    mDataByteSize: UInt32(buffer.count * 4),
                    mData: buffer.baseAddress
                )
            )
            status = AudioConverterFillComplexBuffer(
                converter,
                Self.inputProc,
                Unmanaged.passUnretained(queue).toOpaque(),
                &frames,
                &list,
                nil
            )
        }
        return status
    }

    /// Decodes one Opus packet, returning whatever interleaved float samples became
    /// available. Early packets can legitimately yield nothing while the decoder fills.
    public func decode(_ packet: Data) throws -> [Float]? {
        guard !packet.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        // Truncating to fit the scratch buffer would hand the decoder garbage. Nothing this stream
        // sends approaches the capacity — the seat's packets measure ~51 bytes — so a packet this
        // big is dropped and counted rather than mangled.
        guard packet.count <= queue.capacity else {
            oversizedPacketCount += 1
            return nil
        }

        let consumedBefore = queue.consumedPackets
        queue.packets.append(packet)
        var produced: [Float] = []

        while true {
            var frames = UInt32(framesPerPacket)
            let status = fillLocked(frames: &frames)
            if frames > 0 {
                decodedFrameCount += UInt64(frames)
                framesPerPacketCounts[Int(frames), default: 0] += 1
                produced.append(contentsOf: output[0..<(Int(frames) * layout.channels)])
            }
            if status == Self.noDataAvailable { break }
            if status != noErr {
                failedPacketCount += 1
                lastFailureStatus = status
                break
            }
            if frames == 0 { break }
        }
        // Count what the converter actually consumed. With the decoder's priming delay, counting
        // output chunks instead lags the input by a packet.
        decodedPacketCount += queue.consumedPackets - consumedBefore
        return produced.isEmpty ? nil : produced
    }

    public var framesPerPacketSummary: String {
        lock.lock()
        defer { lock.unlock() }
        // The storage directly, not `framesPerPacketSeen`: that accessor takes `lock` too, and
        // `NSLock` is not recursive, so going through it deadlocks this thread with the lock held.
        return framesPerPacketCounts.sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key)x\($0.value)" }
            .joined(separator: ",")
    }
}

/// What the receive pipeline needs from an Opus decoder: PCM, and enough about the decoder's own
/// health to tell a layout it cannot decode from a stream that is merely quiet.
///
/// `NvstOpusDecoder` is the only implementation that ships. The seam exists because the fallback it
/// feeds cannot otherwise be exercised on a macOS whose Opus decoder has no multistream support:
/// there, the surround decoder such a test would need cannot be built in the first place.
protocol NvstOpusDecoding: AnyObject, Sendable {
    /// Packets the decoder rejected. A family 1 decoder rejects every packet with 'bada' when the
    /// seat sends stereo, and it reports that through this counter rather than by throwing.
    var failedPackets: UInt64 { get }
    /// True once the decoder has consumed enough packets without producing a single frame that the
    /// layout it was built for is the only remaining explanation.
    var hasProducedNoAudio: Bool { get }
    func decode(_ packet: Data) throws -> [Float]?
}

extension NvstOpusDecoder: NvstOpusDecoding {}
