import Foundation
import Testing
@testable import OpenNOW

/// The bundle socket carries DTLS and SRTP together, and the two are separated by nothing more than
/// the first byte. Feeding one to the other breaks the association, so the boundaries are pinned.
@Suite struct NvstBundleDatagramDemuxTests {
    @Test func dtlsRecordTypesGoToTheAssociation() {
        for type: UInt8 in [20, 21, 22, 23, 24, 63] {
            let datagram = Data([type, 0xFE, 0xFD, 0x00])
            #expect(NvstBundleDatagramDemux.classify(datagram) == .dtls(datagram), "content type \(type)")
        }
    }

    @Test func rtpAndRtcpGoToTheAudioPath() {
        // A valid RTP first byte is version 2 in the top bits, then padding/extension/CSRC count, so
        // the whole range is 0x80…0xBF: 0x8F is the highest CSRC count, 0xBF adds padding and
        // extension.
        for first: UInt8 in [0x80, 0x8F, 0x9F, 0xBF] {
            let datagram = Data([first, 0x00, 0x01, 0x02])
            #expect(NvstBundleDatagramDemux.classify(datagram) == .srtp(datagram), "first byte \(first)")
        }
        #expect(NvstBundleDatagramDemux.classify(Data([128, 0])) == .srtp(Data([128, 0])))
        #expect(NvstBundleDatagramDemux.classify(Data([191, 0])) == .srtp(Data([191, 0])))
    }

    @Test func theGapBetweenTheTwoRangesIsNotAssumedToBeOneOfThem() {
        // 64…127 belongs to neither: RTP would need the version bits set, DTLS does not use it.
        for first: UInt8 in [0, 19, 64, 100, 127, 192, 255] {
            #expect(NvstBundleDatagramDemux.classify(Data([first, 0x00])) == .unknown, "first byte \(first)")
        }
    }

    @Test func stunIsSeparatedFromBothMediaPlanes() throws {
        // The punch shares this socket, so it must be recognised and never fed to the record layer.
        let request = try #require(NvstStunHolePunch.buildBindingRequest(
            transactionID: Data(repeating: 0x5a, count: 12),
            username: "e503c1fe47999:abcd",
            integrityKey: Data("secret".utf8)
        ))
        #expect(NvstBundleDatagramDemux.classify(request) == .stun(request))
    }

    @Test func aStunLookalikeWithoutTheCookieIsNotStun() {
        // Two zero bits and the right length are not enough; the magic cookie is what decides.
        var header = Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        header.append(Data(repeating: 0, count: 12))
        #expect(NvstBundleDatagramDemux.classify(header) == .unknown)
        #expect(NvstBundleDatagramDemux.classify(Data([0x00, 0x01])) == .unknown)
    }

    @Test func anEmptyDatagramIsNotMistakenForAnything() {
        #expect(NvstBundleDatagramDemux.classify(Data()) == .unknown)
    }
}
