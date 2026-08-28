import AudioToolbox
import Foundation

/// Decodes the seat's Opus audio to interleaved 32-bit float PCM.
///
/// macOS decodes Opus itself — `kAudioFormatOpus` is in `AudioFormatGetProperty`'s decodable list
/// and an `AudioConverter` from Opus to float PCM builds cleanly — so nothing has to be vendored
/// for this.
///
/// The seat sends 48 kHz stereo in 5 ms frames — a measured RTP timestamp step of 240 at ~200
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
    public static let channels: UInt32 = 2

    private let converter: AudioConverterRef
    private let lock = NSLock()
    private var output: [Float]

    public private(set) var decodedPackets: UInt64 = 0
    public private(set) var decodedFrames: UInt64 = 0
    public private(set) var failedPackets: UInt64 = 0
    public private(set) var lastFailure: OSStatus = 0
    /// Frames produced per packet, which is how the seat's real frame duration is observed rather
    /// than assumed.
    public private(set) var framesPerPacketSeen: [Int: UInt64] = [:]

    /// RFC 7845's identification header: magic, version, channel count, pre-skip, input sample
    /// rate, output gain, channel-mapping family.
    static func opusHeadCookie(channels: UInt8, sampleRate: UInt32) -> Data {
        var cookie = Data("OpusHead".utf8)
        cookie.append(1)
        cookie.append(channels)
        cookie.append(contentsOf: [0, 0])
        for shift in stride(from: 0, through: 24, by: 8) {
            cookie.append(UInt8(truncatingIfNeeded: sampleRate >> UInt32(shift)))
        }
        cookie.append(contentsOf: [0, 0])
        cookie.append(0)
        return cookie
    }

    public let framesPerPacket: Int

    /// - Parameter framesPerPacket: samples per channel in each packet — the stream's RTP timestamp
    ///   step. 240 is 5 ms at 48 kHz, which is what the seat sends.
    public init(framesPerPacket: Int = 240) throws {
        self.framesPerPacket = framesPerPacket
        var source = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: Self.channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var destination = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * Self.channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * Self.channels,
            mChannelsPerFrame: Self.channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var created: AudioConverterRef?
        let status = AudioConverterNew(&source, &destination, &created)
        guard status == noErr, let created else { throw DecoderError.converterUnavailable(status) }
        converter = created

        // Without an `OpusHead` magic cookie the decoder rejects every packet with 'bada'
        // (`kAudioCodecBadDataError`) — including packets that reference libopus decodes without a
        // single error. Nothing in the AudioToolbox headers says a cookie is required; it simply is.
        let cookie = Self.opusHeadCookie(channels: UInt8(Self.channels), sampleRate: UInt32(Self.sampleRate))
        let cookieStatus = cookie.withUnsafeBytes { raw in
            AudioConverterSetProperty(created, kAudioConverterDecompressionMagicCookie,
                                      UInt32(raw.count), raw.baseAddress!)
        }
        guard cookieStatus == noErr else {
            AudioConverterDispose(created)
            throw DecoderError.converterUnavailable(cookieStatus)
        }
        output = [Float](repeating: 0, count: max(framesPerPacket, 1) * Int(Self.channels))
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
    private final class Queue {
        var packets: [Data] = []
        var description = AudioStreamPacketDescription()
        let scratch: UnsafeMutablePointer<UInt8>
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        }

        deinit { scratch.deallocate() }
    }

    /// An Opus packet cannot exceed 1275 bytes per frame; the seat's measure about 51.
    private let queue = Queue(capacity: 4096)

    /// Decodes one Opus packet, returning whatever interleaved stereo float samples became
    /// available. Early packets can legitimately yield nothing while the decoder fills.
    public func decode(_ packet: Data) throws -> [Float]? {
        guard !packet.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

        queue.packets.append(packet)
        var produced: [Float] = []

        while true {
            var frames = UInt32(framesPerPacket)
            var status: OSStatus = noErr
            output.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: Self.channels,
                        mDataByteSize: UInt32(buffer.count * 4),
                        mData: buffer.baseAddress
                    )
                )
                status = AudioConverterFillComplexBuffer(
                    converter,
                    { _, packetCount, data, descriptions, context in
                        let queue = Unmanaged<Queue>.fromOpaque(context!).takeUnretainedValue()
                        guard !queue.packets.isEmpty else {
                            packetCount.pointee = 0
                            return NvstOpusDecoder.noDataAvailable
                        }
                        let next = queue.packets.removeFirst()
                        let count = min(next.count, queue.capacity)
                        next.copyBytes(to: queue.scratch, count: count)
                        queue.description = AudioStreamPacketDescription(
                            mStartOffset: 0,
                            mVariableFramesInPacket: 0,
                            mDataByteSize: UInt32(count)
                        )
                        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(queue.scratch)
                        data.pointee.mBuffers.mDataByteSize = UInt32(count)
                        data.pointee.mBuffers.mNumberChannels = NvstOpusDecoder.channels
                        data.pointee.mNumberBuffers = 1
                        descriptions?.pointee = withUnsafeMutablePointer(to: &queue.description) { $0 }
                        packetCount.pointee = 1
                        return noErr
                    },
                    Unmanaged.passUnretained(queue).toOpaque(),
                    &frames,
                    &list,
                    nil
                )
            }
            if frames > 0 {
                decodedPackets += 1
                decodedFrames += UInt64(frames)
                framesPerPacketSeen[Int(frames), default: 0] += 1
                produced.append(contentsOf: output[0..<(Int(frames) * Int(Self.channels))])
            }
            if status == Self.noDataAvailable { break }
            if status != noErr {
                failedPackets += 1
                lastFailure = status
                break
            }
            if frames == 0 { break }
        }
        return produced.isEmpty ? nil : produced
    }

    public var framesPerPacketSummary: String {
        lock.lock()
        defer { lock.unlock() }
        return framesPerPacketSeen.sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key)x\($0.value)" }
            .joined(separator: ",")
    }
}
