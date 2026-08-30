import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized)
struct NvstMjolnirReceiverTests {
    @Test func authenticatedPacketsReassembleIntoAnAnnexBAccessUnit() throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let sof = NvstReceiverFixtures.packet(sequence: 1, frameIndex: 42, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65])
        let eof = NvstReceiverFixtures.packet(sequence: 2, frameIndex: 42, flags: 0x03, media: [0x00, 0x00, 0x01, 0x41])

        #expect(NvstReceiverFixtures.frames(receiver.process(datagram: try NvstReceiverFixtures.seal(sof, sequence: 1, handoff: handoff))).isEmpty)
        let emitted = NvstReceiverFixtures.frames(receiver.process(datagram: try NvstReceiverFixtures.seal(eof, sequence: 2, handoff: handoff)))
        #expect(emitted.count == 1)
        #expect(emitted[0].bytes == Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x00, 0x00, 0x01, 0x41]))
        #expect(emitted[0].isKeyframe)
        let stats = receiver.snapshot
        #expect(stats.authenticatedPackets == 2)
        #expect(stats.framesEmitted == 1)
        #expect(stats.keyframesEmitted == 1)
        #expect(stats.boundSSRC == NvstReceiverFixtures.mediaSSRC)
    }

    @Test func theSixteenByteTagProfileAuthenticatesToo() throws {
        // The seat advertises AEAD_AES_256_GCM explicitly on some builds; the tag is 16 bytes
        // there, not NVIDIA's default 8.
        let handoff = NvstReceiverFixtures.makeHandoff(profile: .aeadAes256Gcm)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let unit = NvstReceiverFixtures.packet(sequence: 7, frameIndex: 1, flags: 0x07, media: [0x00, 0x00, 0x00, 0x01, 0x65])
        let emitted = NvstReceiverFixtures.frames(receiver.process(datagram: try NvstReceiverFixtures.seal(unit, sequence: 7, handoff: handoff)))
        #expect(emitted.count == 1)
    }

    @Test func aesCmProfilesAreRejectedRatherThanMisDecrypted() {
        #expect(throws: NvstVideoReceiver.ReceiverError.unsupportedProfile("AES_CM_128_HMAC_SHA1_80")) {
            _ = try NvstVideoReceiver(handoff: NvstReceiverFixtures.makeHandoff(profile: .aesCm128HmacSha1_80))
        }
    }

    @Test func tamperedAndReplayedPacketsAreDropped() throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let sof = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 5, frameIndex: 9, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65]), sequence: 5, handoff: handoff)
        #expect(NvstReceiverFixtures.frames(receiver.process(datagram: sof)).isEmpty)
        // Same packet again: the replay window must reject it.
        #expect(!NvstReceiverFixtures.drops(receiver.process(datagram: sof)).isEmpty)

        var tampered = sof
        tampered[tampered.count - 3] ^= 0x40
        #expect(!NvstReceiverFixtures.drops(receiver.process(datagram: tampered)).isEmpty)
    }

    @Test func aPacketFromAForeignSsrcNeverJoinsTheStream() throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstVideoReceiver(handoff: handoff)
        var foreign = NvstReceiverFixtures.packet(sequence: 1, frameIndex: 1, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65])
        foreign.replaceSubrange(8..<12, with: Data([0xde, 0xad, 0xbe, 0xef]))
        // Sealed under its own SSRC so authentication passes; only the handoff disagrees.
        let datagram = try NvstReceiverFixtures.seal(foreign, sequence: 1, handoff: handoff, ssrc: 0xdead_beef)
        let events = receiver.process(datagram: datagram)
        #expect(NvstReceiverFixtures.drops(events).contains { $0.contains("SSRC") })
        #expect(receiver.snapshot.boundSSRC == nil)
    }

    /// One lost packet used to take its whole reorder window with it: the finalizing flush
    /// destroyed every packet buffered behind the gap, so a single loss cost 32 packets and the
    /// frames they carried — uncounted, because the destroyed packets hit no drop counter.
    @Test func aSingleLostPacketDeliversTheBufferedPacketsBehindIt() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let media: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65]
        // A complete single-packet frame per sequence number. Sequence 2 never arrives.
        let first = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 1, frameIndex: 1, flags: 0x07, media: media), sequence: 1, handoff: handoff)
        #expect(NvstReceiverFixtures.frames(receiver.process(datagram: first)).count == 1)
        for sequence in UInt16(3)...UInt16(5) {
            let held = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: sequence, frameIndex: UInt32(sequence), flags: 0x07, media: media),
                                sequence: sequence, handoff: handoff)
            // Head-of-line blocked on the missing packet, not dropped.
            #expect(NvstReceiverFixtures.frames(receiver.process(datagram: held)).isEmpty)
        }
        // Sequence 6 ages the gap past the window: 2 is finalized loss, 3...6 must all deliver.
        let sixth = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 6, frameIndex: 6, flags: 0x07, media: media), sequence: 6, handoff: handoff)
        let events = receiver.process(datagram: sixth)
        #expect(NvstReceiverFixtures.frames(events).count == 4)
        #expect(NvstReceiverFixtures.recoveries(events) == 1)
        let stats = receiver.snapshot
        #expect(stats.framesEmitted == 5)
        #expect(stats.recoveries == 1)
        #expect(stats.finalizedLossPackets == 1)
        #expect(stats.droppedPackets == 0)
    }

    /// A second gap among the survivors finalizes on its own later packet rather than being
    /// silently absorbed by the first flush.
    @Test func interleavedGapsFinalizeIndependently() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let media: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65]
        func feed(_ sequence: UInt16) throws -> [NvstReceiveEvent] {
            receiver.process(datagram: try NvstReceiverFixtures.seal(
                NvstReceiverFixtures.packet(sequence: sequence, frameIndex: UInt32(sequence), flags: 0x07, media: media),
                sequence: sequence, handoff: handoff))
        }
        _ = try feed(1)
        // 2 and 4 never arrive; 3 and 5 wait behind 2.
        #expect(NvstReceiverFixtures.frames(try feed(3)).isEmpty)
        #expect(NvstReceiverFixtures.frames(try feed(5)).isEmpty)
        // 6 finalizes the loss of 2 and delivers 3; 4 is still an open gap holding 5 and 6.
        #expect(NvstReceiverFixtures.frames(try feed(6)).count == 1)
        // 8 finalizes the loss of 4 and delivers 5, 6 — 7 is now the open gap holding 8.
        let events = try feed(8)
        #expect(NvstReceiverFixtures.frames(events).count == 2)
        let stats = receiver.snapshot
        #expect(stats.finalizedLossPackets == 2)
        #expect(stats.recoveries == 2)
    }

    /// A hole in the GS stream sequence with contiguous RTP delivery has no RTP packet to NACK:
    /// it must ask for a keyframe, not a retransmission of an arbitrary sequence number.
    @Test func aStreamSequenceHoleAsksForAKeyframeNotARetransmission() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let sof = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 1, frameIndex: 7, flags: 0x05, media: [0x00, 0x00, 0x00, 0x01, 0x65]),
                           sequence: 1, handoff: handoff)
        #expect(NvstReceiverFixtures.frames(receiver.process(datagram: sof)).isEmpty)
        // Contiguous RTP sequence 2, but the GS stream index jumps to 5: a slot was consumed
        // upstream, no RTP packet is missing.
        let midFrameHole = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: 2, frameIndex: 7, flags: 0x01, media: [0xbb], streamSequence: 5),
                                    sequence: 2, handoff: handoff)
        let events = receiver.process(datagram: midFrameHole)
        #expect(NvstReceiverFixtures.frames(events).isEmpty)
        #expect(NvstReceiverFixtures.recoveries(events) == 0)
        let chainBreaks = events.filter { if case .chainBroken = $0 { return true } else { return false } }.count
        #expect(chainBreaks == 1)
        let stats = receiver.snapshot
        #expect(stats.recoveries == 1)
        #expect(stats.finalizedLossPackets == 0)
    }

    /// The live 5K/120 failure shape: multi-packet frames, one packet lost mid-frame. Only the
    /// frame carrying the hole may be lost — the frames behind it ride on packets the old flush
    /// destroyed wholesale.
    @Test func oneLostPacketInsideAFrameCostsExactlyThatFrame() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 32)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let packetsPerFrame: UInt16 = 50
        let droppedSequence: UInt16 = 75 // mid-frame 2
        var emitted = 0
        let sofBytes: [UInt8] = [0x00, 0x00, 0x00, 0x01, 0x65]
        for frame in UInt16(1)...UInt16(3) {
            for position in UInt16(0)..<packetsPerFrame {
                let sequence = (frame - 1) * packetsPerFrame + position + 1
                guard sequence != droppedSequence else { continue }
                var flags: UInt8 = 0x01
                if position == 0 { flags |= 0x04 }
                if position == packetsPerFrame - 1 { flags |= 0x02 }
                let media: [UInt8] = position == 0 ? sofBytes : [UInt8(truncatingIfNeeded: sequence)]
                let datagram = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: sequence, frameIndex: UInt32(frame), flags: flags, media: media),
                                        sequence: sequence, handoff: handoff)
                emitted += NvstReceiverFixtures.frames(receiver.process(datagram: datagram)).count
            }
        }
        let stats = receiver.snapshot
        // Frame 2 has the hole; frames 1 and 3 must both survive.
        #expect(emitted == 2)
        #expect(stats.framesEmitted == 2)
        #expect(stats.finalizedLossPackets == 1)
        #expect(stats.recoveries == 1)
        // The frame-2 remnants behind the hole are individually rejected by the reassembler as
        // awaiting-start-of-frame; that is the expected local cost, not extra frame loss.
        #expect(stats.abandonedFrames == 0)
    }

    /// Several isolated losses across a long stream each cost one frame and one loss count —
    /// no compounding, no stuck reassembler, no double-counted recovery.
    @Test func isolatedLossesAcrossAStreamDoNotCompound() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 32)
        let receiver = try NvstVideoReceiver(handoff: handoff)
        let packetsPerFrame: UInt16 = 30
        let frameCount: UInt16 = 20
        let dropped: Set<UInt16> = [100, 250, 400] // frames 4, 9, 14 — all far from the stream tail
        var emitted = 0
        for frame in UInt16(1)...frameCount {
            for position in UInt16(0)..<packetsPerFrame {
                let sequence = (frame - 1) * packetsPerFrame + position + 1
                guard !dropped.contains(sequence) else { continue }
                var flags: UInt8 = 0x01
                if position == 0 { flags |= 0x04 }
                if position == packetsPerFrame - 1 { flags |= 0x02 }
                let media: [UInt8] = position == 0 ? [0x00, 0x00, 0x00, 0x01, 0x65] : [UInt8(truncatingIfNeeded: sequence)]
                let datagram = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: sequence, frameIndex: UInt32(frame), flags: flags, media: media),
                                        sequence: sequence, handoff: handoff)
                emitted += NvstReceiverFixtures.frames(receiver.process(datagram: datagram)).count
            }
        }
        let stats = receiver.snapshot
        #expect(emitted == Int(frameCount) - dropped.count)
        #expect(stats.finalizedLossPackets == UInt64(dropped.count))
        #expect(stats.recoveries == UInt64(dropped.count))
    }

    /// End to end through SRTP, parse, FEC recovery, reorder and reassembly: a lost source packet
    /// is rebuilt from the block's parity packet, the frame still emits, and no loss is recorded —
    /// the seat never learns anything was lost.
    @Test func aLostPacketIsRepairedFromParityAndTheFrameStillEmits() throws {
        let handoff = NvstReceiverFixtures.makeHandoff()
        let receiver = try NvstVideoReceiver(handoff: handoff)

        func fecWord(index: UInt32) -> UInt32 { (50 << 4) | (index << 12) | (2 << 22) }
        // One frame per FEC block: two sources (SOF, EOF) and one parity shard (50% of 2).
        func blockPackets(frameIndex: UInt32, baseSequence: UInt16, seed: UInt8) -> [(UInt16, Data)] {
            let sof = NvstReceiverFixtures.packet(sequence: baseSequence, frameIndex: frameIndex, flags: 0x05,
                             media: [0x00, 0x00, 0x00, 0x01, 0x65, seed], fecWord: fecWord(index: 0))
            let eof = NvstReceiverFixtures.packet(sequence: baseSequence + 1, frameIndex: frameIndex, flags: 0x03,
                             media: [0xbb, seed, 0xcc], fecWord: fecWord(index: 1))
            let size = max(sof.count, eof.count)
            let shards = [sof, eof].map { source -> [UInt8] in
                let bytes = [UInt8](source)
                return bytes.count == size ? bytes : bytes + [UInt8](repeating: 0, count: size - bytes.count)
            }
            let parity = NvstReedSolomon.encode(data: shards, parityCount: 1, size: size)!
            let parityHeader = NvstReceiverFixtures.packet(sequence: baseSequence + 2, frameIndex: frameIndex, flags: 0x00,
                                      media: [], fecWord: fecWord(index: 2))
            let parityPacket = parityHeader + Data(parity[0][NvstFecRecovery.headerLength...])
            return [(baseSequence, sof), (baseSequence + 1, eof), (baseSequence + 2, parityPacket)]
        }

        // Clean blocks first: recovery arms only after verifying the scheme against this stream.
        var emitted = 0
        for round in 0..<NvstFecRecovery.verificationTarget {
            for (sequence, plain) in blockPackets(frameIndex: UInt32(round + 1),
                                                  baseSequence: UInt16(round * 3 + 1),
                                                  seed: UInt8(round)) {
                emitted += NvstReceiverFixtures.frames(receiver.process(datagram: try NvstReceiverFixtures.seal(plain, sequence: sequence, handoff: handoff))).count
            }
        }
        #expect(emitted == NvstFecRecovery.verificationTarget)
        #expect(receiver.fecFindings.isArmed)

        // The lossy frame: its start-of-frame packet never arrives.
        let base = UInt16(NvstFecRecovery.verificationTarget * 3 + 1)
        let lossy = blockPackets(frameIndex: UInt32(NvstFecRecovery.verificationTarget + 1),
                                 baseSequence: base, seed: 0x42)
        #expect(NvstReceiverFixtures.frames(receiver.process(datagram: try NvstReceiverFixtures.seal(lossy[1].1, sequence: lossy[1].0, handoff: handoff))).isEmpty)
        let events = receiver.process(datagram: try NvstReceiverFixtures.seal(lossy[2].1, sequence: lossy[2].0, handoff: handoff))
        #expect(NvstReceiverFixtures.frames(events).count == 1)
        #expect(NvstReceiverFixtures.frames(events).first?.isKeyframe == true)
        #expect(NvstReceiverFixtures.recoveries(events) == 0)

        let stats = receiver.snapshot
        #expect(stats.finalizedLossPackets == 0)
        #expect(stats.recoveries == 0)
        #expect(receiver.fecFindings.recoveredPackets == 1)
        #expect(stats.framesEmitted == UInt64(NvstFecRecovery.verificationTarget) + 1)
    }

    /// With FEC armed, a gap outlives the plain reorder window: the block's parity — the repair —
    /// arrives after all of the block's sources, so finalizing at the plain window would lose the
    /// race and turn a repairable hole into a lost frame plus a keyframe round trip.
    @Test func anOpenGapWaitsForFecRepairBeforeBecomingLoss() throws {
        let handoff = NvstReceiverFixtures.makeHandoff(reorderWindow: 4)
        let receiver = try NvstVideoReceiver(handoff: handoff)

        func fecWord(index: UInt32) -> UInt32 { (50 << 4) | (index << 12) | (2 << 22) }
        func blockPackets(frameIndex: UInt32, baseSequence: UInt16, seed: UInt8) -> [(UInt16, Data)] {
            let sof = NvstReceiverFixtures.packet(sequence: baseSequence, frameIndex: frameIndex, flags: 0x05,
                             media: [0x00, 0x00, 0x00, 0x01, 0x65, seed], fecWord: fecWord(index: 0))
            let eof = NvstReceiverFixtures.packet(sequence: baseSequence + 1, frameIndex: frameIndex, flags: 0x03,
                             media: [0xbb, seed, 0xcc], fecWord: fecWord(index: 1))
            let size = max(sof.count, eof.count)
            let shards = [sof, eof].map { source -> [UInt8] in
                let bytes = [UInt8](source)
                return bytes.count == size ? bytes : bytes + [UInt8](repeating: 0, count: size - bytes.count)
            }
            let parity = NvstReedSolomon.encode(data: shards, parityCount: 1, size: size)!
            let parityHeader = NvstReceiverFixtures.packet(sequence: baseSequence + 2, frameIndex: frameIndex, flags: 0x00,
                                      media: [], fecWord: fecWord(index: 2))
            return [(baseSequence, sof), (baseSequence + 1, eof),
                    (baseSequence + 2, parityHeader + Data(parity[0][NvstFecRecovery.headerLength...]))]
        }
        for round in 0..<NvstFecRecovery.verificationTarget {
            for (sequence, plain) in blockPackets(frameIndex: UInt32(round + 1),
                                                  baseSequence: UInt16(round * 3 + 1),
                                                  seed: UInt8(round)) {
                _ = receiver.process(datagram: try NvstReceiverFixtures.seal(plain, sequence: sequence, handoff: handoff))
            }
        }
        #expect(receiver.fecFindings.isArmed)

        // A jump well past the plain window (4) but inside the repair window: the gap must stay
        // open — no recovery event, no finalized loss — while repair still has a chance.
        let base = UInt16(NvstFecRecovery.verificationTarget * 3 + 1)
        let far = try NvstReceiverFixtures.seal(NvstReceiverFixtures.packet(sequence: base + 20, frameIndex: 99, flags: 0x05,
                                  media: [0x00, 0x00, 0x00, 0x01, 0x65]),
                           sequence: base + 20, handoff: handoff)
        let events = receiver.process(datagram: far)
        #expect(NvstReceiverFixtures.recoveries(events) == 0)
        #expect(NvstReceiverFixtures.frames(events).isEmpty)
        #expect(receiver.snapshot.finalizedLossPackets == 0)
    }

}

