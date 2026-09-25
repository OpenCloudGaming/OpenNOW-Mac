import Foundation
import Testing
@testable import OpenNOW

/// The microphone path is only proven by going all the way round: encode PCM the way the mic
/// section will, then decode it with the decoder that already handles the seat's audio. A test that
/// only asserts "some bytes came out" would pass on silence.
@Suite struct NvstOpusEncoderTests {
    private static let framesPerPacket = 240

    /// 5 ms of a 440 Hz tone at 48 kHz, interleaved for `channels`.
    private static func tone(channels: Int, packets: Int) -> [Float] {
        let total = framesPerPacket * packets
        var samples = [Float](repeating: 0, count: total * channels)
        for frame in 0..<total {
            let value = Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / 48_000.0)) * 0.5
            for channel in 0..<channels { samples[frame * channels + channel] = value }
        }
        return samples
    }

    @Test func aPacketOfPcmEncodesToOpus() throws {
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: Self.framesPerPacket)
        let samples = Self.tone(channels: 2, packets: 1)
        var packet: Data?
        for _ in 0..<8 where packet == nil {
            packet = try encoder.encode(samples)
        }
        let encoded = try #require(packet, "the encoder produced nothing for a full packet of PCM")
        #expect(encoded.count > 0)
        #expect(encoded.count < 1276, "an Opus packet cannot exceed 1275 bytes")
        #expect(encoder.encodedPackets >= 1)
    }

    @Test func encodedAudioDecodesBackToTheSameTone() throws {
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: Self.framesPerPacket)
        let decoder = try NvstOpusDecoder(framesPerPacket: Self.framesPerPacket)
        let samples = Self.tone(channels: 2, packets: 6)

        var decoded = [Float]()
        for index in 0..<6 {
            let start = index * Self.framesPerPacket * 2
            let slice = Array(samples[start..<(start + Self.framesPerPacket * 2)])
            guard let packet = try encoder.encode(slice) else { continue }
            if let produced = try decoder.decode(packet) { decoded.append(contentsOf: produced) }
        }

        #expect(!decoded.isEmpty, "nothing decoded from the encoded microphone audio")
        let peak = decoded.map { abs($0) }.max() ?? 0
        #expect(peak > 0.1, "the round trip produced silence (peak \(peak))")
    }

    @Test func aPartialPacketIsRefusedRatherThanPadded() throws {
        let encoder = try NvstOpusEncoder(channels: 2, framesPerPacket: Self.framesPerPacket)
        let short = [Float](repeating: 0, count: Self.framesPerPacket * 2 - 1)
        #expect(try encoder.encode(short) == nil)
        #expect(encoder.encodedPackets == 0)
    }

    @Test func aMonoEncoderInterleavesOneChannel() throws {
        let encoder = try NvstOpusEncoder(channels: 1, framesPerPacket: Self.framesPerPacket)
        let samples = Self.tone(channels: 1, packets: 1)
        var packet: Data?
        for _ in 0..<8 where packet == nil {
            packet = try encoder.encode(samples)
        }
        #expect(try #require(packet).count > 0)
        #expect(encoder.channels == 1)
        #expect(encoder.samplesPerPacket == Self.framesPerPacket)
    }
}
