//
//  StreamOnScreenKeyboardModel.swift
//  OpenNOW
//
//  Drives the on-screen keyboard: it owns the key state and the pad/gamepad navigation, and
//  the overlay in View/ only renders it.
//

import Combine
import Foundation

/// Steam Deck-style on-screen keyboard: opened with Steam + X, dual trackpads each
/// aim a cursor on their half of the grid, pad click or L2/R2 types the aimed key,
/// d-pad/stick + A navigate and confirm for pads without trackpads. Transport
/// agnostic — the active stream host turns `StreamOSKOutput`s into input events.
@MainActor
final class StreamOnScreenKeyboardModel: ObservableObject {
    @Published private(set) var state = StreamOSKState()

    var onOutput: ((StreamOSKOutput) -> Void)?
    var onDismiss: (() -> Void)?

    private var navigator = StreamOSKGamepadNavigator()
    private var padClickHeld: [InputDeviceID: (left: Bool, right: Bool)] = [:]
    private var triggerHeld: [InputDeviceID: (left: Bool, right: Bool)] = [:]

    private static let triggerThreshold: Float = 0.5

    func reset() {
        state.reset()
        navigator.reset()
        padClickHeld.removeAll()
        triggerHeld.removeAll()
    }

    /// Raw Steam Controller/Deck report, delivered by the gamepad monitor while the
    /// keyboard captures the device. Buttons are already chord-stripped (no
    /// quickAccess, no chord-consumed X).
    func handleSteamSnapshot(deviceID: InputDeviceID, snapshot: SteamControllerInputSnapshot) {
        if snapshot.leftPad.touched {
            state.updatePadCursor(.left, x: snapshot.leftPad.x, y: snapshot.leftPad.y)
        } else {
            state.clearPadCursor(.left)
        }
        if snapshot.rightPad.touched {
            state.updatePadCursor(.right, x: snapshot.rightPad.x, y: snapshot.rightPad.y)
        } else {
            state.clearPadCursor(.right)
        }

        var clicks = padClickHeld[deviceID] ?? (left: false, right: false)
        if snapshot.leftPad.pressed, !clicks.left { apply(state.activatePadCursor(.left)) }
        if snapshot.rightPad.pressed, !clicks.right { apply(state.activatePadCursor(.right)) }
        clicks = (left: snapshot.leftPad.pressed, right: snapshot.rightPad.pressed)
        padClickHeld[deviceID] = clicks

        var triggers = triggerHeld[deviceID] ?? (left: false, right: false)
        let leftTrigger = snapshot.leftTrigger > Self.triggerThreshold
        let rightTrigger = snapshot.rightTrigger > Self.triggerThreshold
        if leftTrigger, !triggers.left { apply(state.activatePadCursor(.left)) }
        if rightTrigger, !triggers.right { apply(state.activatePadCursor(.right)) }
        triggers = (left: leftTrigger, right: rightTrigger)
        triggerHeld[deviceID] = triggers

        if let action = navigator.action(deviceID: deviceID, buttons: snapshot.buttons, leftStickX: snapshot.leftStickX, leftStickY: snapshot.leftStickY) {
            handleNavigationAction(action)
        }
    }

    /// Regular gamepad state path for controllers without trackpads.
    func handleGamepadState(_ gamepadState: GamepadState) {
        guard let action = navigator.action(deviceID: gamepadState.deviceID, buttons: gamepadState.buttons, leftStickX: gamepadState.leftStickX, leftStickY: gamepadState.leftStickY) else { return }
        handleNavigationAction(action)
    }

    func activateGridKey(row: Int, column: Int) {
        apply(state.activateGridKey(row: row, column: column))
    }

    func activateBarItem(_ index: Int) {
        apply(state.activateBarItem(index))
    }

    /// Drives the keyboard from an already-abstract navigation command. The stream hosts feed raw
    /// device reports because they also aim the trackpad cursors; the controller-mode catalog gets
    /// its input as high-level moves from `ControllerInputRouter` and has no cursor to aim.
    func handleNavigationAction(_ action: StreamOSKNavAction) {
        switch action {
        case .move(let dx, let dy): state.moveGridCursor(dx: dx, dy: dy)
        case .activate: apply(state.activateGridCursor())
        case .backspace: apply(state.activateKey(.backspace))
        case .space: apply(state.activateKey(.space))
        case .shift: apply(state.activateKey(.shift))
        case .enter: apply(state.activateKey(.enter))
        case .dismiss: apply(state.activateKey(.dismiss))
        }
    }

    private func apply(_ effect: StreamOSKEffect) {
        switch effect {
        case .output(let output): onOutput?(output)
        case .dismiss: onDismiss?()
        case .none: break
        }
    }
}
