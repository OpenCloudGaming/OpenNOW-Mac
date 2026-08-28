import Foundation

/// RTCP/SRTCP builders for the NVST `rtcp1` feedback channel.
///
/// Upstream's independently observed rule: the official client sends SRTCP Receiver Reports
/// and PLI over an SCTP data channel on the WebRTC bundle ("RTCP over SCTP is a must for One
/// SDK video to function"). SRTCP reuses the SRTP master key with labels 0x03 (key) / 0x05
/// (salt) and the RFC 7714 §9.2 SRTCP GCM IV.
public struct NvstRtcpReportBlock: Equatable, Sendable {
    public let sourceSSRC: UInt32
    public let fractionLost: UInt8
    public let cumulativeLost: UInt32
    public let extendedHighestSequence: UInt32
    public let interarrivalJitter: UInt32
    public let lastSenderReportTimestamp: UInt32
    public let delaySinceLastSenderReport: UInt32

    public init(sourceSSRC: UInt32,
                fractionLost: UInt8,
                cumulativeLost: UInt32,
                extendedHighestSequence: UInt32,
                interarrivalJitter: UInt32,
                lastSenderReportTimestamp: UInt32 = 0,
                delaySinceLastSenderReport: UInt32 = 0) {
        self.sourceSSRC = sourceSSRC
        self.fractionLost = fractionLost
        self.cumulativeLost = cumulativeLost & 0x00ff_ffff
        self.extendedHighestSequence = extendedHighestSequence
        self.interarrivalJitter = interarrivalJitter
        self.lastSenderReportTimestamp = lastSenderReportTimestamp
        self.delaySinceLastSenderReport = delaySinceLastSenderReport
    }
}

public enum NvstRtcp {
    public static let receiverReportPayloadType: UInt8 = 201
    public static let payloadSpecificFeedbackPayloadType: UInt8 = 206
    /// RFC 4585 transport-layer feedback, which is where Generic NACK lives.
    public static let transportFeedbackPayloadType: UInt8 = 205

    /// RFC 3550 Receiver Report (compound RR with no embedded SDES).
    public static func receiverReport(ssrc: UInt32, blocks: [NvstRtcpReportBlock]) -> Data {
        var packet = Data()
        let wordCount = 2 + blocks.count * 6 // header (2 words incl sender ssrc) + 6 words/block
        let length = UInt16(wordCount - 1)
        packet.append(contentsOf: [0x80 | UInt8(blocks.count), receiverReportPayloadType])
        packet.appendBigEndian(length)
        packet.appendBigEndian(ssrc)
        for block in blocks {
            packet.appendBigEndian(block.sourceSSRC)
            let first = (UInt32(block.fractionLost) << 24) | block.cumulativeLost
            packet.appendBigEndian(first)
            packet.appendBigEndian(block.extendedHighestSequence)
            packet.appendBigEndian(block.interarrivalJitter)
            packet.appendBigEndian(block.lastSenderReportTimestamp)
            packet.appendBigEndian(block.delaySinceLastSenderReport)
        }
        return packet
    }

    /// RFC 4585 PT=206 FMT=1 (PLI) feedback packet.
    public static func pictureLossIndication(senderSSRC: UInt32, mediaSSRC: UInt32) -> Data {
        var packet = Data()
        packet.append(contentsOf: [0x81, payloadSpecificFeedbackPayloadType])
        packet.appendBigEndian(UInt16(2)) // length = sender SSRC + media SSRC
        packet.appendBigEndian(senderSSRC)
        packet.appendBigEndian(mediaSSRC)
        return packet
    }

    /// RFC 4585 PT=205 FMT=1: Generic NACK, asking the sender to retransmit specific packets.
    ///
    /// We have announced `video[0].enableRtpNack:1` from the captured baseline for as long as this
    /// client has existed and then never sent one, so every gap — however small — cost a full
    /// keyframe instead of the handful of packets actually missing. Each FCI entry names one packet
    /// id plus a 16-bit mask of the packets following it, so a 17-packet run needs one entry.
    ///
    /// `missing` is taken in RTP sequence order; entries are emitted greedily.
    public static func genericNack(senderSSRC: UInt32, mediaSSRC: UInt32, missing: [UInt16]) -> Data? {
        guard !missing.isEmpty else { return nil }
        var entries: [(pid: UInt16, blp: UInt16)] = []
        var index = missing.startIndex
        while index < missing.endIndex, entries.count < maximumNackEntries {
            let pid = missing[index]
            var blp: UInt16 = 0
            var next = missing.index(after: index)
            while next < missing.endIndex {
                let delta = Int(missing[next] &- pid)
                guard delta >= 1, delta <= 16 else { break }
                blp |= UInt16(1) << UInt16(delta - 1)
                next = missing.index(after: next)
            }
            entries.append((pid, blp))
            index = next
        }
        var packet = Data()
        // V=2, P=0, FMT=1 (Generic NACK).
        packet.append(contentsOf: [0x81, transportFeedbackPayloadType])
        // Length in 32-bit words minus one: 2 SSRC words plus one word per FCI entry.
        packet.appendBigEndian(UInt16(2 + entries.count))
        packet.appendBigEndian(senderSSRC)
        packet.appendBigEndian(mediaSSRC)
        for entry in entries {
            packet.appendBigEndian(entry.pid)
            packet.appendBigEndian(entry.blp)
        }
        return packet
    }

    /// A NACK naming more than this is a loss burst a keyframe recovers from faster than
    /// retransmission would.
    public static let maximumNackEntries = 8

    /// RFC 7714 §9.2 SRTCP GCM IV: salt XOR (SSRC at bytes 2..6, SRTCP index at 6..10).
    public static func srtcpGcmIV(sessionSalt: Data, ssrc: UInt32, srtcpIndex: UInt32) -> Data {
        var iv = [UInt8](sessionSalt)
        let ssrcBytes = bigEndianBytes(ssrc)
        let indexBytes = bigEndianBytes(srtcpIndex)
        for index in 0..<4 { iv[2 + index] ^= ssrcBytes[index] }
        for index in 0..<4 { iv[6 + index] ^= indexBytes[index] }
        return Data(iv)
    }

    /// RFC 3711 SRTCP index trailer: 4 bytes with the encrypted-flag (`S`) as the MSB and the
    /// 31-bit SRTCP index in the remaining bits.
    public static func srtcpIndexTrailer(index: UInt32, encrypted: Bool) -> Data {
        let masked = index & 0x7fff_ffff
        var value = masked
        if encrypted { value |= 0x8000_0000 }
        return Data(bigEndianBytes(value))
    }

    private static func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var big = value.bigEndian
        return withUnsafeBytes(of: &big) { Array($0) }
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xff))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(UInt8(value >> 24)); append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8(value & 0xff))
    }
}
