//
//  StreamHUDGamepadTracker.swift
//  OpenNOW
//
//  Edge-detects gamepad navigation for the stream HUD. Pure state machine over GamepadState, so it
//  belongs to the model layer and is testable without a rendered HUD.
//

import Foundation

/// Per-device gamepad edge tracking for HUD navigation. A plain class on
/// purpose: mutating it from input callbacks must not invalidate the view.
@MainActor
final class StreamHUDGamepadTracker {
    enum NavigationStep {
        case move(Int)
        case activate
        case back
    }

    var lastButtons: [InputDeviceID: GamepadButtons] = [:]
    var lastStickStep: [InputDeviceID: Int] = [:]

    func reset() {
        lastButtons.removeAll()
        lastStickStep.removeAll()
    }

    func navigationStep(_ state: GamepadState) -> NavigationStep? {
        let previousButtons = lastButtons[state.deviceID] ?? state.buttons
        let pressed = state.buttons.subtracting(previousButtons)
        lastButtons[state.deviceID] = state.buttons

        let horizontal = abs(state.leftStickX) >= abs(state.leftStickY) ? state.leftStickX : 0
        let vertical = abs(state.leftStickY) > abs(state.leftStickX) ? state.leftStickY : 0
        let stickStep: Int = horizontal > 0.6 || vertical < -0.6 ? 1 : (horizontal < -0.6 || vertical > 0.6 ? -1 : 0)
        let previousStickStep = lastStickStep[state.deviceID] ?? 0
        lastStickStep[state.deviceID] = stickStep

        if pressed.contains(.south) { return .activate }
        if pressed.contains(.east) { return .back }
        if pressed.contains(.dpadRight) || pressed.contains(.dpadDown) { return .move(1) }
        if pressed.contains(.dpadLeft) || pressed.contains(.dpadUp) { return .move(-1) }
        if stickStep != 0, stickStep != previousStickStep { return .move(stickStep) }
        return nil
    }
}
