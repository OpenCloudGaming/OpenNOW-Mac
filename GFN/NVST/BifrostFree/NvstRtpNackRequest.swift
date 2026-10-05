//  The version 2 retransmission request the seat answers.
//

import Foundation

/// Control command `0x317`, which the official client sends for `rtpNackVersion` 2
/// (`NvscClientPipeline::createAndSendNackRequest` → `ServerControl::sendRtpNackRequest`) instead
/// of an RTCP NACK. Layout from `RtpSourceQueueExtV2::createNackRequest`: version, stream index
/// and entry count, one byte each, then per entry a little-endian u16 sequence number and a
/// little-endian u64 whose bit n names sequence + n + 1. At most 64 sequence numbers per request.
public struct NvstRtpNackRequest: Equatable, Sendable {
    public static let version: UInt8 = 2
    public static let maximumSequenceNumbers = 64

    public struct Entry: Equatable, Sendable {
        public let sequenceNumber: UInt16
        public let followingMask: UInt64
    }

    public let streamIndex: UInt8
    public let entries: [Entry]

    /// `sequenceNumbers` in RTP order; only the first `maximumSequenceNumbers` are named.
    public init(streamIndex: UInt8 = 0, sequenceNumbers: [UInt16]) {
        self.streamIndex = streamIndex
        let named = sequenceNumbers.prefix(Self.maximumSequenceNumbers)
        var entries: [Entry] = []
        var index = named.startIndex
        while index < named.endIndex {
            let base = named[index]
            var mask: UInt64 = 0
            index += 1
            while index < named.endIndex {
                let offset = named[index] &- base
                guard offset >= 1, offset <= 64 else { break }
                mask |= 1 << UInt64(offset - 1)
                index += 1
            }
            entries.append(Entry(sequenceNumber: base, followingMask: mask))
        }
        self.entries = entries
    }

    public var payload: Data {
        var writer = NvstByteWriter(capacity: 3 + entries.count * 10)
        writer.u8(Self.version)
        writer.u8(streamIndex)
        writer.u8(UInt8(entries.count))
        for entry in entries {
            writer.u16LE(entry.sequenceNumber)
            writer.u64LE(entry.followingMask)
        }
        return writer.data
    }

    public var command: NvstControlCommand {
        NvstControlCommand(code: .rtpNackRequest, payload: payload)
    }
}
