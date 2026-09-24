import Foundation

/// The audio half of the native Co-Op transport: the host's decoded game audio (48 kHz stereo PCM)
/// packetized for the guest, so the guest hears the game without a second lossy encode.
///
/// Video and audio share one UDP port. They are told apart by the second magic byte (`C` for the
/// compressed video, `A` for audio), so a single listener demultiplexes both.
enum OPNRemoteCoOpAudioPacket {
    static let magic0: UInt8 = 0x4F
    static let magic1: UInt8 = 0x41
    static let version: UInt8 = 1

    /// Magic, version, flags, sequence, timestamp, sample rate, channels, frame count, payload length.
    static let headerBytes = 26

    /// 10 ms at 48 kHz, so one chunk is 960 bytes of stereo PCM and the datagram stays well under a
    /// path MTU. A larger device buffer is split into several chunks.
    static let maximumFramesPerChunk = 240

    struct Header: Equatable {
        var sequence: UInt32
        var timestampNanoseconds: UInt64
        var sampleRate: UInt32
        var channels: UInt16
        var frameCount: UInt16
        var payloadLength: UInt16
    }

    /// True when a datagram is audio rather than compressed video. Cheap enough to run per datagram.
    static func isAudioDatagram(_ datagram: Data) -> Bool {
        let bytes = [UInt8](datagram.prefix(2))
        return bytes.count == 2 && bytes[0] == magic0 && bytes[1] == magic1
    }

    static func encode(_ header: Header, payload: Data) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerBytes + payload.count)
        bytes.append(magic0)
        bytes.append(magic1)
        bytes.append(version)
        bytes.append(0)
        appendUInt32(header.sequence, to: &bytes)
        appendUInt64(header.timestampNanoseconds, to: &bytes)
        appendUInt32(header.sampleRate, to: &bytes)
        appendUInt16(header.channels, to: &bytes)
        appendUInt16(header.frameCount, to: &bytes)
        appendUInt16(header.payloadLength, to: &bytes)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    static func decode(_ datagram: Data) -> (header: Header, payload: Data)? {
        let bytes = [UInt8](datagram)
        guard bytes.count >= headerBytes, bytes[0] == magic0, bytes[1] == magic1, bytes[2] == version else { return nil }
        let sequence = readUInt32(bytes, at: 4)
        let timestampNanoseconds = readUInt64(bytes, at: 8)
        let sampleRate = readUInt32(bytes, at: 16)
        let channels = readUInt16(bytes, at: 20)
        let frameCount = readUInt16(bytes, at: 22)
        let payloadLength = Int(readUInt16(bytes, at: 24))
        guard bytes.count - headerBytes == payloadLength else { return nil }
        let header = Header(sequence: sequence,
                            timestampNanoseconds: timestampNanoseconds,
                            sampleRate: sampleRate,
                            channels: channels,
                            frameCount: frameCount,
                            payloadLength: UInt16(payloadLength))
        return (header, Data(bytes[headerBytes...]))
    }

    private static func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
        for shift in stride(from: 24, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    private static func appendUInt64(_ value: UInt64, to bytes: inout [UInt8]) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value = (value << 8) | UInt32(bytes[offset + index]) }
        return value
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(bytes[offset + index]) }
        return value
    }
}

/// Guest-side PCM buffer between the network and the speaker. A target depth is kept so ordinary
/// jitter does not turn into an underrun; anything past the cap is dropped oldest-first so a stalled
/// guest cannot grow the buffer without bound.
final class RemoteCoOpNativeAudioPlayoutBuffer: @unchecked Sendable {    private let lock = NSLock()
    private var samples: [Int16] = []
    private let targetSamples: Int
    private let maximumSamples: Int
    private var isPrimed = false

    init(channels: Int = 2, sampleRate: Int = 48_000, targetMilliseconds: Int = 50) {
        let frameSamples = max(1, channels)
        targetSamples = sampleRate * targetMilliseconds / 1000 * frameSamples
        maximumSamples = targetSamples * 8
    }

    /// Returns true once the buffer has primed; before that the caller plays silence so the guest
    /// does not stutter while the first few chunks fill the buffer.
    func append(_ incoming: [Int16]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: incoming)
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
        if !isPrimed, samples.count >= targetSamples { isPrimed = true }
        return isPrimed
    }

    /// Fills `count` interleaved samples, silence for anything missing.
    func fill(_ destination: UnsafeMutablePointer<Int16>, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard isPrimed, !samples.isEmpty else {
            destination.update(repeating: 0, count: count)
            return
        }
        let available = min(count, samples.count)
        samples.withUnsafeBufferPointer { buffer in
            destination.update(from: buffer.baseAddress!, count: available)
        }
        if available < count { destination.advanced(by: available).update(repeating: 0, count: count - available) }
        samples.removeFirst(available)
    }

    func reset() {
        lock.lock(); samples.removeAll(); isPrimed = false; lock.unlock()
    }
}

/// Splits one game-audio callback into ready-to-send audio datagrams, so the spike forwarder and the
/// session broadcaster frame audio identically.
enum RemoteCoOpNativeAudioChunker {
    struct Result {
        var datagrams: [Data]
        var nextSequence: UInt64
    }

    static func datagrams(from frame: RemoteCoOpNativeAudioFrame, startingSequence: UInt64, timestampNanoseconds: UInt64) -> Result {
        let channels = Int(frame.channels)
        let totalFrames = Int(frame.frameCount)
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        guard totalFrames > 0, bytesPerFrame > 0, !frame.samples.isEmpty else {
            return Result(datagrams: [], nextSequence: startingSequence)
        }

        let samples = frame.samples
        var datagrams: [Data] = []
        var sequence = startingSequence
        var offsetFrames = 0
        while offsetFrames < totalFrames {
            let chunkFrames = min(OPNRemoteCoOpAudioPacket.maximumFramesPerChunk, totalFrames - offsetFrames)
            let start = offsetFrames * bytesPerFrame
            let end = start + chunkFrames * bytesPerFrame
            guard end <= samples.count else { break }
            let payload = samples.withUnsafeBytes { Data($0[start..<end]) }
            let header = OPNRemoteCoOpAudioPacket.Header(
                sequence: UInt32(truncatingIfNeeded: sequence),
                timestampNanoseconds: timestampNanoseconds,
                sampleRate: UInt32(frame.sampleRate.rounded()),
                channels: UInt16(channels),
                frameCount: UInt16(chunkFrames),
                payloadLength: UInt16(payload.count)
            )
            datagrams.append(OPNRemoteCoOpAudioPacket.encode(header, payload: payload))
            sequence &+= 1
            offsetFrames += chunkFrames
        }
        return Result(datagrams: datagrams, nextSequence: sequence)
    }
}
