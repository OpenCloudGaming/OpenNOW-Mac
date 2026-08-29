import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized)
struct NvstRemoteInputTests {
    /// `[u32 big-endian length][u32 little-endian type][body]`. The mixed endianness is the part
    /// most likely to be "tidied up" by mistake, so it is asserted byte by byte.
    @Test func framesAPacketWithBigEndianLengthAndLittleEndianType() {
        let data = NvstRemoteInput.mouseButton(.left, isPressed: true)
        #expect([UInt8](data) == [0x00, 0x00, 0x00, 0x06,   // length = 4 + 2
                                 0x08, 0x00, 0x00, 0x00,   // type 8 = press, little-endian
                                 0x01, 0x00])              // left, no modifier
    }

    @Test func releaseAndPressUseDifferentTypes() {
        let press = NvstRemoteInput.mouseButton(.right, isPressed: true)
        let release = NvstRemoteInput.mouseButton(.right, isPressed: false)
        #expect(press[4] == 0x08)
        #expect(release[4] == 0x09)
        // Right is 3 on the wire even though the flag bit order puts it second.
        #expect(press[8] == 3)
        #expect(NvstRemoteInput.Button.middle.rawValue == 2)
    }

    /// The motion branch selected by flag word `0x10000` writes the deltas first, then the flags —
    /// there is no leading zero word, and the type is 7, not 10.
    @Test func movesCarryBigEndianSignedDeltas() {
        let data = NvstRemoteInput.mouseMove(deltaX: 24, deltaY: -24)
        #expect([UInt8](data) == [0x00, 0x00, 0x00, 0x0a,   // length = 4 + 6
                                 0x07, 0x00, 0x00, 0x00,   // type 7 = relative motion
                                 0x00, 0x18,                // dx = +24
                                 0xff, 0xe8,                // dy = -24
                                 0x00, 0x00])               // flags: relative (no 0x800)
    }

    /// A delta at the 16-bit extremes must survive sign-extension intact.
    @Test func extremeDeltasRoundTrip() {
        for delta in [Int16.min, -1, 0, 1, Int16.max] {
            let data = NvstRemoteInput.mouseMove(deltaX: delta, deltaY: delta)
            let x = Int16(bitPattern: UInt16(data[8]) << 8 | UInt16(data[9]))
            let y = Int16(bitPattern: UInt16(data[10]) << 8 | UInt16(data[11]))
            #expect(x == delta)
            #expect(y == delta)
        }
    }

    /// Each framing is a distinct hypothesis about what the seat expects, so each must be exact.
    @Test func framingsWrapThePacketAsTheLibraryDoes() {
        let packet = NvstRemoteInput.mouseButton(.left, isPressed: true)
        #expect(NvstRemoteInput.framed(packet, framing: .plain, sequence: 7, timestampMicroseconds: 1) == packet)

        let sequenced = NvstRemoteInput.framed(packet, framing: .sequenced, sequence: 0x0102, timestampMicroseconds: 1)
        #expect(sequenced.count == packet.count + 2)
        #expect([UInt8](sequenced.suffix(2)) == [0x01, 0x02])

        let versioned = NvstRemoteInput.framed(packet, framing: .versioned, sequence: 0, timestampMicroseconds: 0x0102030405060708)
        #expect(versioned.count == packet.count + 9)
        #expect([UInt8](versioned.prefix(9)) == [0x23, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        #expect(versioned.suffix(packet.count) == packet)
    }

    /// The envelope pads the inner packet to an 8-byte slot boundary and appends a
    /// little-endian timestamp — the one place the library does not byte-swap it.
    @Test func theEnvelopeWrapsPadsAndTimestampsTheInnerPacket() {
        let inner = NvstRemoteInput.mouseButton(.left, isPressed: true)   // 10 bytes
        #expect(inner.count == 10)
        #expect(NvstRemoteInput.envelopePaddedLength(innerLength: 10) == 24)

        let data = NvstRemoteInput.framed(inner, framing: .enveloped, sequence: 0, timestampMicroseconds: 0x0102030405060708)
        // Outer header: length = 4 + body, type 0x0e little-endian.
        #expect([UInt8](data.prefix(8)) == [0x00, 0x00, 0x00, 0x24, 0x0e, 0x00, 0x00, 0x00])
        #expect(data.count == 8 + 32)
        #expect(data.dropFirst(8).prefix(10) == inner)
        // Padding out to the slot boundary, then the timestamp, least significant byte first.
        #expect([UInt8](data.dropFirst(18).prefix(14)) == Array(repeating: 0, count: 14))
        #expect([UInt8](data.suffix(8)) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    }

    /// Byte-for-byte against a packet captured from the official client's own `SSL_write`:
    /// command 0x206, envelope type 0x0e, inner type 7 relative motion, dx/dy +24, flags 0,
    /// padded to the slot boundary, then a microseconds-since-session-start timestamp.
    @Test func reproducesACapturedOfficialMousePacket() throws {
        let captured = "06022800000000240e0000000000000a07000000001800180000000000000000000000003013860100000000"
        let inner = NvstRemoteInput.mouseMove(deltaX: 24, deltaY: 24)
        let framed = NvstRemoteInput.framed(inner,
                                            framing: .enveloped,
                                            sequence: 0,
                                            timestampMicroseconds: 0x0186_1330)
        let wire = try NvstControlCommand(code: NvstRemoteInput.commandCode, payload: framed).encoded
        #expect(wire.map { String(format: "%02x", $0) }.joined() == captured)
    }

    /// Byte-for-byte against captured official click packets: press is type 8, release type 9,
    /// body `[button][0]`, enveloped with a session-relative timestamp.
    @Test func reproducesCapturedOfficialClickPackets() throws {
        let cases: [(Bool, UInt64, String)] = [
            (true,  0x0186_18b8, "06022800000000240e000000000000060800000001000000000000000000000000000000b818860100000000"),
            (false, 0x0186_18ef, "06022800000000240e000000000000060900000001000000000000000000000000000000ef18860100000000"),
        ]
        for (isPressed, timestamp, expected) in cases {
            let inner = NvstRemoteInput.mouseButton(.left, isPressed: isPressed)
            let framed = NvstRemoteInput.framed(inner, framing: .enveloped, sequence: 0, timestampMicroseconds: timestamp)
            let wire = try NvstControlCommand(code: NvstRemoteInput.commandCode, payload: framed).encoded
            #expect(wire.map { String(format: "%02x", $0) }.joined() == expected)
        }
    }

    /// A text packet is the raw UTF-8 bytes under RI type 23 — the body `sendUnicodeEvent`
    /// memcpys in, with the standard `[BE length][LE type]` header.
    @Test func aTextPacketCarriesRawUtf8UnderType23() {
        let text = "héllo ☺"
        let utf8 = Data(text.utf8)
        let (packets, droppedBytes) = NvstRemoteInput.utf8TextPackets(forText: text)
        #expect(droppedBytes == 0)
        #expect(packets.count == 1)
        let packet = packets[0]
        #expect(packet.count == 8 + utf8.count)
        #expect(UInt32(packet[3]) == UInt32(4 + utf8.count))
        #expect(packet[4] == 23)
        #expect(Data(packet.suffix(utf8.count)) == utf8)
    }

    /// The official chunker admits 1017 bytes and then cuts back at a code point boundary by
    /// probing 1016, 1015, 1014, 1013 in order, so a chunk is never longer than 1016 bytes and
    /// never splits a code point.
    @Test func textChunksCutAtCodePointBoundariesAsTheOfficialChunkerDoes() {
        func chunkSizes(_ text: String) -> [Int] {
            let (bodies, droppedBytes) = NvstRemoteInput.utf8TextBodies(Data(text.utf8))
            #expect(droppedBytes == 0)
            return bodies.map(\.count)
        }
        // Byte 1016 is the é's leader byte, so the cut lands at 1016.
        #expect(chunkSizes(String(repeating: "a", count: 1016) + "é") == [1016, 2])
        // Byte 1016 is the é's continuation; the probe backs up to its leader at 1015.
        #expect(chunkSizes(String(repeating: "a", count: 1015) + "é" + "bbbbb") == [1015, 7])
        // A four-byte emoji starting at 1014 pushes the probe back two continuation bytes.
        #expect(chunkSizes(String(repeating: "a", count: 1014) + "😀" + String(repeating: "b", count: 10)) == [1014, 14])
        // ASCII never needs the probe: every cut lands exactly at 1016.
        #expect(chunkSizes(String(repeating: "a", count: 3000)) == [1016, 1016, 968])
        // At or under the cap the text is one packet; just over it, two.
        #expect(chunkSizes(String(repeating: "a", count: 1016)) == [1016])
        #expect(chunkSizes(String(repeating: "a", count: 1017)) == [1016, 1])
        #expect(chunkSizes("hi") == [2])
        #expect(NvstRemoteInput.utf8TextBodies(Data()).bodies.isEmpty)
    }

    /// A tail whose four probe positions are all continuation bytes is unchunkable; the
    /// official client logs and drops it rather than splitting a code point.
    @Test func anUnchunkableTailIsDroppedAsTheOfficialClientDoes() {
        let invalid = Data(repeating: 0x80, count: 1020)
        let (bodies, droppedBytes) = NvstRemoteInput.utf8TextBodies(invalid)
        #expect(bodies.isEmpty)
        #expect(droppedBytes == 1020)
    }

    /// An IME hotkey is a one-byte body under type 20, as `sendImeControlEvent` writes it.
    @Test func anImeHotkeyIsASingleByteUnderType20() {
        #expect([UInt8](NvstRemoteInput.imeHotkey(0xab)) ==
                [0x00, 0x00, 0x00, 0x05, 0x14, 0x00, 0x00, 0x00, 0xab])
    }

    /// The envelope's slot arithmetic per `SendPacket`: the timestamp gets its own 8-byte slot,
    /// so the padding between inner packet and timestamp is at least 8 bytes.
    @Test func theEnvelopeKeepsItsOfficialSlotArithmetic() {
        #expect(NvstRemoteInput.envelopePaddedLength(innerLength: 14) == 24)   // pointer: 40 on the wire
        #expect(NvstRemoteInput.envelopePaddedLength(innerLength: 22) == 32)   // key: 48 on the wire
        let keyed = NvstRemoteInput.framed(
            NvstRemoteInput.keyboard(virtualKey: 0x41, isPressed: true),
            framing: .enveloped, sequence: 0, timestampMicroseconds: 0x0102030405060708)
        #expect(keyed.count == 48)
        #expect([UInt8](keyed.dropFirst(30).prefix(10)) == Array(repeating: 0, count: 10))
        #expect([UInt8](keyed.suffix(8)) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
    }

    /// `SendPacket` sends packets bare when the envelope's slot count would reach `0x7f` — a
    /// 1000-byte text body is the first to skip the envelope.
    @Test func oversizedPacketsSkipTheEnvelopeAsSendPacketDoes() {
        #expect(NvstRemoteInput.envelopeMaxInnerLength == 1007)
        let fits = NvstRemoteInput.utf8TextPackets(forText: String(repeating: "a", count: 999)).packets[0]
        let enveloped = NvstRemoteInput.framed(fits, framing: .enveloped, sequence: 0, timestampMicroseconds: 7)
        #expect(enveloped.count == 1032)
        #expect(enveloped[4] == 0x0e)
        let bare = NvstRemoteInput.utf8TextPackets(forText: String(repeating: "a", count: 1000)).packets[0]
        #expect(NvstRemoteInput.framed(bare, framing: .enveloped, sequence: 0, timestampMicroseconds: 7) == bare)
        // A maximum 1016-byte chunk always travels bare, like the official client's.
        let maxChunk = NvstRemoteInput.utf8TextPackets(forText: String(repeating: "a", count: 1016)).packets[0]
        #expect(NvstRemoteInput.framed(maxChunk, framing: .enveloped, sequence: 0, timestampMicroseconds: 7) == maxChunk)
    }

    /// The channel/framing sweep is gone: measurement settled it. Input goes out as command
    /// `0x206`, envelope-framed, on `control_channel_reliable` — the single destination the seat
    /// reacts to, verified by matching the native stack's own reaction signature.
    @Test func inputHasOneDestinationAndItIsTheControlChannel() {
        #expect(NvstBifrostFreeTransport.InputDestination.allCases.map(\.rawValue) == ["control"])
    }

    /// Input is gated on the seat announcing its protocol version. Both layouts upstream accepts
    /// must parse, and the message the seat actually sent us must yield version 3.
    @Test func parsesTheInputProtocolHandshake() {
        // What the seat sent on control_channel_reliable in every capture: command 0x020e, len 2.
        // A full command carries the version in its payload, not in the length field.
        #expect(NvstRemoteInput.protocolVersion(in: Data([0x0e, 0x02, 0x02, 0x00, 0x03, 0x00])) == 3)
        #expect(NvstRemoteInput.protocolVersion(in: Data([0x0e, 0x02, 0x03, 0x00])) == 3)
        // A bare message whose first byte is 0x0e reports the whole first word.
        #expect(NvstRemoteInput.protocolVersion(in: Data([0x0e, 0x03])) == 0x030e)
        // Anything else is not a handshake.
        #expect(NvstRemoteInput.protocolVersion(in: Data([1])) == nil)
        #expect(NvstRemoteInput.protocolVersion(in: Data([0x01, 0x02, 0x03, 0x04])) == nil)
        // A truncated 0x020e message falls back to version 2 rather than failing.
        #expect(NvstRemoteInput.protocolVersion(in: Data([0x0e, 0x02])) == 2)
    }

    /// Kept because upstream's transport sends it, but the captured official client sends no such
    /// heartbeat, so nothing in our path does either.
    @Test func theHeartbeatShapeIsKnownButUnused() {
        #expect([UInt8](NvstRemoteInput.heartbeat) == [2, 0, 0, 0])
    }

    @Test func theBundleKeepsInputChannelsAheadOfCursorAndFeedback() {
        let labels = NvstWebRtcBundle.officialChannels.map(\.label)
        #expect(labels == ["control_channel_reliable",
                           "custom_message_on_sctp_private_reliable",
                           "custom_message_on_sctp_private_partially_reliable",
                           "control_channel_partially_reliable",
                           "control_channel_unreliable",
                           "input_channel_partially_reliable",
                           "cursor_channel",
                           "rtcp_on_sctp_private"])
    }

    @Test func theCommandCodeIsTheRemoteInputChannelCommand() {
        #expect(NvstRemoteInput.commandCode == 0x206)
        #expect(NvstControlCommandCode(rawValue: 0x206).name == "ri-command")
    }
}
