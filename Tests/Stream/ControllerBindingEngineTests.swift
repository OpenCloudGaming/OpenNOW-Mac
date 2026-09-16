import Foundation
import Testing
@testable import OpenNOW

private let device: InputDeviceID = "test-controller"
private let stamp = MediaTimestamp(nanoseconds: 0)
private let clock = ContinuousClock()

private func snapshot(buttons: GamepadButtons = [], leftTrigger: Float = 0, rightTrigger: Float = 0) -> ControllerInputSnapshot {
    ControllerInputSnapshot(buttons: buttons, leftTrigger: leftTrigger, rightTrigger: rightTrigger)
}

private func gamepadState(in events: [UserInputEvent]) -> GamepadState? {
    for event in events { if case .gamepad(let state) = event { return state } }
    return nil
}

@Suite struct ControllerBindingEngineTests {
    @Test func defaultProfilePassesButtonsThrough() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Default")
        let result = engine.apply(profile: profile, snapshot: snapshot(buttons: [.south, .leftGrip]), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        let state = gamepadState(in: result.events)
        #expect(state?.buttons.contains(.south) == true)
        #expect(state?.buttons.contains(.leftGrip) == true)
        #expect(result.nextReapplyDelay == nil)
    }

    @Test func disabledControlDropsItsBit() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Default", bindings: [.leftGrip: .disabled])
        let result = engine.apply(profile: profile, snapshot: snapshot(buttons: [.south, .leftGrip]), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        let state = gamepadState(in: result.events)
        #expect(state?.buttons.contains(.south) == true)
        #expect(state?.buttons.contains(.leftGrip) == false)
    }

    @Test func chordStaggersModifierThenAction() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Default", bindings: [
            .leftGrip: .gamepadChord(ControllerButtonChord(buttons: [.rightShoulder, .south])),
        ])
        let t0 = clock.now
        let fresh = engine.apply(profile: profile, snapshot: snapshot(buttons: [.leftGrip]), deviceID: device, playerIndex: 0, now: t0, timestamp: stamp)
        let freshState = gamepadState(in: fresh.events)
        #expect(freshState?.buttons.contains(.rightShoulder) == true)
        #expect(freshState?.buttons.contains(.south) == false)
        #expect(fresh.nextReapplyDelay == ControllerBindingEngine.modifierLeadTime)

        let settled = engine.apply(profile: profile, snapshot: snapshot(buttons: [.leftGrip]), deviceID: device, playerIndex: 0, now: t0.advanced(by: ControllerBindingEngine.modifierLeadTime), timestamp: stamp)
        let settledState = gamepadState(in: settled.events)
        #expect(settledState?.buttons.contains(.south) == true)
        #expect(settled.nextReapplyDelay == nil)
    }

    @Test func keyboardBindingFiresOnPressAndReleaseEdgesOnly() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Default", bindings: [
            .faceA: .keyboardKey(keyCode: 49, modifiers: []),
        ])
        let pressed = engine.apply(profile: profile, snapshot: snapshot(buttons: [.south]), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(pressed.events.contains { if case .keyboard(let event) = $0 { event.isPressed && event.keyCode == 49 } else { false } })
        #expect(gamepadState(in: pressed.events)?.buttons.contains(.south) == false)

        let held = engine.apply(profile: profile, snapshot: snapshot(buttons: [.south]), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(!held.events.contains { if case .keyboard = $0 { true } else { false } })

        let released = engine.apply(profile: profile, snapshot: snapshot(), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(released.events.contains { if case .keyboard(let event) = $0 { !event.isPressed } else { false } })
    }

    @Test func mouseButtonBindingFiresOnEdges() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Default", bindings: [
            .rightPadClick: .mouseButton(.left),
        ])
        var pad = ControllerTrackpadState()
        pad.pressed = true
        let snap = ControllerInputSnapshot(rightPad: pad)
        let result = engine.apply(profile: profile, snapshot: snap, deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(result.events.contains { if case .mouse(.button(_, let button, let isPressed, _)) = $0 { button == .left && isPressed } else { false } })
    }

    @Test func boundTriggerZeroesAnalogPassthrough() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Default", bindings: [
            .leftTrigger: .keyboardKey(keyCode: 1, modifiers: []),
        ])
        let result = engine.apply(profile: profile, snapshot: snapshot(leftTrigger: 0.8), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(gamepadState(in: result.events)?.leftTrigger == 0)
    }

    @Test func unboundTriggerPassesAnalogValueThrough() {
        var engine = ControllerBindingEngine()
        let profile = ControllerMappingProfile(name: "Default")
        let result = engine.apply(profile: profile, snapshot: snapshot(leftTrigger: 0.42), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(gamepadState(in: result.events)?.leftTrigger == 0.42)
    }

    @Test func rightPadMouseModeMovesCursor() {
        var engine = ControllerBindingEngine()
        var profile = ControllerMappingProfile(name: "Default")
        profile.rightPad = ControllerPadSettings(mode: .mouse)
        _ = engine.apply(profile: profile, snapshot: ControllerInputSnapshot(rightPad: ControllerTrackpadState(x: 0, y: 0, touched: true)), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        let result = engine.apply(profile: profile, snapshot: ControllerInputSnapshot(rightPad: ControllerTrackpadState(x: 0.1, y: 0, touched: true)), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(result.events.contains { if case .mouse(.moved(_, let dx, _, _)) = $0 { dx > 0 } else { false } })
    }

    @Test func leftStickMouseModeMovesCursorAndZeroesAxis() {
        var engine = ControllerBindingEngine()
        var profile = ControllerMappingProfile(name: "Default")
        profile.leftStick = ControllerPadSettings(mode: .mouse)
        let snap = ControllerInputSnapshot(leftStickX: 0.8, leftStickY: 0)
        let result = engine.apply(profile: profile, snapshot: snap, deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(gamepadState(in: result.events)?.leftStickX == 0)
        #expect(result.events.contains { if case .mouse(.moved(_, let dx, _, _)) = $0 { dx > 0 } else { false } })
    }
}
