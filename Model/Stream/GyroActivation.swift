import Foundation

/// Which controls count as pressed for a given snapshot.
///
/// One definition shared by the binding engine and gyro activation, so a control can never be
/// "pressed" for a binding and not for the gyro hold that is bound to the same control.
public enum ControllerControlState {
    public static func active(in snapshot: ControllerInputSnapshot) -> Set<ControllerControl> {
        var active: Set<ControllerControl> = []
        for control in ControllerControl.allCases {
            if let bit = control.gamepadButton, snapshot.buttons.contains(bit) {
                active.insert(control)
            }
        }
        if snapshot.leftTrigger > ControllerBindingEngine.triggerActiveThreshold { active.insert(.leftTrigger) }
        if snapshot.rightTrigger > ControllerBindingEngine.triggerActiveThreshold { active.insert(.rightTrigger) }
        if snapshot.leftPad.pressed { active.insert(.leftPadClick) }
        if snapshot.rightPad.pressed { active.insert(.rightPadClick) }
        if snapshot.touchpad?.pressed == true { active.insert(.touchpadClick) }
        if snapshot.leftGripSense { active.insert(.leftGripSense) }
        if snapshot.rightGripSense { active.insert(.rightGripSense) }
        if snapshot.leftStickTouched { active.insert(.leftStickTouch) }
        if snapshot.rightStickTouched { active.insert(.rightStickTouch) }
        return active
    }
}

extension GyroActivationSource {
    /// Whether the source is engaged right now, before debouncing or style are applied.
    public func isEngaged(in snapshot: ControllerInputSnapshot,
                          activeControls: Set<ControllerControl>) -> Bool {
        switch self {
        case .none:
            return false
        case .control(let control):
            return activeControls.contains(control)
        case .gripSenseLeft:
            return snapshot.leftGripSense
        case .gripSenseRight:
            return snapshot.rightGripSense
        case .gripSenseEither:
            return snapshot.leftGripSense || snapshot.rightGripSense
        case .gripSenseBoth:
            return snapshot.leftGripSense && snapshot.rightGripSense
        case .stickTouchLeft:
            return snapshot.leftStickTouched
        case .stickTouchRight:
            return snapshot.rightStickTouched
        case .stickTouchEither:
            return snapshot.leftStickTouched || snapshot.rightStickTouched
        case .padTouchLeft:
            return snapshot.leftPad.touched
        case .padTouchRight:
            return snapshot.rightPad.touched
        }
    }
}

/// Debounces the activation source and latches it according to the chosen style.
///
/// The debounce is deliberately asymmetric. Engaging is immediate, because a gyro hold that lags
/// its own button feels broken. Disengaging waits out a short dropout, because capacitive handle
/// sensors flicker: users of Valve's own implementation report fingers shifting during aim and
/// cutting gyro at the worst possible moment, and this is the cheapest defence against it.
public struct GyroActivationState: Sendable {
    /// How long the source must stay released before gyro actually switches off.
    public static let releaseDelay: Float = 0.12

    public private(set) var isEngaged = false
    public private(set) var isActive = false

    private var releasedFor: Float = 0
    private var toggleOn = false

    public init() {}

    public mutating func reset() {
        isEngaged = false
        isActive = false
        releasedFor = 0
        toggleOn = false
    }

    public mutating func update(style: GyroActivationStyle,
                                source: GyroActivationSource,
                                snapshot: ControllerInputSnapshot,
                                activeControls: Set<ControllerControl>,
                                deltaTime: Float) -> Bool {
        let raw = source.isEngaged(in: snapshot, activeControls: activeControls)
        return update(style: style, raw: raw, deltaTime: deltaTime)
    }

    public mutating func update(style: GyroActivationStyle, raw: Bool, deltaTime: Float) -> Bool {
        let deltaTime = min(max(deltaTime, 0), 0.05)

        let wasEngaged = isEngaged
        if raw {
            releasedFor = 0
            isEngaged = true
        } else if isEngaged {
            releasedFor += deltaTime
            if releasedFor >= Self.releaseDelay {
                isEngaged = false
                releasedFor = 0
            }
        }

        switch style {
        case .always:
            isActive = true
        case .hold:
            isActive = isEngaged
        case .release:
            isActive = !isEngaged
        case .toggle:
            // The latch flips on the rising edge of the debounced source, not on the edge of its
            // own output — otherwise a toggle could re-flip itself while still held.
            if isEngaged, !wasEngaged { toggleOn.toggle() }
            isActive = toggleOn
        }
        return isActive
    }

    /// Force the latch open or closed — used when a profile changes under a held control, so a
    /// toggle cannot be left on with nothing to switch it off.
    public mutating func forceActive(_ active: Bool) {
        toggleOn = active
        isActive = active
    }
}
