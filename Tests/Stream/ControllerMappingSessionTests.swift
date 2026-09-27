import Foundation
import Testing
@testable import OpenNOW

@Suite struct ControllerMappingSessionTests {
    private let stamp = MediaTimestamp(nanoseconds: 123)
    private let device: InputDeviceID = "native-first"

    private func gamepad(_ events: [UserInputEvent]) -> GamepadState? {
        events.compactMap { if case .gamepad(let state) = $0 { state } else { nil } }.last
    }

    private func keys(_ events: [UserInputEvent]) -> [KeyboardEvent] {
        events.compactMap { if case .keyboard(let key) = $0 { key } else { nil } }
    }

    @Test func unassignedNativeInputPreservesEveryBitAndAnalogValue() throws {
        // `.guide` deliberately defaults to an app action, which consumes `.mode`; this test is
        // about a passthrough profile, so it asks for the passthrough guide explicitly.
        var session = ControllerMappingSession(deviceID: device, playerIndex: 2, guideBinding: .passthroughButton)
        let input = ControllerInputSnapshot(buttons: GamepadButtons(rawValue: 0xFFFF_FFFF), leftTrigger: 0.1234567,
                                            rightTrigger: 0.9876543, leftStickX: -0.2345678, leftStickY: 0.3456789,
                                            rightStickX: 0.4567891, rightStickY: -0.5678912)
        let events = session.process(input, now: .now, timestamp: stamp).events
        #expect(events == [.gamepad(input.gamepadState(deviceID: device, playerIndex: 2, timestamp: stamp))])
        #expect(session.process(input, now: .now, timestamp: stamp).events.isEmpty)
        #expect(try #require(gamepad(events)).buttons.contains([.mode, .quickAccess, .leftGrip]))
    }

    @Test func configuredControlConsumesOnlyItsOriginalButton() throws {
        let profile = ControllerMappingProfile(name: "Custom", family: .generic, bindings: [
            .faceA: .keyboardKey(keyCode: 49, modifiers: []),
            .guide: .passthroughButton,
        ])
        var session = ControllerMappingSession(deviceID: device, playerIndex: 0, profile: profile, guideBinding: .passthroughButton)
        let input = ControllerInputSnapshot(buttons: [.south, .east, .mode, .quickAccess, .leftGrip], leftTrigger: 0.5123456, rightStickX: -0.654321)
        let events = session.process(input, now: .now, timestamp: stamp).events
        let output = try #require(gamepad(events))
        #expect(output.buttons == [.east, .mode, .quickAccess, .leftGrip])
        #expect(output.leftTrigger == input.leftTrigger)
        #expect(output.rightStickX == input.rightStickX)
        #expect(keys(events).map(\.keyCode) == [49])
        #expect(keys(events).map(\.isPressed) == [true])
    }

    @Test func unchangedHeldStickContinuesMovingAndChordSettles() {
        var profile = ControllerMappingProfile(name: "Custom", family: .generic, bindings: [
            .faceA: .gamepadChord(ControllerButtonChord(buttons: [.rightShoulder, .north])),
        ])
        profile.leftStick.mode = .mouse
        var session = ControllerMappingSession(deviceID: device, playerIndex: 0, profile: profile)
        let input = ControllerInputSnapshot(buttons: [.south], leftStickX: 1)
        let now = ContinuousClock.now
        let first = session.process(input, now: now, timestamp: stamp).events
        let second = session.process(input, now: now.advanced(by: .milliseconds(60)), timestamp: stamp).events
        #expect(gamepad(first)?.buttons == [.rightShoulder])
        #expect(gamepad(second)?.buttons == [.rightShoulder, .north])
        for events in [first, second] {
            #expect(gamepad(events)?.leftStickX == 0)
            #expect(events.contains { if case .mouse(.moved(_, let delta, _, _)) = $0 { delta > 0 } else { false } })
        }
    }

