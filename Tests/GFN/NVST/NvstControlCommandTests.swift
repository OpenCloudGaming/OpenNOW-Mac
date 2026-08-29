import Foundation
import Testing
@testable import OpenNOW

@Suite(.serialized)
struct NvstControlCommandTests {
    static func packet(code: UInt16, payload: [UInt8]) -> Data {
        var data = Data()
        data.append(UInt8(code & 0xff))
        data.append(UInt8(code >> 8))
        data.append(UInt8(payload.count & 0xff))
        data.append(UInt8(payload.count >> 8))
        data.append(contentsOf: payload)
        return data
    }

    @Test func parsesOnePacket() {
        let (commands, trailing) = NvstControlCommand.parse(Self.packet(code: 0x10e, payload: [1, 2, 3]))
        #expect(commands.count == 1)
        #expect(commands.first?.code == 0x10e)
        #expect(commands.first?.payload == Data([1, 2, 3]))
        #expect(trailing.isEmpty)
    }

    @Test func parsesConcatenatedPackets() {
        var data = Self.packet(code: 0x111, payload: [0xaa])
        data.append(Self.packet(code: 0x110, payload: [0xbb, 0xcc]))
        let (commands, trailing) = NvstControlCommand.parse(data)
        #expect(commands.map(\.code) == [0x111, 0x110])
        #expect(trailing.isEmpty)
    }

    /// A short read means the framing assumption is wrong, so the remainder must survive into the
    /// log rather than being silently dropped.
    @Test func reportsTruncatedTail() {
        var data = Self.packet(code: 0x102, payload: [1, 2, 3, 4])
        data.append(contentsOf: [0x09, 0x01, 0x10, 0x00, 0x01])
        let (commands, trailing) = NvstControlCommand.parse(data)
        #expect(commands.count == 1)
        #expect(trailing.count == 5)
    }

    @Test func decodesTerminationReasonAsBigEndian() {
        let data = Self.packet(code: 0x109, payload: [0x80, 0x03, 0x00, 0x1a])
        let command = NvstControlCommand.parse(data).commands[0]
        #expect(command.terminationReason == 0x8003001a)
        #expect(command.summary.contains("termination"))
        #expect(command.summary.contains("0x8003001a"))
        #expect(command.summary.contains("NVST_DISCONN_SERVER_TERMINATED_FULL_TDR_OCCURRED"))
    }

    @Test func decodesCommandOutcome() {
        let data = Self.packet(code: 0x102, payload: [0x1f, 0x03, 0x02, 0x00])
        let command = NvstControlCommand.parse(data).commands[0]
        #expect(command.commandOutcome?.command == 0x31f)
        #expect(command.commandOutcome?.outcome == 2)
    }

    /// The seat ends the session with `NVST_NETERR_CLIENT_TIMED_OUT` when this packet does not
    /// arrive inside 10 s, so its shape is load-bearing: code `0x200`, 4-byte little-endian value.
    @Test func encodesThePingBackAckKeepalive() throws {
        let command = NvstControlCommand.pingBackAck(streamValue: 0x0102_0304)
        #expect(command.code == 0x200)
        #expect(command.payload == Data([0x04, 0x03, 0x02, 0x01]))
        #expect([UInt8](try command.encoded) == [0x00, 0x02, 0x04, 0x00, 0x04, 0x03, 0x02, 0x01])
        #expect(NvstControlCommand.pingBackIntervalSeconds == 3)
    }

    @Test func encodingRoundTripsThroughTheParser() throws {
        let original = NvstControlCommand(code: 0x31f, payload: Data([1, 2, 3, 4, 5]))
        let (commands, trailing) = NvstControlCommand.parse(try original.encoded)
        #expect(commands == [original])
        #expect(trailing.isEmpty)
    }

