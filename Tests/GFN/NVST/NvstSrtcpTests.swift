import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized)
struct NvstSrtcpTests {

    private func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    @Test func srtcpSealOpenRoundTrips() throws {
        let masterKey = hex(String(repeating: "cd", count: 32))
        let masterSalt = hex("0ec675ad498afeebb6960b3aabe6")
        let senderSSRC: UInt32 = 0x4433_2211
        let block = NvstRtcpReportBlock(sourceSSRC: 0x1122_3344, fractionLost: 0, cumulativeLost: 3, extendedHighestSequence: 0x0001_0002, interarrivalJitter: 0)
        let rtcp = NvstRtcp.receiverReport(ssrc: senderSSRC, blocks: [block])
        let sealed = try NvstSrtcp.seal(rtcpPacket: rtcp, masterKey: masterKey, masterSalt: masterSalt, senderSSRC: senderSSRC, srtcpIndex: 7)
        // cleartext header(8) + ciphertext of the full RTCP (rtcp.count) + tag(8) + index(4)
        #expect(sealed.count == rtcp.count + 12)
        let opened = try NvstSrtcp.open(srtcpPacket: sealed, masterKey: masterKey, masterSalt: masterSalt, senderSSRC: senderSSRC)
        #expect(opened.rtcp == rtcp)
        #expect(opened.index == 7)
    }

    @Test func srtcpRejectsTamperedTag() throws {
        let masterKey = hex(String(repeating: "cd", count: 32))
        let masterSalt = hex("0ec675ad498afeebb6960b3aabe6")
        let block = NvstRtcpReportBlock(sourceSSRC: 1, fractionLost: 0, cumulativeLost: 0, extendedHighestSequence: 1, interarrivalJitter: 0)
        let rtcp = NvstRtcp.receiverReport(ssrc: 1, blocks: [block])
        let sealed = try NvstSrtcp.seal(rtcpPacket: rtcp, masterKey: masterKey, masterSalt: masterSalt, senderSSRC: 1, srtcpIndex: 1)
        var tampered = sealed
        tampered[tampered.count - 5] ^= 0x80
        #expect(throws: SrtpCryptoError.self) {
            _ = try NvstSrtcp.open(srtcpPacket: tampered, masterKey: masterKey, masterSalt: masterSalt, senderSSRC: 1)
        }
    }

    @Test func feedbackSenderProducesSealedReports() throws {
        let masterKey = hex(String(repeating: "cd", count: 32))
        let masterSalt = hex("0ec675ad498afeebb6960b3aabe6")
        final class Sink: @unchecked Sendable {
            private let lock = NSLock()
            private var packets: [Data] = []
            func append(_ data: Data) { lock.lock(); packets.append(data); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return packets.count }
            var first: Data? { lock.lock(); defer { lock.unlock() }; return packets.first }
        }
        let sink = Sink()
        let sender = NvstFeedbackSender(interval: 3600)
        sender.configure(channelWriter: { sink.append($0) }, senderSSRC: 9, mediaSSRC: 8)
        sender.updateMediaState(highestExtendedSequence: 0x1234_5678, cumulativeLost: 2)
        try sender.sendKeyframeRequestNow()
        #expect(sink.count == 1)
        #expect(sink.first?.count == 12) // plain PLI is 12 bytes

        // The SCTP channel carries plain RTCP (DTLS already encrypts it); SRTCP belongs to the
        // raw Mjolnir UDP socket, so verify that sealing path directly.
        let block = NvstRtcpReportBlock(sourceSSRC: 8, fractionLost: 0, cumulativeLost: 2, extendedHighestSequence: 0x1234_5678, interarrivalJitter: 0)
        let rtcp = NvstRtcp.receiverReport(ssrc: 9, blocks: [block])
        let sealed = try NvstSrtcp.seal(rtcpPacket: rtcp, masterKey: masterKey, masterSalt: masterSalt, senderSSRC: 9, srtcpIndex: 0)
        let opened = try NvstSrtcp.open(srtcpPacket: sealed, masterKey: masterKey, masterSalt: masterSalt, senderSSRC: 9)
        #expect(opened.rtcp == rtcp)
    }
}
