import Foundation
import Testing
@testable import OpenNOW

/// The raw-HID codec, byte for byte as the official client's `RiClientBackend` writes it and
/// `ServerControl::handleServerCommand` reads it. See `NvstHidPassthrough`.
@Suite struct NvstHidPassthroughTests {
    @Test func changeEventIsA14ByteBigEndianBodyUnderType0x12() {
        let event = NvstHidPassthrough.ChangeEvent(deviceId: 2, change: .added, flags: 0x0000_0001, vendorId: 0x054c, productId: 0x09cc, field3: 0x0100, field4: 0x0005)
        let packet = [UInt8](event.packet)
        // [u32 BE len 18][u32 LE type 0x12][body]
        #expect(Array(packet[0..<8]) == [0x00, 0x00, 0x00, 0x12, 0x12, 0x00, 0x00, 0x00])
        #expect(Array(packet[8...]) == [0x02, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x4c, 0x09, 0xcc, 0x01, 0x00, 0x00, 0x05])
    }

    @Test func removalUsesControlThree() {
        let packet = [UInt8](NvstHidPassthrough.ChangeEvent(deviceId: 0, change: .removed, vendorId: 1, productId: 2).packet)
        #expect(packet[9] == 0x03)
    }

    @Test func reportRidesTheGamepadCommandWithThePartiallyReliableWrapper() {
        let report = NvstHidPassthrough.Report(deviceId: 1, kind: 0, reportType: 1, data: Data([0xaa, 0xbb, 0xcc]))
        let command = report.command(sequence: 0x0102, timestampMicroseconds: 0x0000_0000_0001_0000)
        #expect(command.code == .gamepadEvent)
        let bytes = [UInt8](command.payload)
        #expect(bytes[0] == 0x23)
        #expect(Array(bytes[1..<9]) == [0, 0, 0, 0, 0, 1, 0, 0])
        #expect(bytes[9] == 0x26)
        #expect(bytes[10] == 1)
        #expect(Array(bytes[11..<13]) == [0x01, 0x02])
        #expect(bytes[13] == 0x21)
        // 7-byte event header + 3 data bytes.
        #expect(Array(bytes[14..<16]) == [0x00, 0x0a])
        #expect(Array(bytes[16...]) == [0x11, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0xaa, 0xbb, 0xcc])
    }

    @Test func outputReportParsesFromTheRemoteInputCommand() {
        let payload = Data([0x11, 0, 0, 0, 0x02, 0x00, 0x02, 0x05, 0x11, 0x22])
        let report = NvstHidPassthrough.parseOutputReport(NvstControlCommand(code: .remoteInput, payload: payload))
        #expect(report == NvstHidPassthrough.Report(deviceId: 2, kind: 0, reportType: 2, data: Data([0x05, 0x11, 0x22])))
    }

    /// The official dispatcher's own guard: fewer than seven bytes is "Corrupted ... PACKET_HID".
    @Test func shortOrForeignPayloadsAreNotOutputReports() {
        #expect(NvstHidPassthrough.parseOutputReport(NvstControlCommand(code: .remoteInput, payload: Data([0x11, 0, 0, 0, 1, 2]))) == nil)
        #expect(NvstHidPassthrough.parseOutputReport(NvstControlCommand(code: .remoteInput, payload: Data([0x1a, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7]))) == nil)
        #expect(NvstHidPassthrough.parseOutputReport(NvstControlCommand(code: .hapticEvent, payload: Data([0x11, 0, 0, 0, 1, 2, 3]))) == nil)
    }

    @Test func changeResponseParses() {
        let payload = Data([0x1a, 0, 0, 0, 0x03, 0x01, 0x00, 0x00, 0x00, 0x2a, 0x01])
        let response = NvstHidPassthrough.ChangeResponse.parse(NvstControlCommand(code: .remoteInput, payload: payload))
        #expect(response == NvstHidPassthrough.ChangeResponse(deviceId: 3, field: 1, requestId: 42, status: 1))
    }

    @Test func seatCapabilityBits() {
        let capability = NvstHidPassthrough.SeatCapability(raw: 0x3)
        #expect(capability.supportsDualShock4 && capability.supportsDualSense)
        #expect(!NvstHidPassthrough.SeatCapability(raw: 0x4).supportsDualShock4)
    }
}
