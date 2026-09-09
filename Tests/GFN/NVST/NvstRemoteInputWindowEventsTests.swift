import Foundation
import Testing
@testable import OpenNOW

/// RI types 6, 15 and 16. Only type 6 has a body this repo can encode; the other two are pinned
/// as ids so a later session can see at a glance that they were left unencoded on purpose.
/// See `NvstRemoteInputWindowEvents.swift`.
@Suite struct NvstRemoteInputWindowEventsTests {
    /// `[u32 BE length][u32 LE type][body]` like every other RI packet: length 18 for a 14-byte
    /// body, type 6 little-endian, then seven big-endian words.
    @Test func extendedAbsoluteMoveIsA14ByteBigEndianBodyUnderType6() {
        let move = NvstRemoteInput.ExtendedAbsoluteMouseMove(x: 0x065f,
                                                             y: 0x02af,
                                                             flags: NvstRemoteInput.extendedAbsoluteFlag,
                                                             viewportWidth: 0x0660,
                                                             viewportHeight: 0x02b0,
                                                             field6: 0x1122,
                                                             field7: 0x3344)
        #expect([UInt8](move.packet) == [0x00, 0x00, 0x00, 0x12,   // length = 4 + 14
                                        0x06, 0x00, 0x00, 0x00,   // type 6, little-endian
                                        0x06, 0x5f,               // x
                                        0x02, 0xaf,               // y
                                        0x10, 0x00,               // flags: the 0x1000 form
                                        0x06, 0x60,               // viewport width
                                        0x02, 0xb0,               // viewport height
                                        0x11, 0x22,               // extra word 6
                                        0x33, 0x44])              // extra word 7
    }

    /// The extension is encoded as an append, so the first ten body bytes have to be exactly the
    /// type-5 body — the one that is byte-exact against the official client's `SSL_write` capture
    /// (`...05000000 065f 02af 0800 0660 02b0`). If someone ever re-reads the builder and finds
    /// the extra words interleaved, this is the assertion that has to change.
    @Test func theFirstTenBodyBytesAreTheCapturedAbsoluteMoveBody() {
        let captured = NvstRemoteInput.absoluteMouseMove(x: 0x065f,
                                                         y: 0x02af,
                                                         viewportWidth: 0x0660,
                                                         viewportHeight: 0x02b0)
        let extended = NvstRemoteInput.ExtendedAbsoluteMouseMove(x: 0x065f,
                                                                 y: 0x02af,
                                                                 flags: NvstRemoteInput.absoluteFlag,
                                                                 viewportWidth: 0x0660,
                                                                 viewportHeight: 0x02b0,
                                                                 field6: 0,
                                                                 field7: 0)
        #expect(captured.count == 18)
        #expect(extended.body.prefix(10) == captured.dropFirst(8))
        #expect(extended.body.count == 14)
        #expect([UInt8](extended.body.suffix(4)) == [0, 0, 0, 0])
    }

    /// The flags word is whatever the caller names it — nothing is ORed in behind their back,
    /// because which bits type 6 wants there is the part that was never recovered.
    @Test func theFlagsWordIsWrittenExactlyAsGiven() {
        func flagsWord(_ flags: UInt16) -> UInt16 {
            let body = NvstRemoteInput.ExtendedAbsoluteMouseMove(x: 1, y: 2, flags: flags,
                                                                 viewportWidth: 3, viewportHeight: 4,
                                                                 field6: 5, field7: 6).body
            return UInt16(body[4]) << 8 | UInt16(body[5])
        }
        #expect(NvstRemoteInput.extendedAbsoluteFlag == 0x1000)
        #expect(NvstRemoteInput.absoluteFlag == 0x0800)
        #expect(NvstRemoteInput.extendedAbsoluteFlag & NvstRemoteInput.absoluteFlag == 0)
        #expect(flagsWord(0) == 0)
        #expect(flagsWord(NvstRemoteInput.extendedAbsoluteFlag) == 0x1000)
        #expect(flagsWord(NvstRemoteInput.absoluteFlag | NvstRemoteInput.extendedAbsoluteFlag) == 0x1800)
    }

    /// Full-width values must survive both extra words unclamped: they are opaque, so anything a
    /// caller puts in has to come out the other side byte for byte.
    @Test func theExtraWordsCarryEveryValueBigEndian() {
        for word in [UInt16.min, 1, 0x00ff, 0xff00, UInt16.max] {
            let body = NvstRemoteInput.ExtendedAbsoluteMouseMove(x: 0, y: 0, flags: 0,
                                                                 viewportWidth: 0, viewportHeight: 0,
                                                                 field6: word, field7: word).body
            #expect(UInt16(body[10]) << 8 | UInt16(body[11]) == word)
            #expect(UInt16(body[12]) << 8 | UInt16(body[13]) == word)
        }
    }

    /// A 22-byte inner packet pads to four eight-byte slots and carries the timestamp in its own,
    /// so the extended move is 48 bytes on the wire under command `0x206` — the same envelope
    /// arithmetic the shipping pointer packets go through.
    @Test func theExtendedMoveEnvelopesLikeEveryOtherPointerPacket() throws {
        let inner = NvstRemoteInput.ExtendedAbsoluteMouseMove(x: 0, y: 0, flags: 0,
                                                              viewportWidth: 0, viewportHeight: 0,
                                                              field6: 0, field7: 0).packet
        #expect(inner.count == 22)
        #expect(NvstRemoteInput.envelopePaddedLength(innerLength: 22) == 32)
        let framed = NvstRemoteInput.framed(inner, framing: .enveloped, sequence: 0,
                                            timestampMicroseconds: 0x0102030405060708)
        #expect([UInt8](framed.prefix(8)) == [0x00, 0x00, 0x00, 0x2c, 0x0e, 0x00, 0x00, 0x00])
        #expect(framed.count == 48)
        #expect(framed.dropFirst(8).prefix(22) == inner)
        #expect([UInt8](framed.dropFirst(30).prefix(2)) == [0, 0])
        #expect([UInt8](framed.suffix(8)) == [0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01])
        let wire = try NvstControlCommand(code: NvstRemoteInput.commandCode, payload: framed).encoded
        #expect(wire.prefix(4).map { String(format: "%02x", $0) }.joined() == "06023000")
    }

    /// Types 15 and 16 are an id and a body length and nothing more — no field layout, no capture,
    /// and for 15 not even an agreed direction. They stay declared and unencoded; this pins that,
    /// in the same spirit as `theHeartbeatShapeIsKnownButUnused`.
    @Test func windowFocusAndGeometryAreIdsWithNoRecoveredBody() {
        #expect(NvstRemoteInput.PacketType.absoluteMouseMoveExtended.rawValue == 6)
        #expect(NvstRemoteInput.PacketType.windowFocus.rawValue == 15)
        #expect(NvstRemoteInput.PacketType.windowGeometry.rawValue == 16)
        // The direction clash that blocks type 15: our Geronimo table reads the same id as a
        // server-to-client haptic event.
        #expect(GeronimoInputEventType.haptic.rawValue == 15)
        #expect(GeronimoInputEventType.windowGeometry.rawValue == 16)
    }
}