    /// With no `rtcp_on_sctp_private` channel a PLI has nowhere to go, so the control channel's
    /// IDR request is the only way to recover a broken reference chain.
    @Test func encodesTheIdrRequest() throws {
        let command = NvstControlCommand.idrRequest()
        #expect(command.code == 0x302)
        #expect([UInt8](try command.encoded) == [0x02, 0x03, 0x02, 0x00, 0x00, 0x00])
        #expect([UInt8](NvstControlCommand.idrRequest(streamIndex: 1).payload) == [0x01, 0x00])
        #expect(NvstControlCommandCode(rawValue: 0x302).name == "idr-request")
    }

    /// Three 64-bit little-endian words: first frame, last frame, stream index.
    @Test func encodesTheFrameInvalidationRange() throws {
        let command = NvstControlCommand.frameInvalidationRange(first: 1, last: 0x0102, streamIndex: 0)
        #expect(command.code == 0x301)
        #expect(command.payload.count == 24)
        #expect([UInt8](command.payload.prefix(8)) == [1, 0, 0, 0, 0, 0, 0, 0])
        #expect([UInt8](command.payload.dropFirst(8).prefix(8)) == [0x02, 0x01, 0, 0, 0, 0, 0, 0])
        #expect([UInt8](command.payload.suffix(8)) == [0, 0, 0, 0, 0, 0, 0, 0])
        #expect([UInt8](try command.encoded.prefix(4)) == [0x01, 0x03, 0x18, 0x00])
        #expect(NvstControlCommandCode(rawValue: 0x301).name == "frame-invalidation-range")
    }

    /// The seat sends some control messages as JSON; hex-dumping those hides the schema.
    @Test func recognisesTextualPayloads() {
        let json = Array(#"{"messageType":"NvExtendedControllerInfo"}"#.utf8)
        let textual = NvstControlCommand(code: 0x10a, payload: Data(json))
        #expect(textual.isTextual)
        #expect(textual.text().hasPrefix("{\"messageType\""))
        #expect(textual.text(limit: 4) == "{\"me…(\(json.count) bytes)")

        #expect(!NvstControlCommand(code: 0x111, payload: Data([0x01, 0x00, 0xff, 0x7f])).isTextual)
        // Printable but not JSON, and too short to judge, are both not text.
        #expect(!NvstControlCommand(code: 0x10a, payload: Data(Array("hello".utf8))).isTextual)
        #expect(!NvstControlCommand(code: 0x10a, payload: Data([UInt8(ascii: "{")])).isTextual)
    }

    /// Three little-endian 32-bit words: stream index, requested state, frame number. The window
    /// state announces 19 ("active") at frame zero — an all-zero payload leaves the session looking
    /// inactive and the seat then withholds its cursor mode updates.
    @Test func encodesTheWindowAndSystemStateChanges() throws {
        let window = NvstControlCommand.windowStateChange()
        #expect(window.code == 0x320)
        #expect(window.payload.count == 12)
        #expect([UInt8](window.payload) == [0, 0, 0, 0, 19, 0, 0, 0, 0, 0, 0, 0])
        #expect([UInt8](try window.encoded.prefix(4)) == [0x20, 0x03, 0x0c, 0x00])
        #expect(NvstControlCommand.systemStateChange().code == 0x321)
        #expect([UInt8](NvstControlCommand.systemStateChange().payload) == Array(repeating: 0, count: 12))

        let stated = NvstControlCommand.windowStateChange(state: 1, frameNumber: 0x0203)
        #expect([UInt8](stated.payload) == [0, 0, 0, 0, 0x01, 0, 0, 0, 0x03, 0x02, 0, 0])
        #expect(NvstControlCommandCode(rawValue: 0x320).name == "window-state-change")
        #expect(NvstControlCommandCode(rawValue: 0x321).name == "system-state-change")
    }

    @Test func namesUnknownCodesAsRaw() {
        let command = NvstControlCommand(code: 0x7fff, payload: Data())
        #expect(NvstControlCommandCode(rawValue: 0x7fff).name == nil)
        #expect(command.summary.hasPrefix("0x7fff len=0"))
    }
}
