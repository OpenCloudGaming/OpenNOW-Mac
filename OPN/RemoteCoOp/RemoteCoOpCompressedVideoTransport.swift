import Foundation

/// The compressed-video framing Remote Co-Op uses to forward the host's *source* stream to a native
/// guest, so the guest decodes what the seat encoded rather than a second encode of the decoded
/// picture. This is the media half of the WebRTC-free Co-Op plan.
///
/// Transport-agnostic on purpose: it turns a `NativeNVSTVideoFrame` into MTU-sized datagrams and
/// back. The session, encryption and reachability live above it, and the tests here prove the
/// framing alone — fragmentation, out-of-order reassembly and loss recovery.
public enum OPNRemoteCoOpCompressedVideoPacket {
    /// `OC`, so a stray datagram on a shared socket is rejected rather than parsed as media.
    static let magic0: UInt8 = 0x4F
    static let magic1: UInt8 = 0x43
    static let version: UInt8 = 1

    /// Magic, version, flags, codec, stream ID, session ID, frame sequence, timestamp, duration,
    /// fragment index, fragment count and payload length. Fixed so a decoder never has to search for
    /// a boundary.
    public static let headerBytes = 39

    /// One datagram's payload ceiling. 1200 stays under a 1280-byte path MTU with the header and any
    /// outer encapsulation, which keeps a 5K access unit to a small, ordered burst of fragments.
    public static let maximumFragmentPayload = 1200

    struct Header: Equatable {
        var isKeyFrame: Bool
        var codec: NativeNVSTVideoCodec
        var streamID: UInt32
        var sessionID: UInt32
        var frameSequence: UInt32
        var timestampNanoseconds: UInt64
        var durationNanoseconds: UInt64
        var fragmentIndex: UInt16
        var fragmentCount: UInt16
        var payloadLength: UInt16
    }