    @Test func sharedKeyAndMouseBindingsReleaseOnlyAfterLastControl() {
        let profile = ControllerMappingProfile(name: "Shared", family: .generic, bindings: [
            .faceA: .keyboardKey(keyCode: 49, modifiers: []), .faceB: .keyboardKey(keyCode: 49, modifiers: []),
            .faceX: .mouseButton(.left), .faceY: .mouseButton(.left),
        ])
        var session = ControllerMappingSession(deviceID: device, playerIndex: 0, profile: profile)
        _ = session.process(ControllerInputSnapshot(buttons: [.south, .east, .west, .north]), now: .now, timestamp: stamp)
        let partial = session.process(ControllerInputSnapshot(buttons: [.east, .north]), now: .now, timestamp: stamp).events
        #expect(keys(partial).isEmpty)
        #expect(!partial.contains { if case .mouse(.button) = $0 { true } else { false } })
        let released = session.process(ControllerInputSnapshot(), now: .now, timestamp: stamp).events
        #expect(keys(released).map(\.isPressed) == [false])
        #expect(released.contains(.mouse(.button(deviceID: device, button: .left, isPressed: false, timestamp: stamp))))
    }

    @Test func profileReplacementAndDisableReleaseBeforeNewInput() {
        let profile = ControllerMappingProfile(name: "Old", family: .generic, bindings: [.faceA: .keyboardKey(keyCode: 49, modifiers: [])])
        var session = ControllerMappingSession(deviceID: device, playerIndex: 0, profile: profile)
        let input = ControllerInputSnapshot(buttons: [.south])
        _ = session.process(input, now: .now, timestamp: stamp)
        var replacement = profile
        replacement.bindings[.faceA] = .mouseButton(.left)
        #expect(keys(session.configure(profile: replacement, timestamp: stamp)).map(\.isPressed) == [false])
        let next = session.process(input, now: .now, timestamp: stamp).events
        #expect(next.contains(.mouse(.button(deviceID: device, button: .left, isPressed: true, timestamp: stamp))))
        let disabled = session.configure(profile: nil, timestamp: stamp)
        #expect(disabled.contains(.mouse(.button(deviceID: device, button: .left, isPressed: false, timestamp: stamp))))
        #expect(gamepad(session.process(input, now: .now, timestamp: stamp).events)?.buttons == [.south])
    }

    @Test func lifecycleResetReleasesMappedOutputsAndClearsEdges() {
        let profile = ControllerMappingProfile(name: "Custom", family: .generic, bindings: [
            .faceA: .keyboardKey(keyCode: 49, modifiers: [.shift]), .faceB: .mouseButton(.right),
        ])
        var session = ControllerMappingSession(deviceID: device, playerIndex: 0, profile: profile)
        let input = ControllerInputSnapshot(buttons: [.south, .east])
        _ = session.process(input, now: .now, timestamp: stamp)
        let released = session.reset(timestamp: stamp)
        #expect(keys(released).map(\.isPressed) == [false])
        #expect(released.contains(.mouse(.button(deviceID: device, button: .right, isPressed: false, timestamp: stamp))))
        #expect(gamepad(released)?.buttons.isEmpty == true)
        #expect(keys(session.process(input, now: .now, timestamp: stamp).events).map(\.isPressed) == [true])
    }

    @Test func separateIdenticalPadsDoNotShareBindingState() {
        let profile = ControllerMappingProfile(name: "Identical pads", family: .generic, bindings: [.faceA: .keyboardKey(keyCode: 49, modifiers: [])])
        var first = ControllerMappingSession(deviceID: "native-uuid-one", playerIndex: 0, profile: profile)
        var second = ControllerMappingSession(deviceID: "native-uuid-two", playerIndex: 1)
        let input = ControllerInputSnapshot(buttons: [.south])
        #expect(keys(first.process(input, now: .now, timestamp: stamp).events).count == 1)
        let untouched = second.process(input, now: .now, timestamp: stamp).events
        #expect(keys(untouched).isEmpty)
        #expect(gamepad(untouched)?.buttons == [.south])
        _ = first.reset(timestamp: stamp)
        #expect(second.process(input, now: .now, timestamp: stamp).events.isEmpty)
    }

