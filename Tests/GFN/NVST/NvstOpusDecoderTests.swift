import AudioToolbox
import Foundation
import Testing
@testable import OpenNOW

/// Round-trips real Opus through macOS's own encoder so the decoder is tested against actual
/// bitstream rather than a hand-made fixture. `kAudioFormatOpus` is both encodable and decodable
/// here, which is what makes this possible without vendoring a codec.
@Suite(.serialized)
struct NvstOpusDecoderTests {

    /// Encodes interleaved stereo float PCM into Opus packets of `framesPerPacket` frames each.
    private final class Feed {
        var samples: [Float]
        var offset = 0
        init(_ samples: [Float]) { self.samples = samples }
    }

    /// Encodes interleaved stereo float PCM into Opus packets of `framesPerPacket` frames each.
    /// A batch is requested per call because the encoder buffers before it emits: a loop that
    /// stops at the first call producing nothing collects almost no packets.
    private func encode(_ pcm: [Float], framesPerPacket: UInt32) throws -> [Data] {
        var source = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        var destination = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
            mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0
        )
        var created: AudioConverterRef?
        try #require(AudioConverterNew(&source, &destination, &created) == noErr)
        guard let converter = created else { return [] }
        defer { AudioConverterDispose(converter) }

        let feed = Feed(pcm)
        var packets: [Data] = []
        let batch = 64
        var scratch = [UInt8](repeating: 0, count: 4096 * batch)
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: batch)

        for _ in 0..<1024 {
            var packetCount = UInt32(batch)
            var status: OSStatus = noErr
            scratch.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32(buffer.count), mData: buffer.baseAddress))
                status = AudioConverterFillComplexBuffer(converter, { _, count, data, _, context in
                    let feed = Unmanaged<Feed>.fromOpaque(context!).takeUnretainedValue()
                    let wanted = Int(count.pointee) * 2
                    let taking = min(wanted, feed.samples.count - feed.offset)
                    guard taking > 0 else { count.pointee = 0; return noErr }
                    feed.samples.withUnsafeMutableBytes { bytes in
                        data.pointee.mBuffers.mData = bytes.baseAddress!.advanced(by: feed.offset * 4)
                        data.pointee.mBuffers.mDataByteSize = UInt32(taking * 4)
                        data.pointee.mBuffers.mNumberChannels = 2
                    }
                    data.pointee.mNumberBuffers = 1
                    feed.offset += taking
                    count.pointee = UInt32(taking / 2)
                    return noErr
                }, Unmanaged.passUnretained(feed).toOpaque(), &packetCount, &list, &descriptions)
                for index in 0..<Int(packetCount) where descriptions[index].mDataByteSize > 0 {
                    let offset = Int(descriptions[index].mStartOffset)
                    packets.append(Data(buffer[offset..<(offset + Int(descriptions[index].mDataByteSize))]))
                }
            }
            if status != noErr || packetCount == 0 { break }
        }
        return packets
    }

    /// A 440 Hz tone, so the decode can be checked for real signal rather than only for a status.
    private func tone(seconds: Double) -> [Float] {
        let frames = Int(48000 * seconds)
        return (0..<frames).flatMap { index -> [Float] in
            let value = Float(sin(2 * Double.pi * 440 * Double(index) / 48000)) * 0.5
            return [value, value]
        }
    }

    @Test func decodesFiveMillisecondFramesTheWayTheSeatSendsThem() throws {
        let packets = try encode(tone(seconds: 0.5), framesPerPacket: 240)
        try #require(!packets.isEmpty)
        let decoder = try NvstOpusDecoder(framesPerPacket: 240)
        var frames = 0
        for packet in packets {
            if let pcm = try decoder.decode(packet) { frames += pcm.count / 2 }
        }
        #expect(decoder.failedPackets == 0)
        // Opus reports its decoder delay as leading frames, so allow a tolerance rather than
        // demanding an exact sample count.
        #expect(frames > Int(48000 * 0.4))
        #expect(decoder.decodedPackets > 0)
    }

    /// The frame size is observed, not assumed: a 10 ms stream must decode too, and the decoder
    /// must report what it actually saw.
    @Test func decodesTenMillisecondFramesAndReportsTheFrameSize() throws {
        let packets = try encode(tone(seconds: 0.2), framesPerPacket: 480)
        try #require(!packets.isEmpty)
        let decoder = try NvstOpusDecoder(framesPerPacket: 480)
        for packet in packets { _ = try decoder.decode(packet) }
        #expect(decoder.failedPackets == 0)
        #expect(!decoder.framesPerPacketSeen.isEmpty)
    }

    @Test func decodedAudioCarriesSignalRatherThanSilence() throws {
        let packets = try encode(tone(seconds: 0.3), framesPerPacket: 240)
        let decoder = try NvstOpusDecoder(framesPerPacket: 240)
        var peak: Float = 0
        for packet in packets {
            guard let pcm = try decoder.decode(packet) else { continue }
            for sample in pcm { peak = max(peak, abs(sample)) }
        }
        #expect(peak > 0.1, "decoded a 0.5-amplitude tone as peak \(peak)")
    }

    @Test func anEmptyPacketIsNotAFailure() throws {
        let decoder = try NvstOpusDecoder()
        #expect(try decoder.decode(Data()) == nil)
        #expect(decoder.failedPackets == 0)
    }
}

/// Real payloads, captured from the vendored decoder's own input by patching
/// `OpusAudioDecoderWrapper::decode` in libBifrost2 — the only place the seat's audio exists in the
/// clear, since the bundle leg is DTLS-SRTP and libwebrtc holds those keys.
@Suite(.serialized)
struct NvstCapturedOpusPayloadTests {

    private func capturedPayloads() throws -> [Data] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/nvst-opus-payloads.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            let hex = line.trimmingCharacters(in: .whitespaces)
            guard hex.count >= 4, hex.count % 2 == 0 else { return nil }
            var data = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
                data.append(byte)
                index = next
            }
            return data
        }
    }

    /// The payload is plain Opus, and the frame the TOC byte describes is what the RTP timestamp
    /// step already said: 5 ms, stereo, one frame per packet.
    @Test func theSeatsPayloadIsSingleFrameFiveMillisecondStereoOpus() throws {
        let payloads = try capturedPayloads()
        try #require(payloads.count >= 20)
        for payload in payloads {
            let toc = payload[0]
            #expect(toc >> 3 == 29, "config \(toc >> 3): 29 is CELT fullband at 5 ms")
            #expect((toc >> 2) & 1 == 1, "stereo bit")
            #expect(toc & 3 == 0, "code 0 is one frame per packet")
        }
    }

    /// Decodes every captured packet. This is the test that would have caught the missing magic
    /// cookie: without it the decoder rejects all of them with `kAudioCodecBadDataError`, while
    /// packets produced by macOS's own encoder decode either way.
    @Test func theDecoderDecodesEveryCapturedPayload() throws {
        let payloads = try capturedPayloads()
        let decoder = try NvstOpusDecoder(framesPerPacket: 240)
        var frames = 0
        for payload in payloads {
            if let pcm = try decoder.decode(payload) { frames += pcm.count / Int(NvstOpusDecoder.channels) }
        }
        #expect(decoder.failedPackets == 0, "last failure \(decoder.lastFailure)")
        // Opus reports its decoder delay as leading frames, so allow one packet of slack.
        #expect(frames >= (payloads.count - 1) * 240)
        #expect(decoder.framesPerPacketSeen[240] != nil)
    }
}
