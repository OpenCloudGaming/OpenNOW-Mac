import Foundation

/// Tells a Guide/Steam button *tap* apart from the three roles the same bit already holds on a
/// Steam Controller: the Steam+X on-screen-keyboard chord, the hold-and-right-pad local cursor
/// modifier, and half of the Steam+Y power-off combo.
///
/// The rule is edge- and history-based rather than timed: a tap is the release of a hold during
/// which no other button was pressed and no right-pad motion was produced. That keeps every
/// existing role intact — a chord partner or a moving right pad disqualifies the hold — and it
/// needs no timer, so it cannot misfire on a slow tap.
///
/// Pure state machine over `ControllerInputSnapshot`, so it belongs to the model layer and is
/// testable without a controller.
public struct SteamGuideTapTracker: Sendable {
    /// Matches `SteamControllerLocalCursorInjector`'s own dead zone, so "motion was injected" is
    /// exactly the set of samples that moved the real cursor.
    public static let padDeadzone: Float = 0.002

    struct DeviceState: Sendable {
        var held = false
        var disqualified = false
        var lastPadX: Float = 0
        var lastPadY: Float = 0
        var lastPadTouched = false
    }

    var devices: [InputDeviceID: DeviceState] = [:]

    public init() {}

    public mutating func reset() {
        devices.removeAll()
    }

    public mutating func removeDevice(_ deviceID: InputDeviceID) {
        devices.removeValue(forKey: deviceID)
    }

    /// Returns true on the release edge of a qualifying tap. Must see every report for a device,
    /// including the ones the on-screen keyboard captures, or the hold history goes stale.
    public mutating func process(snapshot: ControllerInputSnapshot, deviceID: InputDeviceID) -> Bool {
        var state = devices[deviceID] ?? DeviceState()
        defer { devices[deviceID] = state }

        let guide = snapshot.buttons.contains(.mode)
        guard state.held else {
            if guide {
                state.held = true
                state.disqualified = false
                state.lastPadX = snapshot.rightPad.x
                state.lastPadY = snapshot.rightPad.y
                state.lastPadTouched = snapshot.rightPad.touched
            }
            return false
        }

        guard guide else {
            let wasTap = !state.disqualified
            state.held = false
            state.disqualified = false
            state.lastPadTouched = false
            return wasTap
        }

        if !snapshot.buttons.subtracting(.mode).isEmpty { state.disqualified = true }
        if snapshot.rightPad.pressed { state.disqualified = true }
        // The injector establishes its origin on the first touched frame and moves nothing, so only
        // a delta from a *previous* touched frame counts as injected motion.
        if snapshot.rightPad.touched, state.lastPadTouched,
           abs(snapshot.rightPad.x - state.lastPadX) > Self.padDeadzone
            || abs(snapshot.rightPad.y - state.lastPadY) > Self.padDeadzone {
            state.disqualified = true
        }
        state.lastPadX = snapshot.rightPad.x
        state.lastPadY = snapshot.rightPad.y
        state.lastPadTouched = snapshot.rightPad.touched
        return false
    }
}
