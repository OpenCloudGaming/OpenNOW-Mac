import Foundation
import Testing
@testable import OpenNOW

/// Layout from `RtpSourceQueueExtV2::createNackRequest` in the official client.
struct NvstRtpNackRequestTests {
    @Test func packetsWithin64OfAnEntryRideInItsMask() {
        let request = NvstRtpNackRequest(sequenceNumbers: [100, 101, 103, 200])
        #expect(request.entries == [
            NvstRtpNackRequest.Entry(sequenceNumber: 100, followingMask: 0b101),
            NvstRtpNackRequest.Entry(sequenceNumber: 200, followingMask: 0),
        ])
        #expect([UInt8](request.payload) == [0x02, 0x00, 0x02,
                                              0x64, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                                              0xc8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(request.command.code == .rtpNackRequest)
        #expect(NvstControlCommandCode.rtpNackRequest.rawValue == 0x0317)
    }

    @Test func theMaskSpansTheSequenceWrapAndEndsAtSixtyFour() {
        let request = NvstRtpNackRequest(sequenceNumbers: [0xffff, 0x0000, 0xffff &+ 64, 0xffff &+ 65])
        #expect(request.entries == [
            NvstRtpNackRequest.Entry(sequenceNumber: 0xffff, followingMask: 1 | (1 << 63)),
            NvstRtpNackRequest.Entry(sequenceNumber: 0xffff &+ 65, followingMask: 0),
        ])
    }

    @Test func atMostSixtyFourSequenceNumbersAreNamed() {
        let request = NvstRtpNackRequest(sequenceNumbers: (0..<100).map { UInt16($0 * 100) })
        #expect(request.entries.count == NvstRtpNackRequest.maximumSequenceNumbers)
    }
}
