import Foundation
import Testing
@testable import OpenNOW

/// The receive path end to end: real SRTP, a real dropped packet and a real reorder, then Opus
/// decoding. Asserting on PCM length and energy is the only way to check that a loss consumed its
/// 5 ms of timeline rather than shortening the stream.
@Suite struct NvstAudioReceivePipelineTests {
    private static let profile = NVSTSrtpProfile.aeadAes256Gcm8
    private static let framesPerPacket = 240
    private static let channels = 2

    private func makeSrtp() throws -> NvstAudioSrtp {
        try NvstAudioSrtp(masterKey: Data((0..<32).map { UInt8($0 &* 5 &+ 3) }),
                          masterSalt: Data((0..<12).map { UInt8($0 &* 11 &+ 7) }),
                          profile: Self.profile)
    }

    /// One packet of a 440 Hz stereo tone, already encoded, protected and ready to ingest.
    private func protectedTonePacket(srtp: NvstAudioSrtp, encoder: NvstOpusEncoder, sequence: UInt16, timestamp: UInt32) throws -> Data {
        var samples = [Float](repeating: 0, count: Self.framesPerPacket * Self.channels)
        for frame in 0..<Self.framesPerPacket {
            let value = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / 48_000.0)) * 0.5
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        var encoded: Data?
        for _ in 0..<8 where encoded == nil { encoded = try encoder.encode(samples) }
        let payload = try #require(encoded)
        let header = NvstAudioRtpPacket.headerBytes(payloadType: 111, marker: false, sequenceNumber: sequence, timestamp: timestamp, ssrc: 1)
        return try srtp.protect(header + payload)
    }

    @Test func aStreamWithARecordedLossDecodesWithItsTimelineIntact() throws {
        let srtp = try makeSrtp()
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: Self.framesPerPacket)
        let pipeline = try NvstAudioReceivePipeline(srtp: srtp, framesPerPacket: Self.framesPerPacket)

        var packets: [UInt16: Data] = [:]
        for sequence in UInt16(0)..<6 {
            packets[sequence] = try protectedTonePacket(srtp: srtp, encoder: encoder, sequence: sequence, timestamp: UInt32(sequence) * 240)
        }
        // Ingest out of order, and never ingest sequence 2 at all.
        for sequence in [UInt16(0), 1, 4, 3, 5] {
            pipeline.ingest(try #require(packets[sequence]))
        }
        _ = pipeline.pull()
        let tail = pipeline.flush()
        let counters = pipeline.snapshot

        #expect(counters.datagrams == 5)
        #expect(counters.authenticated == 5)
        #expect(counters.authenticationFailures == 0)
        #expect(counters.packetsLost == 1, "the missing sequence must be reported exactly once")
        // Six packets' worth of timeline comes out even though one never arrived. Converted to Int
        // explicitly: mixing UInt64 counters with Int lengths makes this expression expensive to
        // type-check and hard to read.
        let decodedSamples = Int(counters.packetsDecoded) * Self.framesPerPacket * Self.channels
        let concealedSamples = Int(counters.concealedFrames) * Self.channels
        let total = decodedSamples + concealedSamples + tail.count
        #expect(total >= 5 * Self.framesPerPacket * Self.channels)
    }

    @Test func aDatagramThatFailsItsTagIsDiscardedAndCounted() throws {
        let srtp = try makeSrtp()
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: Self.framesPerPacket)
        let pipeline = try NvstAudioReceivePipeline(srtp: srtp, framesPerPacket: Self.framesPerPacket)

        var tampered = [UInt8](try protectedTonePacket(srtp: srtp, encoder: encoder, sequence: 0, timestamp: 0))
        tampered[14] ^= 0xFF
        pipeline.ingest(Data(tampered))
        pipeline.ingest(try protectedTonePacket(srtp: srtp, encoder: encoder, sequence: 1, timestamp: 240))

        let counters = pipeline.snapshot
        #expect(counters.datagrams == 2)
        #expect(counters.authenticationFailures == 1)
        #expect(counters.authenticated == 1)
    }

    @Test func decodedAudioCarriesTheToneRatherThanSilence() throws {
        let srtp = try makeSrtp()
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: Self.framesPerPacket)
        let pipeline = try NvstAudioReceivePipeline(srtp: srtp, framesPerPacket: Self.framesPerPacket)

        for sequence in UInt16(0)..<5 {
            pipeline.ingest(try protectedTonePacket(srtp: srtp, encoder: encoder, sequence: sequence, timestamp: UInt32(sequence) * 240))
        }
        var pcm = pipeline.pull()
        pcm += pipeline.flush()
        let peak = pcm.map { abs($0) }.max() ?? 0
        #expect(peak > 0.1, "the decoded stream is silent (peak \(peak))")
    }

    @Test func aRepeatInsideALaterRedPacketRecoversALostFrame() throws {
        let srtp = try makeSrtp()
        let pipeline = try NvstAudioReceivePipeline(srtp: srtp, framesPerPacket: Self.framesPerPacket)

        // Distinct payloads, so recovery is identifiable by value and no codec is involved: this is
        // about the RED path, not about encoding.
        let frameOne = Data([0x01, 0x11])
        let frameTwo = Data([0x02, 0x22, 0x22])
        let frameThree = Data([0x03, 0x33, 0x33, 0x33])

        func packet(payloadType: UInt8, sequence: UInt16, timestamp: UInt32, payload: Data) throws -> Data {
            let header = NvstAudioRtpPacket.headerBytes(payloadType: payloadType, marker: false, sequenceNumber: sequence, timestamp: timestamp, ssrc: 1)
            return try srtp.protect(header + payload)
        }

        // Packet 3: a repeat of frame 2 (240 samples — one frame — back) then frame 3 as the primary.
        // Headers come first, then both payloads: the RED wire layout. The offset is fourteen bits
        // across the first two header bytes, the length ten across the last two.
        let repeatOffset: UInt32 = 240
        let repeatLength = frameTwo.count
        let redHeader: [UInt8] = [
            0x80 | 63,
            UInt8((repeatOffset >> 6) & 0xFF),
            UInt8((repeatOffset & 0x3F) << 2) | UInt8((repeatLength >> 8) & 0x03),
            UInt8(repeatLength & 0xFF),
        ]
        let redPayload = Data(redHeader + [63] + [UInt8](frameTwo) + [UInt8](frameThree))
        let redPacket = try packet(payloadType: 63, sequence: 3, timestamp: 720, payload: redPayload)

        // Frame 2's own packet never arrives; frames 1 and 3 do.
        pipeline.ingest(try packet(payloadType: 111, sequence: 1, timestamp: 240, payload: frameOne))
        pipeline.ingest(redPacket)

        _ = pipeline.pull()
        _ = pipeline.flush()
        let counters = pipeline.snapshot
        #expect(counters.malformedRedPackets == 0)
        #expect(counters.recoveredPackets == 1, "the repeat was not slotted back")
        #expect(counters.packetsLost == 0, "the repeat should have covered the loss")
    }

    @Test func aResetClearsTheOrderingState() throws {
        let srtp = try makeSrtp()
        let pipeline = try NvstAudioReceivePipeline(srtp: srtp, framesPerPacket: Self.framesPerPacket)
        pipeline.reset()
        #expect(pipeline.snapshot.packetsLost == 0)
    }

    @Test func reorderedPacketsAcrossSequenceRolloverAuthenticateWithoutReplaying() throws {
        let srtp = try makeSrtp()
        let pipeline = try NvstAudioReceivePipeline(srtp: srtp)
        func packet(sequence: UInt16, rollover: UInt32) throws -> Data {
            let header = NvstAudioRtpPacket.headerBytes(payloadType: 111, marker: false, sequenceNumber: sequence, timestamp: 0, ssrc: 1)
            return try srtp.protect(header + Data([0x01, 0x02]), rolloverCounter: rollover)
        }
        pipeline.ingest(try packet(sequence: 65_534, rollover: 0))
        var forged = try packet(sequence: 0, rollover: 1)
        forged[forged.count - 1] ^= 1
        pipeline.ingest(forged)
        pipeline.ingest(try packet(sequence: 0, rollover: 1))
        pipeline.ingest(try packet(sequence: 65_535, rollover: 0))
        pipeline.ingest(try packet(sequence: 1, rollover: 1))
        pipeline.ingest(try packet(sequence: 0, rollover: 1))
        #expect(pipeline.snapshot.authenticated == 4)
        #expect(pipeline.snapshot.authenticationFailures == 1)
        #expect(pipeline.snapshot.replayDrops == 1)
    }

    @Test func deviceSizedPullsPreserveEveryDecodedSample() throws {
        let srtp = try makeSrtp()
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: Self.framesPerPacket)
        let reference = try NvstAudioReceivePipeline(srtp: srtp, targetDepth: 0)
        let device = try NvstAudioReceivePipeline(srtp: srtp, targetDepth: 0)
        for sequence in UInt16(0)..<6 {
            let packet = try protectedTonePacket(srtp: srtp, encoder: encoder, sequence: sequence, timestamp: UInt32(sequence) * 240)
            reference.ingest(packet)
            device.ingest(packet)
        }
        let expected = reference.pull()
        var received: [Float] = []
        for _ in 0..<20 {
            let samples = device.pull(sampleCount: 256)
            if samples.isEmpty { break }
            received.append(contentsOf: samples)
        }
        #expect(!expected.isEmpty)
        #expect(received == expected)
    }
}