@Suite struct NvstInboundCounterTests {
    private func stun(messageType: UInt16) -> Data {
        var packet = Data()
        packet.append(UInt8(messageType >> 8))
        packet.append(UInt8(messageType & 0xff))
        packet.append(contentsOf: [0x00, 0x00])
        packet.append(contentsOf: [0x21, 0x12, 0xa4, 0x42]) // magic cookie
        packet.append(Data(repeating: 0x11, count: 12))
        return packet
    }

    @Test func datagramsAreCountedByClass() {
        var counters = NvstInboundCounters()
        counters.record(datagram: stun(messageType: 0x0001)) // Binding Request
        counters.record(datagram: stun(messageType: 0x0101)) // Binding Success
        counters.record(datagram: stun(messageType: 0x0111)) // Binding Error
        counters.record(datagram: Data([0x16, 0xfe, 0xfd, 0x00, 0x00, 0x01])) // DTLS handshake
        counters.record(datagram: Data([0x90, 0xe0, 0x00, 0x01, 0, 0, 0, 8, 0x11, 0x22, 0x33, 0x44])) // RTP
        counters.record(datagram: Data([0x01, 0x02, 0x03]))
        #expect(counters.stunRequests == 1)
        #expect(counters.stunSuccessResponses == 1)
        #expect(counters.stunErrorResponses == 1)
        #expect(counters.dtls == 1)
        #expect(counters.rtp == 1)
        #expect(counters.other == 1)
        #expect(counters.total == 6)
        #expect(counters.summary.contains("stunOk=1"))
        #expect(counters.summary.contains("rtp=1"))
    }

