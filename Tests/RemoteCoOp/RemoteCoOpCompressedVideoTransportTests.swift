import Foundation
import Testing
@testable import OpenNOW

/// The compressed-video framing a native Co-Op guest depends on: the host's source access units must
/// survive fragmentation, out-of-order delivery and loss. These prove the framing, not a loopback of
/// our own decoder, so they hold regardless of which transport eventually carries the datagrams.
@Suite struct RemoteCoOpCompressedVideoTransportTests {
    private func frame(payload: Data,
                       isKeyFrame: Bool = true,
                       codec: NativeNVSTVideoCodec = .h264,
                       streamID: UInt32 = 7,
                       nanoseconds: UInt64 = 1_234_567_890,
                       durationNanoseconds: UInt64 = 16_666_667) -> NativeNVSTVideoFrame {
        NativeNVSTVideoFrame(streamID: streamID,
                             codec: codec,
                             timestamp: MediaTimestamp(nanoseconds: nanoseconds),
                             durationNanoseconds: durationNanoseconds,
                             width: 0,
                             height: 0,
                             isKeyFrame: isKeyFrame,
                             payload: payload)
    }

    private func patternedPayload(_ count: Int, seed: UInt8 = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ Int(seed)) })
    }

    private func ingest(_ datagrams: [Data], into reassembler: OPNRemoteCoOpCompressedVideoReassembler) -> [NativeNVSTVideoFrame] {
        datagrams.compactMap { reassembler.ingest($0) }
    }

    @Test func aKeyframeRoundTripsWithItsMetadata() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        let source = frame(payload: patternedPayload(200), isKeyFrame: true, codec: .h265, streamID: 42)

        let emitted = ingest(fragmenter.fragments(for: source), into: reassembler)

        #expect(emitted.count == 1)
        let result = emitted.first
        #expect(result?.payload == source.payload)
        #expect(result?.isKeyFrame == true)
        #expect(result?.codec == .h265)
        #expect(result?.streamID == 42)
        #expect(result?.timestamp == source.timestamp)
        #expect(result?.durationNanoseconds == source.durationNanoseconds)
    }

    @Test func anAccessUnitLargerThanTheMtuReassemblesByteForByteOutOfOrder() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        // A 5K access unit is ~90 KB; 80 KB forces tens of fragments.
        let source = frame(payload: patternedPayload(80_000), isKeyFrame: true)

        let datagrams = fragmenter.fragments(for: source)
        #expect(datagrams.count > 50)

        let emitted = ingest(datagrams.reversed(), into: reassembler)

        #expect(emitted.count == 1)
        #expect(emitted.first?.payload == source.payload)
        #expect(reassembler.snapshot.framesEmitted == 1)
        #expect(reassembler.snapshot.framesDropped == 0)
        #expect(reassembler.snapshot.rejected == 0)
    }

    @Test func aPayloadSliceWithANonZeroStartIndexStillFragments() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        // A live access unit can arrive as a slice of a larger buffer, whose `startIndex` is not 0;
        // indexing it with frame-relative offsets is what trapped the decode thread.
        let backing = patternedPayload(5_000)
        let sliced = backing[100..<4_000]
        #expect(sliced.startIndex == 100)
        let source = frame(payload: sliced)

        let emitted = ingest(fragmenter.fragments(for: source), into: reassembler)

        #expect(emitted.count == 1)
        #expect(emitted.first?.payload == Data(sliced))
    }

    @Test func aRestartedSenderWithALowerSequenceIsAccepted() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let first = OPNRemoteCoOpCompressedVideoFragmenter()
        let firstFrame = frame(payload: patternedPayload(400))
        // Advance the first sender several frames so a restart's sequence 0 looks stale to a
        // reassembler that tracked only sequences.
        for _ in 0..<4 { _ = first.fragments(for: firstFrame) }
        #expect(ingest(first.fragments(for: firstFrame), into: reassembler).count == 1)

        let restarted = OPNRemoteCoOpCompressedVideoFragmenter()
        let afterRestart = frame(payload: patternedPayload(900))
        let emitted = ingest(restarted.fragments(for: afterRestart), into: reassembler)

        #expect(emitted.count == 1)
        #expect(emitted.first?.payload == afterRestart.payload)
    }

    @Test func aFrameWithALostFragmentIsDroppedAndTheNextFrameSurvives() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        let large = frame(payload: patternedPayload(5_000), isKeyFrame: true)

        var lost = fragmenter.fragments(for: large)
        let dropped = lost.remove(at: 1)
        #expect(ingest(lost, into: reassembler).isEmpty)

        let recovery = frame(payload: patternedPayload(120), isKeyFrame: true)
        let emitted = ingest(fragmenter.fragments(for: recovery), into: reassembler)

        #expect(emitted.count == 1)
        #expect(emitted.first?.payload == recovery.payload)
        #expect(reassembler.snapshot.framesDropped == 1)
        // The late survivor of the abandoned frame must not resurrect it.
        #expect(reassembler.ingest(dropped) == nil)
        #expect(reassembler.snapshot.framesEmitted == 1)
    }

    @Test func aRepeatedFragmentDoesNotCompleteTheFrameEarly() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        let source = frame(payload: patternedPayload(3_000))
        let datagrams = fragmenter.fragments(for: source)
        #expect(datagrams.count >= 3)

        #expect(reassembler.ingest(datagrams[0]) == nil)
        #expect(reassembler.ingest(datagrams[1]) == nil)
        #expect(reassembler.ingest(datagrams[1]) == nil)
        #expect(reassembler.snapshot.framesEmitted == 0)

        var emitted: [NativeNVSTVideoFrame] = []
        for datagram in datagrams.dropFirst(2) { if let frame = reassembler.ingest(datagram) { emitted.append(frame) } }
        #expect(emitted.count == 1)
        #expect(emitted.first?.payload == source.payload)
    }

    @Test func aFragmentFromASupersededFrameIsRejected() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        let first = frame(payload: patternedPayload(4_000))
        let second = frame(payload: patternedPayload(100))

        var firstFragments = fragmenter.fragments(for: first)
        let trailing = firstFragments.removeLast()
        #expect(reassembler.ingest(firstFragments[0]) == nil)

        #expect(ingest(fragmenter.fragments(for: second), into: reassembler).count == 1)
        #expect(reassembler.ingest(trailing) == nil)
        #expect(reassembler.snapshot.framesEmitted == 1)
        #expect(reassembler.snapshot.rejected >= 1)
    }

    @Test func aDuplicateFragmentAfterDeliveryIsRejected() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        let source = frame(payload: patternedPayload(64))
        let datagram = fragmenter.fragments(for: source)[0]

        #expect(reassembler.ingest(datagram)?.payload == source.payload)
        #expect(reassembler.ingest(datagram) == nil)
        #expect(reassembler.snapshot.framesEmitted == 1)
        #expect(reassembler.snapshot.rejected == 1)
    }

    @Test func anEmptyPayloadStillFramesAKeyframeBoundary() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        let source = frame(payload: Data(), isKeyFrame: true)

        let emitted = ingest(fragmenter.fragments(for: source), into: reassembler)

        #expect(emitted.count == 1)
        #expect(emitted.first?.payload.isEmpty == true)
        #expect(emitted.first?.isKeyFrame == true)
    }

    @Test func aDatagramWithTheWrongMagicIsRejected() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        var datagram = [UInt8](fragmenter.fragments(for: frame(payload: patternedPayload(32)))[0])
        datagram[0] ^= 0xFF

        #expect(reassembler.ingest(Data(datagram)) == nil)
        #expect(reassembler.snapshot.rejected == 1)
        #expect(reassembler.snapshot.framesEmitted == 0)
    }

    @Test func aTruncatedDatagramIsRejected() {
        let reassembler = OPNRemoteCoOpCompressedVideoReassembler()
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter()
        let datagram = fragmenter.fragments(for: frame(payload: patternedPayload(500)))[0]

        #expect(reassembler.ingest(datagram.prefix(10)) == nil)
        #expect(reassembler.snapshot.rejected == 1)
    }

    @Test func fragmentationKeepsEachDatagramWithinThePayloadCeiling() {
        let maximum = 900
        let fragmenter = OPNRemoteCoOpCompressedVideoFragmenter(maximumFragmentPayload: maximum)
        let source = frame(payload: patternedPayload(5 * maximum + 17))

        let datagrams = fragmenter.fragments(for: source)
        #expect(datagrams.count == 6)
        for datagram in datagrams {
            let decoded = OPNRemoteCoOpCompressedVideoPacket.decode(datagram)
            #expect(decoded != nil)
            #expect(Int(decoded?.header.payloadLength ?? .max) <= maximum)
        }
    }

    @Test func sequenceComparisonHandlesWraparound() {
        #expect(OPNRemoteCoOpCompressedVideoReassembler.isNewer(1, than: 0))
        #expect(!OPNRemoteCoOpCompressedVideoReassembler.isNewer(0, than: 1))
        #expect(!OPNRemoteCoOpCompressedVideoReassembler.isNewer(5, than: 5))
        #expect(OPNRemoteCoOpCompressedVideoReassembler.isNewer(2, than: 0xFFFF_FFFF))
        #expect(!OPNRemoteCoOpCompressedVideoReassembler.isNewer(0xFFFF_FFFF, than: 2))
    }
}
