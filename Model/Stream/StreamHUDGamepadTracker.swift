//  Edge-detects gamepad navigation for the stream HUD. Pure state machine over GamepadState, so it
//  belongs to the model layer and is testable without a rendered HUD.
//

import Foundation

/// Per-device gamepad edge tracking for HUD navigation. A plain class on
/// purpose: mutating it from input callbacks must not invalidate the view.
@MainActor
final class StreamHUDGamepadTracker {
    enum NavigationStep: Equatable {
        /// A direction, not a ±1: the HUD's icon panels are grids, and "down" has to mean the
        /// row below rather than the next tile to the right.
        case move(StreamHUDFocusDirection)
        case activate
        case back
    }

    var lastButtons: [InputDeviceID: GamepadButtons] = [:]
    var lastStickDirection: [InputDeviceID: StreamHUDFocusDirection?] = [:]

    func reset() {
        lastButtons.removeAll()
        lastStickDirection.removeAll()
    }

    func navigationStep(_ state: GamepadState) -> NavigationStep? {
        let previousButtons = lastButtons[state.deviceID] ?? state.buttons
        let pressed = state.buttons.subtracting(previousButtons)
        lastButtons[state.deviceID] = state.buttons

        let stickDirection = Self.stickDirection(x: state.leftStickX, y: state.leftStickY)
        let previousStickDirection = lastStickDirection[state.deviceID] ?? nil
        lastStickDirection[state.deviceID] = stickDirection

        if pressed.contains(.south) { return .activate }
        if pressed.contains(.east) { return .back }
        if pressed.contains(.dpadRight) { return .move(.right) }
        if pressed.contains(.dpadLeft) { return .move(.left) }
        if pressed.contains(.dpadDown) { return .move(.down) }
        if pressed.contains(.dpadUp) { return .move(.up) }
        if let stickDirection, stickDirection != previousStickDirection { return .move(stickDirection) }
        return nil
    }

    /// The dominant stick axis past the 0.6 threshold, or nil in the dead zone. Stick up is +Y.
    static func stickDirection(x: Float, y: Float) -> StreamHUDFocusDirection? {
        if abs(x) >= abs(y) {
            if x > 0.6 { return .right }
            if x < -0.6 { return .left }
            return nil
        }
        if y > 0.6 { return .up }
        if y < -0.6 { return .down }
        return nil
    }
}
