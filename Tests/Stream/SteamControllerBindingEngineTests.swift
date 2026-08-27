import Foundation
import Testing
@testable import OpenNOW

private let device: InputDeviceID = "test-controller"
private let stamp = MediaTimestamp(nanoseconds: 0)
private let clock = ContinuousClock()

private func snapshot(buttons: GamepadButtons = [], leftTrigger: Float = 0, rightTrigger: Float = 0) -> SteamControllerInputSnapshot {
    SteamControllerInputSnapshot(buttons: buttons, leftTrigger: leftTrigger, rightTrigger: rightTrigger)
}

private func gamepadState(in events: [UserInputEvent]) -> GamepadState? {
    for event in events { if case .gamepad(let state) = event { return state } }
    return nil
}

@Suite struct SteamControllerBindingEngineTests {
    @Test func defaultProfilePassesButtonsThrough() {
        var engine = SteamControllerBindingEngine()
        let profile = SteamControllerMappingProfile(name: "Default")
        let result = engine.apply(profile: profile, snapshot: snapshot(buttons: [.south, .leftGrip]), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        let state = gamepadState(in: result.events)
        #expect(state?.buttons.contains(.south) == true)
        #expect(state?.buttons.contains(.leftGrip) == true)
        #expect(result.nextReapplyDelay == nil)
    }

    @Test func disabledControlDropsItsBit() {
        var engine = SteamControllerBindingEngine()
        let profile = SteamControllerMappingProfile(name: "Default", bindings: [.leftGrip: .disabled])
        let result = engine.apply(profile: profile, snapshot: snapshot(buttons: [.south, .leftGrip]), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        let state = gamepadState(in: result.events)
        #expect(state?.buttons.contains(.south) == true)
        #expect(state?.buttons.contains(.leftGrip) == false)
    }

    @Test func chordStaggersModifierThenAction() {
        var engine = SteamControllerBindingEngine()
        let profile = SteamControllerMappingProfile(name: "Default", bindings: [
            .leftGrip: .gamepadChord(SteamControllerGripCombo(buttons: [.rightShoulder, .south])),
        ])
        let t0 = clock.now
        let fresh = engine.apply(profile: profile, snapshot: snapshot(buttons: [.leftGrip]), deviceID: device, playerIndex: 0, now: t0, timestamp: stamp)
        let freshState = gamepadState(in: fresh.events)
        #expect(freshState?.buttons.contains(.rightShoulder) == true)
        #expect(freshState?.buttons.contains(.south) == false)
        #expect(fresh.nextReapplyDelay == SteamControllerBindingEngine.modifierLeadTime)

        let settled = engine.apply(profile: profile, snapshot: snapshot(buttons: [.leftGrip]), deviceID: device, playerIndex: 0, now: t0.advanced(by: SteamControllerBindingEngine.modifierLeadTime), timestamp: stamp)
        let settledState = gamepadState(in: settled.events)
        #expect(settledState?.buttons.contains(.south) == true)
        #expect(settled.nextReapplyDelay == nil)
    }

    @Test func keyboardBindingFiresOnPressAndReleaseEdgesOnly() {
        var engine = SteamControllerBindingEngine()
        let profile = SteamControllerMappingProfile(name: "Default", bindings: [
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
        var engine = SteamControllerBindingEngine()
        let profile = SteamControllerMappingProfile(name: "Default", bindings: [
            .rightPadClick: .mouseButton(.left),
        ])
        var pad = SteamControllerTrackpadState()
        pad.pressed = true
        let snap = SteamControllerInputSnapshot(rightPad: pad)
        let result = engine.apply(profile: profile, snapshot: snap, deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(result.events.contains { if case .mouse(.button(_, let button, let isPressed, _)) = $0 { button == .left && isPressed } else { false } })
    }

    @Test func boundTriggerZeroesAnalogPassthrough() {
        var engine = SteamControllerBindingEngine()
        let profile = SteamControllerMappingProfile(name: "Default", bindings: [
            .leftTrigger: .keyboardKey(keyCode: 1, modifiers: []),
        ])
        let result = engine.apply(profile: profile, snapshot: snapshot(leftTrigger: 0.8), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(gamepadState(in: result.events)?.leftTrigger == 0)
    }

    @Test func unboundTriggerPassesAnalogValueThrough() {
        var engine = SteamControllerBindingEngine()
        let profile = SteamControllerMappingProfile(name: "Default")
        let result = engine.apply(profile: profile, snapshot: snapshot(leftTrigger: 0.42), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(gamepadState(in: result.events)?.leftTrigger == 0.42)
    }

    @Test func rightPadMouseModeMovesCursor() {
        var engine = SteamControllerBindingEngine()
        var profile = SteamControllerMappingProfile(name: "Default")
        profile.rightPad = SteamControllerPadSettings(mode: .mouse)
        _ = engine.apply(profile: profile, snapshot: SteamControllerInputSnapshot(rightPad: SteamControllerTrackpadState(x: 0, y: 0, touched: true)), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        let result = engine.apply(profile: profile, snapshot: SteamControllerInputSnapshot(rightPad: SteamControllerTrackpadState(x: 0.1, y: 0, touched: true)), deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(result.events.contains { if case .mouse(.moved(_, let dx, _, _)) = $0 { dx > 0 } else { false } })
    }

    @Test func leftStickMouseModeMovesCursorAndZeroesAxis() {
        var engine = SteamControllerBindingEngine()
        var profile = SteamControllerMappingProfile(name: "Default")
        profile.leftStick = SteamControllerPadSettings(mode: .mouse)
        let snap = SteamControllerInputSnapshot(leftStickX: 0.8, leftStickY: 0)
        let result = engine.apply(profile: profile, snapshot: snap, deviceID: device, playerIndex: 0, now: clock.now, timestamp: stamp)
        #expect(gamepadState(in: result.events)?.leftStickX == 0)
        #expect(result.events.contains { if case .mouse(.moved(_, let dx, _, _)) = $0 { dx > 0 } else { false } })
    }
}
