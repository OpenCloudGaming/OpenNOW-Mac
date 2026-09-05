import Foundation
import Testing
@testable import OpenNOW

/// The seat's rumble command (`0x010b`) and the client's haptics enable (RI type 13), as the
/// official client's disassembly lays them out. See `NvstHapticEvent` for the recovery.
@Suite struct NvstHapticEventTests {
    private func command(_ payload: [UInt8], code: UInt16 = 0x010b) -> NvstControlCommand {
        NvstControlCommand(code: NvstControlCommandCode(rawValue: code), payload: Data(payload))
    }

    @Test func parsesStateRecords() {
        // kind 1, 12 bytes: pad 0 left 0x8000 right 0x4000; pad 1 silent.
        let parsed = NvstHapticEvent.parse(command([
            0x01, 0x00, 0x0c, 0x00,
            0x00, 0x00, 0x00, 0x80, 0x00, 0x40,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
        ]))
        #expect(parsed == [
            NvstHapticEvent(gamepadIndex: 0, leftMotor: 0x8000, rightMotor: 0x4000),
            NvstHapticEvent(gamepadIndex: 1, leftMotor: 0, rightMotor: 0),
        ])
        #expect(parsed?.first?.durationMilliseconds == nil)
        #expect(parsed?.first?.effectiveDurationMilliseconds == NvstHapticEvent.defaultDurationMilliseconds)
        #expect(parsed?.last?.isSilent == true)
    }

    @Test func parsesPulseRecordsWithDuration() {
        let parsed = NvstHapticEvent.parse(command([
            0x02, 0x00, 0x08, 0x00,
            0x02, 0x00, 0xff, 0xff, 0x00, 0x00, 0xfa, 0x00,
        ]))
        #expect(parsed == [NvstHapticEvent(gamepadIndex: 2, leftMotor: 0xffff, rightMotor: 0, durationMilliseconds: 250)])
        #expect(parsed?.first?.effectiveDurationMilliseconds == 250)
    }

    /// Geronimo substitutes 1000 ms for a zero duration; so does the parse.
    @Test func zeroDurationFallsBackToDefault() {
        let parsed = NvstHapticEvent.parse(command([0x02, 0x00, 0x08, 0x00, 0x00, 0x00, 0x10, 0x00, 0x10, 0x00, 0x00, 0x00]))
        #expect(parsed?.first?.durationMilliseconds == 0)
        #expect(parsed?.first?.effectiveDurationMilliseconds == 1000)
    }

    /// The official client ignores slots above 3; a declared length longer than the blob yields
    /// only the whole records that arrived.
    @Test func ignoresOutOfRangeSlotsAndTruncatedTails() {
        let parsed = NvstHapticEvent.parse(command([
            0x01, 0x00, 0x20, 0x00,
            0x07, 0x00, 0x01, 0x00, 0x01, 0x00,
            0x03, 0x00, 0x02, 0x00, 0x03, 0x00,
            0x00, 0x00, 0x04,
        ]))
        #expect(parsed == [NvstHapticEvent(gamepadIndex: 3, leftMotor: 2, rightMotor: 3)])
    }

    @Test func unknownKindIsAHapticCommandWithNoRecords() {
        #expect(NvstHapticEvent.parse(command([0x09, 0x00, 0x06, 0x00, 0, 0, 0, 0, 0, 0])) == [])
        #expect(NvstHapticEvent.parse(command([0x01])) == [])
    }

    @Test func otherCommandsAreNotHaptic() {
        #expect(NvstHapticEvent.parse(command([0x01, 0x00, 0x06, 0x00, 0, 0, 0, 0, 0, 0], code: 0x010f)) == nil)
    }

    @Test func payloadRoundTrips() {
        let events = [
            NvstHapticEvent(gamepadIndex: 0, leftMotor: 1000, rightMotor: 2000, durationMilliseconds: 300),
            NvstHapticEvent(gamepadIndex: 1, leftMotor: 0, rightMotor: 65535, durationMilliseconds: 50),
        ]
        let payload = NvstHapticEvent.payload(kind: NvstHapticEvent.pulseKind, events: events)
        #expect(payload.count == 4 + 16)
        #expect(NvstHapticEvent.parse(NvstControlCommand(code: .hapticEvent, payload: payload)) == events)
    }

    /// `RiClientBackend::enableHaptics(true)`: RI packet type 13, body length 2, body `01 00`.
    @Test func hapticsStatePacketMatchesTheOfficialLayout() {
        let packet = NvstRemoteInput.hapticsState(enabled: true)
        #expect([UInt8](packet) == [0x00, 0x00, 0x00, 0x06, 0x0d, 0x00, 0x00, 0x00, 0x01, 0x00])
        #expect([UInt8](NvstRemoteInput.hapticsState(enabled: false)).suffix(2) == [0x00, 0x00])
    }

    @Test func controlCommandNamesTheHapticCode() {
        #expect(NvstControlCommandCode.hapticEvent.rawValue == 0x010b)
        #expect(NvstControlCommandCode.hapticEvent.name == "haptic-event")
    }
}

@Suite struct NvstHdrModeNotificationTests {
    @Test func parsesModeAndDetail() {
        let command = NvstControlCommand(code: .hdrMode, payload: Data([0x01, 0, 0, 0, 0x2a, 0, 0, 0]))
        let parsed = NvstHdrModeNotification.parse(command)
        #expect(parsed == NvstHdrModeNotification(mode: .hdr, detail: 42))
        #expect(parsed?.isHDR == true)
        #expect(parsed?.summary == "mode=hdr detail=42")
    }

    /// The official dispatcher rejects a mode above 2 and raises nothing.
    @Test func rejectsUnknownModes() {
        #expect(NvstHdrModeNotification.parse(NvstControlCommand(code: .hdrMode, payload: Data([0x03, 0, 0, 0]))) == nil)
        #expect(NvstHdrModeNotification.parse(NvstControlCommand(code: .hdrMode, payload: Data([0x00]))) == nil)
        #expect(NvstHdrModeNotification.parse(NvstControlCommand(code: .systemCursor, payload: Data([0, 0, 0, 0]))) == nil)
    }

    @Test func sdrWithoutDetail() {
        let parsed = NvstHdrModeNotification.parse(NvstControlCommand(code: .hdrMode, payload: Data([0, 0, 0, 0])))
        #expect(parsed == NvstHdrModeNotification(mode: .sdr, detail: 0))
        #expect(parsed?.isHDR == false)
    }
}