    @Test func anEmptySocketReportsNothingArrived() {
        // The decisive reading on a silent stream: zero inbound, non-zero punches out.
        var counters = NvstInboundCounters()
        counters.punchesSent = 40
        #expect(counters.total == 0)
        #expect(counters.summary.hasPrefix("in=0 "))
        #expect(counters.summary.contains("punchesOut=40"))
    }
}

@Suite struct NvstBundleIceProbeTests {
    private func handoff(withCredentials: Bool) -> NVSTVideoHandoff {
        NVSTVideoHandoff(
            clientUDPPort: 0,
            videoPeerIP: "192.0.2.20",
            videoPeerPort: 5004,
            srtpProfile: .aeadAes256Gcm8,
            srtpAESKey: Data(repeating: 0xab, count: 32),
            srtpSalt: Data(repeating: 0x9e, count: 12),
            codec: .h264,
            rtpPayloadType: 96,
            rtpSSRC: 0,
            reorderWindowPackets: 32,
            maxAccessUnitBytes: 1024,
            timeoutMilliseconds: 5000,
            pingVersion: 6,
            pingPayload: "3745882b47998",
            mjolnirUDPPort: 0,
            iceCredentials: withCredentials
                ? NVSTHandoffIceCredentials(
                    localUsernameFragment: "abcd",
                    localPassword: String(repeating: "p", count: 22),
                    remoteUsernameFragment: "3745882b47999",
                    remotePassword: "seatPassword",
                    remoteDTLSFingerprint: "AA:BB"
                )
                : nil
        )
    }

