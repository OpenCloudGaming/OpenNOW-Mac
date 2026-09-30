import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import OpenNOW

/// macOS encodes Opus only in mono and stereo, so the seat's 5.1 packets are built the way RFC 7845
/// defines them: one Opus packet per stream, all but the last in self-delimiting framing.
@Suite(.serialized)
struct NvstSurroundAudioDecodeTests {
    private static let describeOffer = "a=nv-audio-surround-opus-params: 20000000000;32102100000;42201230000;53204123000;64204123500;"
    private static let fiveOne = NvstOpusMultistreamLayout(surroundParams: "64204123500")
    private static let sampleRate = 48_000.0
    private static let framesPerPacket = 240

    private final class Feed {
        var samples: [Float]
        var offset = 0
        let channels: Int
        init(_ samples: [Float], channels: Int) {
            self.samples = samples
            self.channels = channels
        }
    }

    private func encode(_ pcm: [Float], channels: Int) throws -> [Data] {
        let width = UInt32(channels)
        var source = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * width, mFramesPerPacket: 1, mBytesPerFrame: 4 * width,
            mChannelsPerFrame: width, mBitsPerChannel: 32, mReserved: 0
        )
        var destination = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.framesPerPacket), mBytesPerFrame: 0,
            mChannelsPerFrame: width, mBitsPerChannel: 0, mReserved: 0
        )
        var created: AudioConverterRef?
        try #require(AudioConverterNew(&source, &destination, &created) == noErr)
        let converter = try #require(created)
        defer { AudioConverterDispose(converter) }

        let feed = Feed(pcm, channels: channels)
        var packets: [Data] = []
        let batch = 64
        var scratch = [UInt8](repeating: 0, count: 4096 * batch)
        var descriptions = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: batch)
        for _ in 0..<1024 {
            var packetCount = UInt32(batch)
            var status: OSStatus = noErr
            scratch.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: width, mDataByteSize: UInt32(buffer.count), mData: buffer.baseAddress))
                status = AudioConverterFillComplexBuffer(converter, { _, count, data, _, context in
                    guard let context else { return -1 }
                    let feed = Unmanaged<Feed>.fromOpaque(context).takeUnretainedValue()
                    let taking = min(Int(count.pointee) * feed.channels, feed.samples.count - feed.offset)
                    guard taking > 0 else {
                        count.pointee = 0
                        return noErr
                    }
                    feed.samples.withUnsafeMutableBytes { bytes in
                        data.pointee.mBuffers.mData = bytes.baseAddress?.advanced(by: feed.offset * 4)
                        data.pointee.mBuffers.mDataByteSize = UInt32(taking * 4)
                        data.pointee.mBuffers.mNumberChannels = UInt32(feed.channels)
                    }
                    data.pointee.mNumberBuffers = 1
                    feed.offset += taking
                    count.pointee = UInt32(taking / feed.channels)
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

    /// RFC 6716 appendix B: the single frame of a code 0 packet gets its length written after the TOC.
    private func selfDelimited(_ packet: Data) throws -> Data {
        let bytes = [UInt8](packet)
        try #require(bytes.first.map { $0 & 0x3 == 0 } == true, "expected a single-frame packet")
        let length = bytes.count - 1
        var framed: [UInt8] = [bytes[0]]
        if length < 252 {
            framed.append(UInt8(length))
        } else {
            let first = 252 + (length & 3)
            framed += [UInt8(first), UInt8((length - first) >> 2)]
        }
        return Data(framed + bytes.dropFirst())
    }

    private func tone(_ frequency: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(sin(2 * Double.pi * frequency * Double($0) / Self.sampleRate)) * 0.4 }
    }

    /// Splits one tone per output channel into the layout's streams and multiplexes them the way the
    /// seat's packets arrive.
    private func multistreamPackets(_ layout: NvstOpusMultistreamLayout, tones: [Double], frames: Int) throws -> [Data] {
        var streamChannels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: layout.streams + layout.coupledStreams)
        for (channel, index) in layout.mapping.enumerated() { streamChannels[Int(index)] = tone(tones[channel], frames: frames) }
        var encoded: [[Data]] = []
        for stream in 0..<layout.streams {
            if stream < layout.coupledStreams {
                let left = streamChannels[stream * 2]
                let right = streamChannels[stream * 2 + 1]
                encoded.append(try encode(zip(left, right).flatMap { [$0, $1] }, channels: 2))
            } else {
                encoded.append(try encode(streamChannels[layout.coupledStreams + stream], channels: 1))
            }
        }
        let count = try #require(encoded.map(\.count).min())
        return try (0..<count).map { index in
            var packet = Data()
            for stream in 0..<(layout.streams - 1) { packet += try selfDelimited(encoded[stream][index]) }
            packet += encoded[layout.streams - 1][index]
            return packet
        }
    }

    private func power(_ samples: [Float], at frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / Self.sampleRate)
        var previous = 0.0
        var beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        return previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
    }

    @Test func theSeatsSurroundOfferParsesIntoItsStreamLayouts() throws {
        let body = "m=audio 0 RTP/AVP 96 97\r\n\(Self.describeOffer)\r\na=rtpmap:97 opus/16000/2\r\n"
        let offered = NvstOpusMultistreamLayout.offered(inDescribe: body)
        #expect(offered.map(\.channels) == [3, 4, 5, 6])
        let fiveOne = try #require(offered.last)
        #expect(fiveOne.streams == 4)
        #expect(fiveOne.coupledStreams == 2)
        #expect(fiveOne.mapping == [0, 4, 1, 2, 3, 5])
        #expect(NvstOpusMultistreamLayout(surroundParams: "6420412350") == nil)
        #expect(NvstOpusMultistreamLayout(surroundParams: "64204123900") == nil)
        #expect(NvstOpusMultistreamLayout.offered(inDescribe: "a=rtpmap:97 opus/48000/2").isEmpty)
    }

    @Test func negotiationPicksTheWidestDescribedLayoutWithinTheRequest() {
        let offered = NvstOpusMultistreamLayout.offered(inDescribe: Self.describeOffer)
        #expect(NvstOpusMultistreamLayout.negotiated(requestedChannels: 6, offered: offered).channels == 6)
        #expect(NvstOpusMultistreamLayout.negotiated(requestedChannels: 8, offered: offered).channels == 6)
        #expect(NvstOpusMultistreamLayout.negotiated(requestedChannels: 2, offered: offered) == .stereo)
        #expect(NvstOpusMultistreamLayout.negotiated(requestedChannels: 6, offered: []) == .stereo)
    }

    @Test func theDecoderCookieCarriesTheStreamTable() throws {
        let fiveOne = try #require(Self.fiveOne)
        let surround = [UInt8](NvstOpusDecoder.opusHeadCookie(layout: fiveOne, sampleRate: 48_000))
        #expect(surround.count == 27)
        #expect(surround[9] == 6)
        #expect(Array(surround[18...]) == [1, 4, 2, 0, 4, 1, 2, 3, 5])
        let stereo = [UInt8](NvstOpusDecoder.opusHeadCookie(layout: .stereo, sampleRate: 48_000))
        #expect(stereo.count == 19)
        #expect(stereo[9] == 2)
        #expect(stereo[18] == 0)
    }

    @Test func fiveOneDecodesEachChannelOntoItsOwnSpeaker() throws {
        let layout = try #require(Self.fiveOne)
        let tones: [Double] = [400, 1000, 700, 1600, 2200, 250]
        let frames = Int(Self.sampleRate * 0.4)
        let packets = try multistreamPackets(layout, tones: tones, frames: frames)
        try #require(packets.count > 40)
        let decoder = try NvstOpusDecoder(framesPerPacket: Self.framesPerPacket, layout: layout)
        var pcm: [Float] = []
        for packet in packets { pcm += try decoder.decode(packet) ?? [] }
        #expect(decoder.failedPackets == 0)
        let decodedFrames = pcm.count / layout.channels
        try #require(decodedFrames > 9_600)
        for channel in 0..<layout.channels {
            let samples = (2_400..<(decodedFrames - 2_400)).map { pcm[$0 * layout.channels + channel] }
            let strongest = tones.indices.max { power(samples, at: tones[$0]) < power(samples, at: tones[$1]) }
            #expect(strongest == channel, "channel \(channel) (\(layout.speakers[channel])) carried tone \(strongest.map { tones[$0] } ?? 0)")
        }
    }

    private func rendered(_ samples: [Float], from source: [AudioChannelLabel], onto destination: [AudioChannelLabel]) -> [Int16] {
        let frames = samples.count / source.count
        var output = [Int16](repeating: -1, count: frames * destination.count)
        output.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            NvstSpeakerMatrix(from: source, to: destination).render(samples, frames: frames, into: base)
        }
        return output
    }

    private func sample(_ value: Float) -> Int16 { Int16((value * Float(Int16.max)).rounded()) }

    @Test func fiveOneLandsOnTheSpeakersAWaveOrderDeviceNames() throws {
        let layout = try #require(Self.fiveOne)
        let arena: [AudioChannelLabel] = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                                          kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround]
        let decoded: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        #expect(rendered(decoded, from: layout.speakers, onto: arena) == [0.1, 0.3, 0.2, 0.6, 0.4, 0.5].map(sample))
        #expect(NvstSpeakerMatrix.speakers(reported: [], channels: 6) == arena)
        #expect(NvstSpeakerMatrix.speakers(reported: Array(repeating: kAudioChannelLabel_Unknown, count: 6), channels: 6) == arena)
        #expect(NvstSpeakerMatrix.speakers(reported: arena, channels: 2) == [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
    }

    @Test func fiveOneFoldsToStereoWithoutClippingAndWithoutTheLFE() throws {
        let layout = try #require(Self.fiveOne)
        let stereo = NvstSpeakerMatrix.speakers(reported: [], channels: 2)
        let loudest: Float = 1 / (1 + 2 * 0.70710677)
        #expect(rendered([1, 0, 0, 0, 0, 0], from: layout.speakers, onto: stereo) == [sample(loudest), 0])
        #expect(rendered([0, 1, 0, 0, 0, 0], from: layout.speakers, onto: stereo)
                == [sample(0.70710677 * loudest), sample(0.70710677 * loudest)])
        #expect(rendered([0, 0, 0, 0, 1, 0], from: layout.speakers, onto: stereo) == [0, sample(0.70710677 * loudest)])
        #expect(rendered([0, 0, 0, 0, 0, 1], from: layout.speakers, onto: stereo) == [0, 0])
        #expect(rendered([1, 1, 1, 1, 1, 1], from: layout.speakers, onto: stereo) == [Int16.max, Int16.max])
    }

    @Test func aLayoutGivenAsATagExpandsIntoItsSpeakers() {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A
        let labels = withUnsafePointer(to: &layout) { NvstSpeakerMatrix.labels(of: $0) }
        #expect(labels == [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
                           kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround])
    }

    @Test func aSurroundDeviceStillHandsTheRecorderStereo() throws {
        let layout = try #require(Self.fiveOne)
        let mixer = NvstPlayoutMixer(source: layout.speakers)
        let speakers = NvstSpeakerMatrix.speakers(reported: [], channels: 6)
        var device = [Int16](repeating: 0, count: 12)
        device.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            mixer.render([0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0], frames: 2, speakers: speakers, into: base)
        }
        #expect(device[2] == Int16.max)
        var tapped: [Int16] = []
        var tappedFrames: UInt32 = 0
        mixer.withStereoTap { list, frames in
            let buffer = list.assumingMemoryBound(to: AudioBufferList.self).pointee.mBuffers
            tappedFrames = frames
            tapped = Array(UnsafeBufferPointer(start: buffer.mData?.assumingMemoryBound(to: Int16.self), count: Int(frames) * 2))
        }
        #expect(tappedFrames == 2)
        #expect(tapped.allSatisfy { $0 > 0 })

        var stereoDevice = [Int16](repeating: 0, count: 4)
        stereoDevice.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            mixer.render([0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0], frames: 2, speakers: [kAudioChannelLabel_Left, kAudioChannelLabel_Right], into: base)
        }
        var tappedAgain = false
        mixer.withStereoTap { _, _ in tappedAgain = true }
        #expect(!tappedAgain)
    }
}
