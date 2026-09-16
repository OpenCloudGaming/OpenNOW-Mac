import Foundation
import Testing
@testable import OpenNOW

@Suite struct ControllerBindingOutputLedgerTests {
    private func key(_ device: InputDeviceID, code: UInt16 = 49, down: Bool, modifiers: KeyboardModifiers = []) -> UserInputEvent {
        .keyboard(KeyboardEvent(deviceID: device, keyCode: code, scanCode: code, modifiers: modifiers,
                                isPressed: down, timestamp: MediaTimestamp(nanoseconds: 1)))
    }

    private func keyboard(_ events: [UserInputEvent]) -> [KeyboardEvent] {
        events.compactMap { if case .keyboard(let value) = $0 { value } else { nil } }
    }

    @Test func plainThenShiftedSharedKeyUpdatesAndReleasesModifiers() {
        var ledger = ControllerBindingOutputLedger()
        _ = ledger.events(for: key("plain", down: true))
        let shifted = keyboard(ledger.events(for: key("shifted", down: true, modifiers: .shift)))
        #expect(shifted.map(\.isPressed) == [false, true])
        #expect(shifted.map(\.modifiers) == [.shift, .shift])
        let plainReleased = ledger.events(for: key("plain", down: false))
        #expect(plainReleased.isEmpty)
        let final = keyboard(ledger.events(for: key("shifted", down: false, modifiers: .shift)))
        #expect(final.map(\.isPressed) == [false])
        #expect(final.map(\.modifiers) == [[]])
    }

    @Test func shiftedThenPlainSharedKeyDropsShiftWithoutDroppingHeldKey() {
        var ledger = ControllerBindingOutputLedger()
        _ = ledger.events(for: key("shifted", down: true, modifiers: .shift))
        let plainPressed = ledger.events(for: key("plain", down: true))
        #expect(plainPressed.isEmpty)
        let unshifted = keyboard(ledger.events(for: key("shifted", down: false, modifiers: .shift)))
        #expect(unshifted.map(\.isPressed) == [false, true])
        #expect(unshifted.map(\.modifiers) == [[], []])
        let final = keyboard(ledger.events(for: key("plain", down: false)))
        #expect(final.map(\.isPressed) == [false])
        #expect(final.map(\.modifiers) == [[]])
    }

    @Test func modifiersSharedAcrossDifferentKeysRemainUntilLastOwnerReleases() {
        var ledger = ControllerBindingOutputLedger()
        _ = ledger.events(for: key("first", code: 49, down: true, modifiers: .shift))
        _ = ledger.events(for: key("second", code: 0, down: true, modifiers: .shift))
        let partial = keyboard(ledger.events(for: key("first", code: 49, down: false, modifiers: .shift)))
        #expect(partial.map(\.keyCode) == [49])
        #expect(partial.map(\.modifiers) == [.shift])
        #expect(partial.map(\.isPressed) == [false])
        let final = keyboard(ledger.events(for: key("second", code: 0, down: false, modifiers: .shift)))
        #expect(final.map(\.keyCode) == [0])
        #expect(final.map(\.modifiers) == [[]])
    }

    @Test func differentModifierOwnersUseTheirUnion() {
        var ledger = ControllerBindingOutputLedger()
        _ = ledger.events(for: key("shift", down: true, modifiers: .shift))
        let combined = keyboard(ledger.events(for: key("control", down: true, modifiers: .control)))
        #expect(combined.map(\.modifiers) == [[.shift, .control], [.shift, .control]])
        let remaining = keyboard(ledger.events(for: key("shift", down: false, modifiers: .shift)))
        #expect(remaining.map(\.modifiers) == [.control, .control])
        #expect(remaining.map(\.isPressed) == [false, true])
    }

    @Test func unrelatedPlainKeyDoesNotClearAnotherKeysModifier() {
        var ledger = ControllerBindingOutputLedger()
        _ = ledger.events(for: key("shifted", code: 49, down: true, modifiers: .shift))
        let plain = keyboard(ledger.events(for: key("plain", code: 0, down: true)))
        #expect(plain.map(\.modifiers) == [.shift])
        let release = keyboard(ledger.events(for: key("plain", code: 0, down: false)))
        #expect(release.map(\.modifiers) == [.shift])
    }
}
