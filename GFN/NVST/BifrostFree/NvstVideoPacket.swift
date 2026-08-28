import Foundation

/// RTP parsing + NVST "Mjolnir" GS-extension depacketization, per the wire format
/// independently observed and documented by OpenNOW's MIT `native-opennow-streamer`:
/// video packets carry a fixed 16-byte RTP extension block, profile `0x4753` ("GS"), holding
/// a 24-bit stream sequence, a 32-bit frame index, and SOF/EOF/contains-pic-data flags; the
/// RTP payloads reassemble into H.264 Annex-B access units.

public struct NvstRtpVideoPacket: Equatable, Sendable {
    public let payloadType: UInt8
    public let sequenceNumber: UInt16
    public let timestamp: UInt32
    public let ssrc: UInt32
    public let streamSequence: UInt32
    public let frameIndex: UInt32
    public let flags: NVSTVideoFlag
    /// True when the GS extension's FEC group coordinates mark this as a repair packet.
    /// Repair packets carry no picture data and must never reach the assembler.
    public let isFec: Bool
    /// A frame can span several FEC blocks. Start- and end-of-frame only count on the first and
    /// last block, so these qualify the raw SOF/EOF flags.
    public let fecCurrentBlock: UInt8
    public let fecLastBlock: UInt8
    /// This packet's index within its FEC group. Indices below `fecSourcePackets` are source data;
    /// at or above it, repair data.
    public let fecIndex: UInt32
    /// How many source packets the group protects.
    public let fecSourcePackets: UInt32
    /// The group's repair overhead in percent; parity shard count is `ceil(sources * pct / 100)`.
    public let fecPercentage: UInt32
    public let payload: Data
    /// AAD prefix length (12-byte RTP header + 20-byte GS extension), for the SRTP layer.
    public static let headerAndExtensionLength = 32

    public struct NVSTVideoFlag: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let containsPicData = NVSTVideoFlag(rawValue: 0x01)
        public static let endOfFrame = NVSTVideoFlag(rawValue: 0x02)
        public static let startOfFrame = NVSTVideoFlag(rawValue: 0x04)
    }

    /// A frame's first packet: the SOF flag only counts on the first FEC block.
    public var isStartOfFrame: Bool { flags.contains(.startOfFrame) && fecCurrentBlock == 0 }

    /// A frame's last packet: the EOF flag only counts on the last FEC block.
    public var isEndOfFrame: Bool { flags.contains(.endOfFrame) && fecCurrentBlock == fecLastBlock }

    public static let gsExtensionProfile: UInt16 = 0x4753
}

public enum NvstRtpParseError: LocalizedError, Equatable, Sendable {
    case truncated(String)
    case notRtp
    case missingGsExtension
    case badExtensionLength

    public var errorDescription: String? {
        switch self {
        case .truncated(let reason): "NVST RTP parse truncated: \(reason)"
        case .notRtp: "NVST RTP parse: not an RTP v2 packet."
        case .missingGsExtension: "NVST RTP parse: missing the 0x4753 GS extension."
        case .badExtensionLength: "NVST RTP parse: GS extension length is not 16 bytes."
        }
    }
}

public enum NvstVideoPacketParser {
    /// Parses one decrypted SRTP RTP datagram (12-byte header + 20-byte GS extension + payload).
    public static func parse(_ packet: Data) throws -> NvstRtpVideoPacket {
        guard packet.count >= 12 else { throw NvstRtpParseError.truncated("RTP header") }
        let first = packet[0]
        guard first & 0xc0 == 0x80 else { throw NvstRtpParseError.notRtp }
        guard first & 0x10 != 0 else { throw NvstRtpParseError.missingGsExtension }

        let payloadType = packet[1] & 0x7f
        let sequenceNumber = UInt16(packet[2]) << 8 | UInt16(packet[3])
        let timestamp = readUInt32BE(packet, 4)
        let ssrc = readUInt32BE(packet, 8)

        guard packet.count >= 16 else { throw NvstRtpParseError.truncated("GS extension header") }
        let profile = readUInt16BE(packet, 12)
        let lengthWords = Int(readUInt16BE(packet, 14))
        let extensionLength = lengthWords * 4
        guard profile == NvstRtpVideoPacket.gsExtensionProfile else { throw NvstRtpParseError.missingGsExtension }
        guard extensionLength == 16 else { throw NvstRtpParseError.badExtensionLength }
        guard packet.count >= 16 + extensionLength else { throw NvstRtpParseError.truncated("GS extension") }

        let gs = 16
        let sequenceWord = readUInt32LE(packet, gs)
        let streamSequence = (sequenceWord >> 8) & 0x00ff_ffff
        let frameIndex = readUInt32LE(packet, gs + 4)
        // Flags live in the low nibble of the little-endian word at extension offset 8.
        let flags = NvstRtpVideoPacket.NVSTVideoFlag(rawValue: packet[gs + 8] & 0x0f)
        // FEC group coordinates: a repair packet is one whose index within the group is at or past
        // the source-packet count, while the group carries a non-zero repair percentage.
        let fecWord = readUInt32LE(packet, gs + 12)
        let fecPercentage = (fecWord >> 4) & 0xff
        let fecIndex = (fecWord >> 12) & 0x3ff
        let fecSourcePackets = (fecWord >> 22) & 0x3ff
        let isFec = fecPercentage != 0 && fecIndex >= fecSourcePackets
        // The multi-FEC-block counters share the top byte of the flags word.
        let multiFecBlocks = packet[gs + 11]

        let payloadOffset = gs + 16
        var end = packet.count
        if first & 0x20 != 0, let padding = packet.last, padding > 0, padding <= packet.count - payloadOffset {
            end -= Int(padding)
        }
        let payload = Data(packet[payloadOffset..<max(payloadOffset, end)])

        return NvstRtpVideoPacket(
            payloadType: payloadType,
            sequenceNumber: sequenceNumber,
            timestamp: timestamp,
            ssrc: ssrc,
            streamSequence: streamSequence,
            frameIndex: frameIndex,
            flags: flags,
            isFec: isFec,
            fecCurrentBlock: (multiFecBlocks >> 4) & 0x03,
            fecLastBlock: (multiFecBlocks >> 6) & 0x03,
            fecIndex: fecIndex,
            fecSourcePackets: fecSourcePackets,
            fecPercentage: fecPercentage,
            payload: payload
        )
    }

    static func readUInt16BE(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    static func readUInt32BE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    static func readUInt32LE(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }
}
