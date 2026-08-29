import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized)
struct NvstAnnexBTests {

    @Test func findStartCodeFindsFourByteFirst() {
        let data = Data([0x00, 0x00, 0x00, 0x01, 0x65])
        let found = NvstAnnexB.findStartCode(data)
        #expect(found?.offset == 0)
        #expect(found?.prefixLength == 4)
    }

    @Test func findStartCodeFallsBackToThreeByte() {
        let data = Data([0x0a, 0x0b, 0x00, 0x00, 0x01, 0x65])
        let found = NvstAnnexB.findStartCode(data)
        #expect(found?.offset == 2)
        #expect(found?.prefixLength == 3)
    }

    @Test func theEarliestStartCodeWinsRegardlessOfLength() {
        // Scanning the whole buffer for the four-byte form first would skip an earlier three-byte
        // start code and hand the decoder a truncated access unit.
        let data = Data([0x00, 0x00, 0x01, 0x65, 0xaa, 0x00, 0x00, 0x00, 0x01, 0x41])
        let found = NvstAnnexB.findStartCode(data)
        #expect(found?.offset == 0)
        #expect(found?.prefixLength == 3)
        // A four-byte code that genuinely comes first still wins.
        let fourFirst = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x00, 0x00, 0x01, 0x41])
        #expect(NvstAnnexB.findStartCode(fourFirst)?.prefixLength == 4)
        #expect(NvstAnnexB.findStartCode(Data([0x01, 0x02])) == nil)
    }

    @Test func isKeyframeDetectsIdrNalTypeFive() {
        // SPS(7) + PPS(8) + IDR(5)
        let keyframe = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x00, 0x00, 0x00, 0x01, 0x68, 0x00, 0x00, 0x00, 0x01, 0x65, 0x88])
        #expect(NvstAnnexB.isKeyframe(keyframe))
        // Non-IDR slice (1)
        let nonKeyframe = Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x88])
        #expect(!NvstAnnexB.isKeyframe(nonKeyframe))
    }

    @Test func picturePayloadTrimsToFirstStartCode() {
        // GS metadata precedes the actual NAL start code.
        let data = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x00, 0x00, 0x00, 0x01, 0x65, 0x77])
        let payload = NvstAnnexB.picturePayload(data)
        #expect(payload == Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x77]))
    }

    @Test func datagramClassifierDistinguishesTypes() {
        let rtp = Data([0x90, 0xe0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x08, 0x11, 0x22, 0x33, 0x44])
        let stun = Data([0x00, 0x01, 0x00, 0x4c, 0x21, 0x12, 0xa4, 0x42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let dtls = Data([0x16, 0xfe, 0xfd, 0x00, 0x00, 0x01])
        #expect(NvstDatagramClassifier.looksLikeRTP(rtp))
        #expect(NvstDatagramClassifier.looksLikeSTUN(stun))
        #expect(NvstDatagramClassifier.looksLikeDTLS(dtls))
        #expect(NvstDatagramClassifier.rtpSSRC(rtp) == 0x1122_3344)
        #expect(!NvstDatagramClassifier.looksLikeRTP(stun))
        #expect(!NvstDatagramClassifier.looksLikeRTP(dtls))
    }

    @Test func routedIPv4DiscoveryReturnsAddressOrNil() {
        let address = NvstRoutedIPv4.discover()
        // On a networked dev machine this resolves; on isolated runners it is nil. Either is
        // valid — the point is the probe path runs without crashing.
        #expect(address == nil || address?.split(separator: ".").count == 4)
    }
}

@Suite struct NvstElementaryStreamTests {
    /// SPS(7) + PPS(8) + AUD(9) + IDR(5), Annex-B delimited with mixed 3- and 4-byte prefixes.
    private static let h264AccessUnit = Data([
        0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0xe0,
        0x00, 0x00, 0x01, 0x68, 0xce,
        0x00, 0x00, 0x00, 0x01, 0x09, 0x10,
        0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84,
    ])

    @Test func nalUnitsSpanBothStartCodeLengths() {
        let units = NvstAnnexB.nalUnits(Self.h264AccessUnit)
        #expect(units.map(\.length) == [3, 2, 2, 3])
        #expect(units.map(\.offset) == [4, 10, 16, 22])
    }

    @Test func parameterSetsAreLiftedOutOfAKeyframe() {
        let sets = NvstElementaryStream.parameterSets(in: Self.h264AccessUnit, codec: .h264)
        #expect(sets.sequenceParameterSets == [Data([0x67, 0x42, 0xe0])])
        #expect(sets.pictureParameterSets == [Data([0x68, 0xce])])
        #expect(sets.videoParameterSets.isEmpty)
        #expect(sets.isComplete)
        // H.264 wants SPS then PPS; HEVC prepends VPS.
        #expect(sets.ordered == [Data([0x67, 0x42, 0xe0]), Data([0x68, 0xce])])
    }

    @Test func hevcParameterSetsUseTheSixBitNalType() {
        // VPS(32) + SPS(33) + PPS(34) + IDR_W_RADL(19)
        let unit = Data([
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x42, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x44, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xaf,
        ])
        let sets = NvstElementaryStream.parameterSets(in: unit, codec: .hevc)
        #expect(sets.videoParameterSets == [Data([0x40, 0x01])])
        #expect(sets.sequenceParameterSets == [Data([0x42, 0x01])])
        #expect(sets.pictureParameterSets == [Data([0x44, 0x01])])
        #expect(sets.ordered.count == 3)
        #expect(NvstAnnexB.isKeyframe(unit, codec: .hevc))
        // The H.264 reading of the same bytes must not accidentally match.
        #expect(!NvstAnnexB.isKeyframe(unit, codec: .h264))
    }

    @Test func pictureNalUnitsExcludeParameterSetsAndDelimiters() {
        let units = NvstElementaryStream.pictureNalUnits(in: Self.h264AccessUnit, codec: .h264)
        #expect(units == [Data([0x65, 0x88, 0x84])])
    }

    @Test func sampleDataIsFourByteLengthPrefixed() {
        let sample = NvstElementaryStream.sampleData(for: Self.h264AccessUnit, codec: .h264)
        #expect(sample == Data([0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84]))
        // Two NAL units keep their own prefixes.
        let two = NvstElementaryStream.lengthPrefixed([Data([0xaa]), Data([0xbb, 0xcc])])
        #expect(two == Data([0, 0, 0, 1, 0xaa, 0, 0, 0, 2, 0xbb, 0xcc]))
    }

    @Test func aDeltaFrameCarriesNoParameterSets() {
        let delta = Data([0x00, 0x00, 0x00, 0x01, 0x41, 0x9a])
        let sets = NvstElementaryStream.parameterSets(in: delta, codec: .h264)
        #expect(!sets.isComplete)
        #expect(NvstElementaryStream.pictureNalUnits(in: delta, codec: .h264) == [Data([0x41, 0x9a])])
    }

    /// `prepare` is the single copy-free pass the decoder actually runs, so it must agree with
    /// the split helpers: parameter sets and the AUD lifted out, the IDR length-prefixed.
    @Test func prepareSplitsParameterSetsAndLengthPrefixesThePictureInOnePass() {
        let prepared = NvstElementaryStream.prepare(Self.h264AccessUnit, codec: .h264)
        #expect(prepared.parameterSets.sequenceParameterSets == [Data([0x67, 0x42, 0xe0])])
        #expect(prepared.parameterSets.pictureParameterSets == [Data([0x68, 0xce])])
        #expect(prepared.sample == Data([0x00, 0x00, 0x00, 0x03, 0x65, 0x88, 0x84]))
    }

    @Test func preparePassesAv1ThroughUntouched() {
        let unit = Data([0x12, 0x00, 0x0a, 0x0b, 0x0c])
        let prepared = NvstElementaryStream.prepare(unit, codec: .av1)
        #expect(prepared.sample == unit)
        #expect(!prepared.parameterSets.isComplete)
    }
}