    @Test func theProbeNeedsASocketAndVersionSixCredentials() throws {
        #expect(throws: NvstBundleIceProbe.ProbeError.noSocket) {
            _ = try NvstBundleIceProbe(handoff: handoff(withCredentials: true), descriptor: -1)
        }
        let reservation = try NvstUdpPortReservation.bindEphemeral()
        let descriptor = reservation.takeDescriptor()
        #expect(throws: NvstBundleIceProbe.ProbeError.missingCredentials) {
            _ = try NvstBundleIceProbe(handoff: handoff(withCredentials: false), descriptor: descriptor)
        }
        close(descriptor)
    }

    @Test func theProbePunchesAndStopsCleanly() throws {
        let reservation = try NvstUdpPortReservation.bindEphemeral()
        let probe = try NvstBundleIceProbe(handoff: handoff(withCredentials: true), descriptor: reservation.takeDescriptor())
        probe.start()
        probe.stop()
        // Punches are counted even when the peer is a black hole, which is what makes a silent
        // socket diagnosable.
        #expect(probe.snapshot.total == 0)
    }

    @Test func transactionIdentifiersAreTwelveBytesAndVary() {
        let first = NvstBundleIceProbe.transactionID()
        let second = NvstBundleIceProbe.transactionID()
        #expect(first.count == 12)
        #expect(second.count == 12)
        #expect(first != second)
        #expect(NvstBundleIceProbe.iceBurstCount == 3)
        #expect(NvstBundleIceProbe.nattUsername == "PING")
    }
}
