import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized)
struct NvstRtcpTests {

    @Test func receiverReportLayout() {
        let block = NvstRtcpReportBlock(
            sourceSSRC: 0x0102_0304,
            fractionLost: 0x1a,
            cumulativeLost: 0x0000_abcd,
            extendedHighestSequence: 0x0001_0002,
            interarrivalJitter: 0x0033_0044
        )
        let packet = NvstRtcp.receiverReport(ssrc: 0xaabb_ccdd, blocks: [block])
        // header: V=2, RC=1, PT=201, length = (2 + 6) - 1 = 7
        #expect(packet.count == 4 + 4 + 24)
        #expect(packet[0] == 0x81)
        #expect(packet[1] == 201)
        #expect(packet.readUInt16BE(at: 2) == 7)
        #expect(packet.readUInt32BE(at: 4) == 0xaabb_ccdd)
        #expect(packet.readUInt32BE(at: 8) == 0x0102_0304)
        #expect(packet.readUInt32BE(at: 12) == (0x1a << 24 | 0x0000_abcd))
        #expect(packet.readUInt32BE(at: 16) == 0x0001_0002)
        #expect(packet.readUInt32BE(at: 20) == 0x0033_0044)
    }

    @Test func pictureLossIndicationLayout() {
        let packet = NvstRtcp.pictureLossIndication(senderSSRC: 0x1111_2222, mediaSSRC: 0x3333_4444)
        #expect(packet.count == 12)
        #expect(packet[0] == 0x81) // V=2, FMT=1 (PLI)
        #expect(packet[1] == 206)
        #expect(packet.readUInt16BE(at: 2) == 2)
        #expect(packet.readUInt32BE(at: 4) == 0x1111_2222)
        #expect(packet.readUInt32BE(at: 8) == 0x3333_4444)
    }

    @Test func srtcpIndexTrailerEncoding() {
        let trailer = NvstRtcp.srtcpIndexTrailer(index: 0x1234_5678, encrypted: true)
        #expect(trailer.count == 4)
        #expect(trailer[0] == 0x92) // 0x80 | high bits of 0x12345678 (0x92 = 0x80 | 0x12)
        #expect(trailer[1] == 0x34)
        #expect(trailer[2] == 0x56)
        #expect(trailer[3] == 0x78)
        let plain = NvstRtcp.srtcpIndexTrailer(index: 1, encrypted: false)
        #expect(plain == Data([0x00, 0x00, 0x00, 0x01]))
    }

    @Test func srtcpGcmIvMatchesRfc7714() {
        let salt = Data(repeating: 0, count: 12)
        let iv = NvstRtcp.srtcpGcmIV(sessionSalt: salt, ssrc: 0x1122_3344, srtcpIndex: 0x5566_7788)
        #expect(iv.count == 12)
        let bytes = [UInt8](iv)
        #expect(bytes[0] == 0)
        #expect(bytes[1] == 0)
        #expect(bytes[2] == 0x11)
        #expect(bytes[3] == 0x22)
        #expect(bytes[4] == 0x33)
        #expect(bytes[5] == 0x44)
        #expect(bytes[6] == 0x55)
        #expect(bytes[7] == 0x66)
        #expect(bytes[8] == 0x77)
        #expect(bytes[9] == 0x88)
        #expect(bytes[10] == 0)
        #expect(bytes[11] == 0)
    }
}

private extension Data {
    func readUInt16BE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}
