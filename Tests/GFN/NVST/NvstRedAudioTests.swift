import Foundation
import Testing
@testable import OpenNOW

/// RED is the format the seat's game audio arrives in, and its block lengths are the whole reason it
/// is recoverable. The wire layout puts every header first and every payload after them, so the
/// fixtures below are built that way — an interleaved fixture would exercise a parser that does not
/// match the browser's.
@Suite struct NvstRedAudioTests {
    /// One redundant header: F set, payload type, 14-bit timestamp offset, 10-bit length.
    private func redundantHeader(payloadType: UInt8, timestampOffset: UInt32, length: Int) -> [UInt8] {
        let offsetBits = UInt8((timestampOffset & 0x3F) << 2)
        let lengthHighBits = UInt8((length >> 8) & 0x03)
        return [
            0x80 | (payloadType & 0x7F),
            UInt8((timestampOffset >> 6) & 0xFF),
            offsetBits | lengthHighBits,
            UInt8(length & 0xFF),
        ]
    }

    private func primaryHeader(payloadType: UInt8) -> [UInt8] { [payloadType & 0x7F] }

    @Test func aRedundantBlockAndItsPrimarySplitIntoTwoPayloads() throws {
        let redundant = Data([0xAA, 0xBB, 0xCC])
        let primary = Data([0x11, 0x22, 0x33, 0x44])
        // Headers first, then the payloads in the same order.
        let payload = Data(redundantHeader(payloadType: 111, timestampOffset: 240, length: redundant.count)
            + primaryHeader(payloadType: 111)
            + [UInt8](redundant)
            + [UInt8](primary))

        let blocks = try #require(NvstRedAudio.split(payload))
        #expect(blocks.count == 2)
        #expect(blocks[0].payloadType == 111)
        #expect(blocks[0].timestampOffset == 240)
        #expect(blocks[0].payload == redundant)
        #expect(!blocks[0].isPrimary)
        #expect(blocks[1].isPrimary)
        #expect(blocks[1].payload == primary, "the primary is what remains after the declared lengths")
    }

    @Test func theHeaderFieldsAreLaidOutTheWayTheRfcDefinesThem() throws {
        // An offset needing all fourteen bits and a length over 255, so a wrong shift or mask cannot
        // pass unnoticed.
        let offset: UInt32 = 0x2000 | 0x0155
        let length = 300
        let header = redundantHeader(payloadType: 63, timestampOffset: offset, length: length)
        #expect(header[0] == 0x80 | 63)
        #expect(header[1] == UInt8((offset >> 6) & 0xFF))
        #expect(header[3] == UInt8(length & 0xFF))

        let body = Data(repeating: 0x5A, count: length)
        let primary = Data(repeating: 0x77, count: 8)
        let payload = Data(header + primaryHeader(payloadType: 63) + [UInt8](body) + [UInt8](primary))
        let blocks = try #require(NvstRedAudio.split(payload))
        #expect(blocks.count == 2)
        #expect(blocks[0].timestampOffset == offset)
        #expect(blocks[0].payload == body)
        #expect(blocks[1].payload == primary)
    }

    @Test func onlyThePrimaryIsTakenWhenTheRepeatsAreNotNeeded() throws {
        let redundant = Data([1, 2, 3])
        let primary = Data([9, 9])
        let payload = Data(redundantHeader(payloadType: 111, timestampOffset: 480, length: redundant.count)
            + primaryHeader(payloadType: 111)
            + [UInt8](redundant)
            + [UInt8](primary))

        let block = try #require(NvstRedAudio.primary(in: payload))
        #expect(block.isPrimary)
        #expect(block.payload == primary)
    }

    @Test func theMostRecentRepeatOfTheCodecIsWhatCoversALoss() throws {
        let older = Data([0x01])
        let newer = Data([0x02, 0x03])
        let primary = Data([0x04, 0x05, 0x06])
        let payload = Data(redundantHeader(payloadType: 111, timestampOffset: 480, length: older.count)
            + redundantHeader(payloadType: 111, timestampOffset: 240, length: newer.count)
            + primaryHeader(payloadType: 111)
            + [UInt8](older)
            + [UInt8](newer)
            + [UInt8](primary))

        let blocks = try #require(NvstRedAudio.split(payload))
        #expect(blocks.count == 3)
        #expect(blocks.map(\.payload) == [older, newer, primary])
        #expect(NvstRedAudio.mostRecentRedundant(in: payload, payloadType: 111)?.payload == newer)
        // A payload type that is not carried has no repeat to offer.
        #expect(NvstRedAudio.mostRecentRedundant(in: payload, payloadType: 63) == nil)
    }

    @Test func aPrimaryOnlyPacketSplitsToJustItself() throws {
        let frame = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let payload = Data(primaryHeader(payloadType: 111) + [UInt8](frame))
        let blocks = try #require(NvstRedAudio.split(payload))
        #expect(blocks.count == 1)
        #expect(blocks[0].payload == frame)
        #expect(blocks[0].isPrimary)
    }

    @Test func declaredLengthsThatOverrunThePacketAreRejected() {
        // Claims 40 bytes of repeat in a packet holding two: corrupt, not merely empty.
        let payload = Data(redundantHeader(payloadType: 111, timestampOffset: 240, length: 40)
            + primaryHeader(payloadType: 111)
            + [0xAA, 0xBB]
            + [0xCC])
        #expect(NvstRedAudio.split(payload) == nil)
    }

    @Test func aTruncatedRedundantHeaderIsRejected() {
        // The F bit promises a four-byte header but only two bytes remain.
        #expect(NvstRedAudio.split(Data([0x80 | 111, 0x00])) == nil)
        #expect(NvstRedAudio.split(Data()) == nil)
    }
}
