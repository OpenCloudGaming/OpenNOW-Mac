import Foundation

/// Tells a Guide/Steam *tap* apart from the same bit's chord, local-cursor and power-off roles.
/// Edge- and history-based: a tap is a release with no other press and no pad motion during the hold.
public struct SteamGuideTapTracker: Sendable {
    /// Matches `SteamControllerLocalCursorInjector`'s dead zone, so "motion was injected" means
    /// exactly the samples that moved the real cursor.
    public static let padDeadzone: Float = 0.002

    struct DeviceState: Sendable {
        var isHeld = false
        var isDisqualified = false
        var isPadTouched = false
        var lastPadX: Float = 0
        var lastPadY: Float = 0
    }

    private var statesByDevice: [InputDeviceID: DeviceState] = [:]

    public init() {}

    public mutating func reset() {
        statesByDevice.removeAll()
    }

    public mutating func removeDevice(_ deviceID: InputDeviceID) {
        statesByDevice.removeValue(forKey: deviceID)
    }

    /// Returns true on the release edge of a qualifying tap. Must see every report for a device,
    /// including the ones the on-screen keyboard captures, or the hold history goes stale.
    public mutating func didReleaseTap(snapshot: ControllerInputSnapshot, deviceID: InputDeviceID) -> Bool {
        var state = statesByDevice[deviceID] ?? DeviceState()
        defer { statesByDevice[deviceID] = state }

        guard state.isHeld else {
            beginHold(&state, snapshot: snapshot)
            return false
        }
        guard snapshot.buttons.contains(.mode) else {
            let isQualifyingTap = !state.isDisqualified
            endHold(&state)
            return isQualifyingTap
        }
        continueHold(&state, snapshot: snapshot)
        return false
    }

    private func beginHold(_ state: inout DeviceState, snapshot: ControllerInputSnapshot) {
        guard snapshot.buttons.contains(.mode) else { return }
        state.isHeld = true
        state.isDisqualified = false
        state.isPadTouched = snapshot.rightPad.touched
        state.lastPadX = snapshot.rightPad.x
        state.lastPadY = snapshot.rightPad.y
    }

    private func endHold(_ state: inout DeviceState) {
        state.isHeld = false
        state.isDisqualified = false
        state.isPadTouched = false
    }

    private func continueHold(_ state: inout DeviceState, snapshot: ControllerInputSnapshot) {
        state.isDisqualified = state.isDisqualified || hasDisqualifyingInput(state, snapshot: snapshot)
        state.isPadTouched = snapshot.rightPad.touched
        state.lastPadX = snapshot.rightPad.x
        state.lastPadY = snapshot.rightPad.y
    }

    private func hasDisqualifyingInput(_ state: DeviceState, snapshot: ControllerInputSnapshot) -> Bool {
        guard snapshot.buttons.subtracting(.mode).isEmpty else { return true }
        guard !snapshot.rightPad.pressed else { return true }
        return hasInjectedPadMotion(state, snapshot: snapshot)
    }

    /// The injector sets its origin on the first touched frame, so only a delta from a previous
    /// touched frame counts as injected motion.
    private func hasInjectedPadMotion(_ state: DeviceState, snapshot: ControllerInputSnapshot) -> Bool {
        guard snapshot.rightPad.touched, state.isPadTouched else { return false }
        let deltaX = abs(snapshot.rightPad.x - state.lastPadX)
        let deltaY = abs(snapshot.rightPad.y - state.lastPadY)
        return max(deltaX, deltaY) > Self.padDeadzone
    }
}