    static func encode(_ header: Header, payload: Data) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(headerBytes + payload.count)
        bytes.append(magic0)
        bytes.append(magic1)
        bytes.append(version)
        bytes.append(header.isKeyFrame ? 0x01 : 0x00)
        bytes.append(header.codec.wireCode)
        appendUInt32(header.streamID, to: &bytes)
        appendUInt32(header.sessionID, to: &bytes)
        appendUInt32(header.frameSequence, to: &bytes)
        appendUInt64(header.timestampNanoseconds, to: &bytes)
        appendUInt64(header.durationNanoseconds, to: &bytes)
        appendUInt16(header.fragmentIndex, to: &bytes)
        appendUInt16(header.fragmentCount, to: &bytes)
        appendUInt16(header.payloadLength, to: &bytes)
        bytes.append(contentsOf: payload)
        return Data(bytes)
    }

    static func decode(_ datagram: Data) -> (header: Header, payload: Data)? {
        let bytes = [UInt8](datagram)
        guard bytes.count >= headerBytes else { return nil }
        guard bytes[0] == magic0, bytes[1] == magic1, bytes[2] == version else { return nil }
        let isKeyFrame = bytes[3] & 0x01 != 0
        let codec = NativeNVSTVideoCodec(wireCode: bytes[4])
        let streamID = readUInt32(bytes, at: 5)
        let sessionID = readUInt32(bytes, at: 9)
        let frameSequence = readUInt32(bytes, at: 13)
        let timestampNanoseconds = readUInt64(bytes, at: 17)
        let durationNanoseconds = readUInt64(bytes, at: 25)
        let fragmentIndex = readUInt16(bytes, at: 33)
        let fragmentCount = readUInt16(bytes, at: 35)
        let payloadLength = Int(readUInt16(bytes, at: 37))
        guard bytes.count - headerBytes == payloadLength else { return nil }
        let header = Header(isKeyFrame: isKeyFrame,
                            codec: codec,
                            streamID: streamID,
                            sessionID: sessionID,
                            frameSequence: frameSequence,
                            timestampNanoseconds: timestampNanoseconds,
                            durationNanoseconds: durationNanoseconds,
                            fragmentIndex: fragmentIndex,
                            fragmentCount: fragmentCount,
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

/// Host side: splits one access unit into datagrams a lossy path can carry.
public final class OPNRemoteCoOpCompressedVideoFragmenter: @unchecked Sendable {
    public let maximumFragmentPayload: Int
    /// Identifies this sender's stream. A host restart makes a fresh value, so a reassembler can tell
    /// a new session from an old fragment whose sequence happens to be lower.
    public let sessionID: UInt32

    private let lock = NSLock()
    private var nextSequence: UInt32 = 0

    public init(maximumFragmentPayload: Int = OPNRemoteCoOpCompressedVideoPacket.maximumFragmentPayload) {
        self.maximumFragmentPayload = max(1, min(Int(UInt16.max), maximumFragmentPayload))
        self.sessionID = UInt32.random(in: 0...UInt32.max)
    }

    /// One datagram per fragment, in order. A frame with no payload still yields a single datagram so
    /// the guest sees the keyframe boundary rather than silence.
    public func fragments(for frame: NativeNVSTVideoFrame) -> [Data] {
        lock.lock()
        let sequence = nextSequence
        nextSequence &+= 1
        lock.unlock()

        let payload = frame.payload
        let fragmentCount = max(1, (payload.count + maximumFragmentPayload - 1) / maximumFragmentPayload)
        return payload.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return (0..<fragmentCount).map { index -> Data in
                let start = index * maximumFragmentPayload
                let end = min(start + maximumFragmentPayload, payload.count)
                let slice: Data
                if end > start, let base = bytes.baseAddress {
                    slice = Data(bytes: base.advanced(by: start), count: end - start)
                } else {
                    slice = Data()
                }
                let header = OPNRemoteCoOpCompressedVideoPacket.Header(
                    isKeyFrame: frame.isKeyFrame,
                    codec: frame.codec,
                    streamID: frame.streamID,
                    sessionID: sessionID,
                    frameSequence: sequence,
                    timestampNanoseconds: frame.timestamp.nanoseconds,
                    durationNanoseconds: frame.durationNanoseconds,
                    fragmentIndex: UInt16(index),
                    fragmentCount: UInt16(fragmentCount),
                    payloadLength: UInt16(slice.count)
                )
                return OPNRemoteCoOpCompressedVideoPacket.encode(header, payload: slice)
            }
        }
    }
}

/// Guest side: reassembles datagrams into access units, in order, dropping anything a loss made
/// unusable rather than waiting on it forever.
public final class OPNRemoteCoOpCompressedVideoReassembler: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var datagrams: UInt64 = 0
        public var rejected: UInt64 = 0
        public var framesEmitted: UInt64 = 0
        /// Frames abandoned because a newer frame started before they completed.
        public var framesDropped: UInt64 = 0
    }

    private struct Pending {
        var sequence: UInt32
        var streamID: UInt32
        var codec: NativeNVSTVideoCodec
        var timestampNanoseconds: UInt64
        var durationNanoseconds: UInt64
        var isKeyFrame: Bool
        var fragmentCount: Int
        var received: [Int: Data]

        init(header: OPNRemoteCoOpCompressedVideoPacket.Header) {
            sequence = header.frameSequence
            streamID = header.streamID
            codec = header.codec
            timestampNanoseconds = header.timestampNanoseconds
            durationNanoseconds = header.durationNanoseconds
            isKeyFrame = header.isKeyFrame
            fragmentCount = Int(header.fragmentCount)
            received = [:]
        }
    }

    private let lock = NSLock()
    private var pending: Pending?
    /// The session the current state belongs to. A different one is a restarted sender, whose
    /// sequences start over, so the old sequence history must be discarded rather than reject it.
    private var sessionID: UInt32?
    /// The newest frame sequence a fragment has been accepted for. It survives completion so a
    /// duplicate or late fragment of an already-seen frame is rejected instead of starting it again.
    private var latestSequence: UInt32?
    private var counters = Counters()

    public init() {}

    public var snapshot: Counters {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    /// Returns a completed access unit, or nil while its fragments are still arriving.
    public func ingest(_ datagram: Data) -> NativeNVSTVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        counters.datagrams += 1

        guard let (header, payload) = accepted(datagram) else { return nil }
        let fragmentIndex = Int(header.fragmentIndex)
        if pending == nil { pending = Pending(header: header) }
        guard var current = pending else { return nil }
        // A repeat of a fragment already held adds nothing and must not double-count toward completion.
        if current.received[fragmentIndex] == nil { current.received[fragmentIndex] = payload }
        pending = current

        guard current.received.count == current.fragmentCount else { return nil }
        pending = nil
        counters.framesEmitted += 1
        return Self.assembledFrame(from: current)
    }

    /// Validates the framing, then admits the fragment to the current frame or rejects it as stale.
    private func accepted(_ datagram: Data) -> (header: OPNRemoteCoOpCompressedVideoPacket.Header, payload: Data)? {
        guard let decoded = OPNRemoteCoOpCompressedVideoPacket.decode(datagram) else {
            counters.rejected += 1
            return nil
        }
        // A restarted sender begins a new session with its own sequence history.
        if decoded.header.sessionID != sessionID {
            sessionID = decoded.header.sessionID
            pending = nil
            latestSequence = nil
        }
        let fragmentCount = Int(decoded.header.fragmentCount)
        guard fragmentCount > 0, Int(decoded.header.fragmentIndex) < fragmentCount, admitsSequence(decoded.header.frameSequence) else {
            counters.rejected += 1
            return nil
        }
        return decoded
    }

    /// True when the fragment belongs to the newest frame; anything older is a straggler whose
    /// siblings are gone, and anything equal after completion is a duplicate of a delivered frame.
    private func admitsSequence(_ sequence: UInt32) -> Bool {
        guard let latest = latestSequence else {
            latestSequence = sequence
            return true
        }
        if sequence == latest { return pending != nil }
        guard Self.isNewer(sequence, than: latest) else { return false }
        if pending != nil { counters.framesDropped += 1 }
        pending = nil
        latestSequence = sequence
        return true
    }

    private static func assembledFrame(from pending: Pending) -> NativeNVSTVideoFrame? {
        var assembled = Data()
        assembled.reserveCapacity(pending.received.values.reduce(0) { $0 + $1.count })
        for index in 0..<pending.fragmentCount {
            guard let part = pending.received[index] else { return nil }
            assembled.append(part)
        }
        return NativeNVSTVideoFrame(streamID: pending.streamID,
                                    codec: pending.codec,
                                    timestamp: MediaTimestamp(nanoseconds: pending.timestampNanoseconds),
                                    durationNanoseconds: pending.durationNanoseconds,
                                    width: 0,
                                    height: 0,
                                    isKeyFrame: pending.isKeyFrame,
                                    payload: assembled)
    }

    /// Wraparound-aware "is `candidate` ahead of `reference`".
    static func isNewer(_ candidate: UInt32, than reference: UInt32) -> Bool {
        candidate != reference && candidate &- reference < 0x8000_0000
    }
}

private extension NativeNVSTVideoCodec {
    var wireCode: UInt8 {
        switch self {
        case .h264: 1
        case .h265: 2
        case .av1: 3
        case .unknown: 0
        }
    }

    init(wireCode: UInt8) {
        switch wireCode {
        case 1: self = .h264
        case 2: self = .h265
        case 3: self = .av1
        default: self = .unknown
        }
    }
}