    @Test func outputLedgerKeepsSharedRemoteKeysHeldAcrossControllers() {
        var ledger = ControllerBindingOutputLedger()
        func key(_ id: InputDeviceID, _ down: Bool) -> UserInputEvent {
            .keyboard(KeyboardEvent(deviceID: id, keyCode: 49, scanCode: 49, isPressed: down, timestamp: stamp))
        }
        let results = [
            !ledger.events(for: key("first", true)).isEmpty,
            !ledger.events(for: key("second", true)).isEmpty,
            !ledger.events(for: key("first", false)).isEmpty,
            !ledger.events(for: key("second", false)).isEmpty,
            !ledger.events(for: .mouse(.button(deviceID: "first", button: .left, isPressed: true, timestamp: stamp))).isEmpty,
            !ledger.events(for: .mouse(.button(deviceID: "second", button: .left, isPressed: true, timestamp: stamp))).isEmpty,
            !ledger.events(for: .mouse(.button(deviceID: "first", button: .left, isPressed: false, timestamp: stamp))).isEmpty,
            !ledger.events(for: .mouse(.button(deviceID: "second", button: .left, isPressed: false, timestamp: stamp))).isEmpty,
        ]
        #expect(results == [true, false, false, true, true, false, false, true])
    }

    @Test func dualShockTouchBeginsAndEndsWithoutPhantomMotion() {
        let profile = ControllerMappingProfile(name: "Touch", family: .dualShock4, touchpad: ControllerPadSettings(mode: .mouse),
                                               bindings: [.touchpadClick: .mouseButton(.left)])
        var session = ControllerMappingSession(deviceID: device, playerIndex: 0, profile: profile)
        func frame(_ x: Float, touched: Bool, pressed: Bool = false) -> ControllerInputSnapshot {
            ControllerInputSnapshot(touchpad: ControllerTrackpadState(x: x, touched: touched, pressed: pressed))
        }
        let start = session.process(frame(0.2, touched: true), now: .now, timestamp: stamp).events
        #expect(!start.contains { if case .mouse(.moved) = $0 { true } else { false } })
        let drag = session.process(frame(0.4, touched: true, pressed: true), now: .now, timestamp: stamp).events
        #expect(drag.contains { if case .mouse(.moved) = $0 { true } else { false } })
        let end = session.process(frame(0.4, touched: false), now: .now, timestamp: stamp).events
        #expect(!end.contains { if case .mouse(.moved) = $0 { true } else { false } })
        #expect(end.contains(.mouse(.button(deviceID: device, button: .left, isPressed: false, timestamp: stamp))))
        let restart = session.process(frame(-0.9, touched: true), now: .now, timestamp: stamp).events
        #expect(!restart.contains { if case .mouse(.moved) = $0 { true } else { false } })
    }

    @Test func familiesExposeOnlyRealControlsAndDualShockLabels() {
        #expect(!ControllerFamily.generic.controls.contains(.leftGrip))
        #expect(!ControllerFamily.generic.controls.contains(.touchpadClick))
        #expect(ControllerFamily.dualShock4.controls.contains(.touchpadClick))
        #expect(!ControllerFamily.dualShock4.controls.contains(.rightPadClick))
        #expect(ControllerFamily.dualShock4.label(for: .faceA) == "×")
        #expect(ControllerFamily.dualShock4.label(for: .select) == "SHARE")
        #expect(ControllerFamily.dualShock4.label(for: .start) == "OPTIONS")
        #expect(ControllerFamily.steam.controls.contains(.guide))
        #expect(ControllerFamily.generic.controls.contains(.guide))
        #expect(ControllerFamily.dualShock4.controls.contains(.guide))
        #expect(ControllerFamily.steam.label(for: .guide) == "Steam")
        #expect(ControllerFamily.generic.label(for: .guide) == "Guide")
        #expect(ControllerFamily.dualShock4.label(for: .guide) == "PS")
    }
}
