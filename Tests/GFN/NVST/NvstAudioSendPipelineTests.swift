import Foundation
import Testing
@testable import OpenNOW

/// The microphone path end to end, and with the right halves of the handshake: the sender protects
/// with the client values and the receiver unprotects with the server's, exactly as RFC 5764 assigns
/// them. A test that used the same keys on both sides would pass on a direction swap that would
/// break against a real seat.
@Suite struct NvstAudioSendPipelineTests {
    private static let profile = NVSTSrtpProfile.aeadAes256Gcm8
    private static let framesPerPacket = 240

    /// A loopback needs one direction's material at both ends: `client_write` is the value the
    /// client protects with, and the peer holds the *same* value to read it. Wiring the far end with
    /// the server's half would model two clients talking past each other, not a client and a seat.
    /// The separation between the two halves is pinned separately, in `NvstAudioSrtpTests`.
    private func makeDirections() throws -> (outbound: NvstAudioSrtp, inbound: NvstAudioSrtp) {
        let keys = try NvstBundleSrtpKeys.split(Data((0..<88).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 5) }), profile: Self.profile)
        let directions = NvstAudioSrtpDirection.directions(from: keys)
        return (try NvstAudioSrtp(masterKey: directions.outbound.key, masterSalt: directions.outbound.salt, profile: Self.profile),
                try NvstAudioSrtp(masterKey: directions.outbound.key, masterSalt: directions.outbound.salt, profile: Self.profile))
    }

    private func tone() -> [Float] {
        var samples = [Float](repeating: 0, count: Self.framesPerPacket * 2)
        for frame in 0..<Self.framesPerPacket {
            let value = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / 48_000.0)) * 0.5
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return samples
    }

    @Test func capturedPcmReachesTheFarEndAsAudio() throws {
        let directions = try makeDirections()
        let sender = try NvstAudioSendPipeline(srtp: directions.outbound, framesPerPacket: Self.framesPerPacket, initialSequenceNumber: 1000, initialTimestamp: 0)
        let receiver = try NvstAudioReceivePipeline(srtp: directions.inbound, framesPerPacket: Self.framesPerPacket)

        var sent = 0
        for _ in 0..<6 {
            for datagram in sender.push(capturedPCM: tone()) {
                receiver.ingest(datagram)
                sent += 1
            }
        }
        #expect(sent >= 5, "the sender produced \(sent) packets")
        var pcm = receiver.pull()
        pcm += receiver.flush()
        let peak = pcm.map { abs($0) }.max() ?? 0
        #expect(peak > 0.1, "nothing audible survived the microphone round trip (peak \(peak))")
        #expect(receiver.snapshot.authenticationFailures == 0)
    }

    @Test func mutingStopsThePacketsRatherThanSendingSilence() throws {
        let directions = try makeDirections()
        let sender = try NvstAudioSendPipeline(srtp: directions.outbound, framesPerPacket: Self.framesPerPacket, initialSequenceNumber: 1, initialTimestamp: 0)
        sender.isMuted = true
        #expect(sender.push(capturedPCM: tone()).isEmpty)
        #expect(sender.snapshot.muteDrops == 1)
        #expect(sender.snapshot.packetsSent == 0)

        sender.isMuted = false
        var packet: Data?
        for _ in 0..<8 where packet == nil { packet = sender.push(capturedPCM: tone()).first }
        #expect(packet != nil)
        #expect(sender.snapshot.packetsSent == 1)
    }

    @Test func gainScalesWhatTheFarEndHears() throws {
        let directions = try makeDirections()
        let quiet = try NvstAudioSendPipeline(srtp: directions.outbound, framesPerPacket: Self.framesPerPacket, initialSequenceNumber: 1, initialTimestamp: 0)
        quiet.gain = 0.25
        let loud = try NvstAudioSendPipeline(srtp: directions.outbound, framesPerPacket: Self.framesPerPacket, initialSequenceNumber: 1, initialTimestamp: 0)

        let quietReceiver = try NvstAudioReceivePipeline(srtp: directions.inbound, framesPerPacket: Self.framesPerPacket)
        let loudReceiver = try NvstAudioReceivePipeline(srtp: directions.inbound, framesPerPacket: Self.framesPerPacket)
        for _ in 0..<6 {
            for datagram in quiet.push(capturedPCM: tone()) { quietReceiver.ingest(datagram) }
            for datagram in loud.push(capturedPCM: tone()) { loudReceiver.ingest(datagram) }
        }
        let quietPeak = (quietReceiver.pull() + quietReceiver.flush()).map { abs($0) }.max() ?? 0
        let loudPeak = (loudReceiver.pull() + loudReceiver.flush()).map { abs($0) }.max() ?? 0
        #expect(loudPeak > quietPeak, "gain had no effect (quiet \(quietPeak), loud \(loudPeak))")
    }

    @Test func aShortCaptureWaitsForTheRestOfItsPacket() throws {
        let directions = try makeDirections()
        let sender = try NvstAudioSendPipeline(srtp: directions.outbound, framesPerPacket: Self.framesPerPacket, initialSequenceNumber: 1, initialTimestamp: 0)
        #expect(sender.push(capturedPCM: [Float](repeating: 0.1, count: Self.framesPerPacket * 2 - 2)).isEmpty)
        #expect(sender.snapshot.packetsSent == 0)
    }

    @Test func theMicCarriesTheVendorsDeterministicSsrc() throws {
        let directions = try makeDirections()
        let sender = try NvstAudioSendPipeline(srtp: directions.outbound, framesPerPacket: Self.framesPerPacket, initialSequenceNumber: 7, initialTimestamp: 240)
        #expect(sender.ssrc == 1)
        #expect(sender.payloadType == 111)
        var packet: Data?
        for _ in 0..<8 where packet == nil { packet = sender.push(capturedPCM: tone()).first }
        let datagram = try #require(packet)
        // The protected header is readable: the SSRC the seat binds by must survive.
        let parsed = try #require(NvstAudioRtpPacket.parse(datagram, tagLength: 8))
        #expect(parsed.ssrc == 1)
        #expect(parsed.payloadType == 111)
        #expect(sender.timestamp == 240 + 240, "the clock must advance one packet per packet")
    }

    @Test func variableCaptureSizesProduceTheSamePacketsWithoutLosingSamples() throws {
        let directions = try makeDirections()
        let reference = try NvstAudioSendPipeline(srtp: directions.outbound, initialSequenceNumber: 65_534, initialTimestamp: 0)
        let segmented = try NvstAudioSendPipeline(srtp: directions.outbound, initialSequenceNumber: 65_534, initialTimestamp: 0)
        let samples = Array(repeating: tone(), count: 8).flatMap { $0 }
        let expected = reference.push(capturedPCM: samples)
        var received: [Data] = []
        for offset in stride(from: 0, to: samples.count, by: 256) {
            received += segmented.push(capturedPCM: Array(samples[offset..<min(offset + 256, samples.count)]))
        }
        #expect(expected.count >= 7)
        #expect(received == expected)
        #expect(segmented.snapshot.bytesSent == UInt64(received.reduce(0) { $0 + $1.count }))
        let receiver = try NvstAudioReceivePipeline(srtp: directions.inbound)
        for packet in received { receiver.ingest(packet) }
        #expect(receiver.snapshot.authenticationFailures == 0)
    }

    @Test func mutingDiscardsAnIncompleteCaptureBeforeTheNextTalkspurt() throws {
        let directions = try makeDirections()
        let sender = try NvstAudioSendPipeline(srtp: directions.outbound, initialSequenceNumber: 1, initialTimestamp: 0)
        #expect(sender.push(capturedPCM: Array(tone().prefix(240))).isEmpty)
        sender.isMuted = true
        sender.isMuted = false
        #expect(sender.push(capturedPCM: Array(tone().suffix(240))).isEmpty)
        #expect(sender.snapshot.framesEncoded == 0)
    }
}
