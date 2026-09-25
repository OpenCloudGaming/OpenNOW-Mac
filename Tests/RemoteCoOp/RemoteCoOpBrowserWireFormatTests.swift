import Foundation
import Testing
@testable import OpenNOW

/// The exact bytes the host sends a browser guest, pinned.
///
/// The page parses these with an independent implementation (`Resources/RemoteCoOp/browser/wire.mjs`),
/// so the layouts are a cross-language contract: a change to either side that the other does not
/// follow is a broken guest. These vectors are the same ones the browser wire code is checked against.
@Suite struct RemoteCoOpBrowserWireFormatTests {
    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }

    @Test func audioChunkMatchesTheBrowserParser() throws {
        let samples: [Int16] = [1, -2, 3, -4, 5, -6, 7, -8]
        let audioData = samples.withUnsafeBytes { Data($0) }
        let frame = RemoteCoOpNativeAudioFrame(samples: audioData, frameCount: 4)
        let result = RemoteCoOpNativeAudioChunker.datagrams(from: frame, startingSequence: 5, timestampNanoseconds: 42)

        let datagram = try #require(result.datagrams.first)
        #expect(Self.hex(datagram) == "4f41010000000005000000000000002a0000bb800002000400100100feff0300fcff0500faff0700f8ff")
        #expect(result.nextSequence == 6)

        let decoded = try #require(OPNRemoteCoOpAudioPacket.decode(datagram))
        #expect(decoded.header.sequence == 5)
        #expect(decoded.header.sampleRate == 48_000)
        #expect(decoded.header.channels == 2)
        #expect(decoded.header.frameCount == 4)
        #expect(decoded.payload == audioData)
    }

    @Test func inputFrameMatchesTheBrowserEncoder() throws {
        let packet = OPNRemoteCoOpInputPacket(participantID: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
                                              sequenceNumber: 9,
                                              buttons: [.south, .start],
                                              leftTrigger: 0.5,
                                              rightTrigger: 0.25,
                                              leftStickX: -0.5,
                                              leftStickY: 0.75,
                                              rightStickX: 1.0,
                                              rightStickY: -1.0,
                                              sentAtNanoseconds: 1234)
        let encoded = OPNRemoteCoOpInputBinaryCodec.encode(packet)
        #expect(Self.hex(encoded) == "a70100112233445566778899aabbccddeeff0900000000000000810000000000003f0000803e000000bf0000403f0000803f000080bfd204000000000000")
        #expect(OPNRemoteCoOpInputBinaryCodec.decode(encoded) == packet)
    }

    @Test func videoFragmentMatchesTheBrowserReassembler() throws {        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84, 0x21, 0x09, 0xF0])
        let frame = NativeNVSTVideoFrame(streamID: 7,
                                         codec: .h264,
                                         timestamp: MediaTimestamp(nanoseconds: 123_456_789),
                                         durationNanoseconds: 3_333_333,
                                         width: 0, height: 0,
                                         isKeyFrame: true,
                                         payload: payload)
        let datagram = try #require(OPNRemoteCoOpCompressedVideoFragmenter().fragments(for: frame).first)

        // Magic, version, key flag, codec, stream ID, sequence, timestamp, duration: the fields the
        // page's reassembler reads by offset.
        let bytes = [UInt8](datagram)
        #expect(bytes[0] == 0x4F && bytes[1] == 0x43 && bytes[2] == 1)
        #expect(bytes[3] & 0x01 == 1)
        #expect(bytes[4] == 1)
        #expect(Self.hex(Data(bytes[5..<9])) == "00000007")
        #expect(Self.hex(Data(bytes[13..<17])) == "00000000")
        #expect(Self.hex(Data(bytes[17..<25])) == "00000000075bcd15")
        #expect(Self.hex(Data(bytes[25..<33])) == "000000000032dcd5")
        #expect(Self.hex(Data(bytes[33..<35])) == "0000")
        #expect(Self.hex(Data(bytes[35..<37])) == "0001")
        #expect(Self.hex(Data(bytes[37..<39])) == "000a")
        #expect(Data(bytes[39...]) == payload)
    }
}
