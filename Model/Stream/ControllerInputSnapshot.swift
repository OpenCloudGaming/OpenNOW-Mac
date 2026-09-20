import Foundation

public struct ControllerTrackpadState: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var pressure: Float
    public var touched: Bool
    public var pressed: Bool

    public init(x: Float = 0,
                y: Float = 0,
                pressure: Float = 0,
                touched: Bool = false,
                pressed: Bool = false) {
        self.x = x
        self.y = y
        self.pressure = pressure
        self.touched = touched
        self.pressed = pressed
    }
}

public struct ControllerInputSnapshot: Equatable, Sendable {
    public var buttons: GamepadButtons
    public var leftTrigger: Float
    public var rightTrigger: Float
    public var leftStickX: Float
    public var leftStickY: Float
    public var rightStickX: Float
    public var rightStickY: Float
    public var leftPad: ControllerTrackpadState
    public var rightPad: ControllerTrackpadState
    public var touchpad: ControllerTrackpadState?
    /// Capacitive handle contact, from the 2026 controller's Grip Sense sensors. Not the rear
    /// grip buttons: these never click, which is exactly why they make a good gyro hold.
    public var leftGripSense: Bool
    public var rightGripSense: Bool
    /// Capacitive thumbstick contact.
    public var leftStickTouched: Bool
    public var rightStickTouched: Bool
    /// Inertial data, when the pad reports it and motion reporting is switched on. `nil` means
    /// "no gyro data available", which is different from "held perfectly still".
    public var motion: ControllerMotionSample?

    public init(buttons: GamepadButtons = [],
                leftTrigger: Float = 0,
                rightTrigger: Float = 0,
                leftStickX: Float = 0,
                leftStickY: Float = 0,
                rightStickX: Float = 0,
                rightStickY: Float = 0,
                leftPad: ControllerTrackpadState = ControllerTrackpadState(),
                rightPad: ControllerTrackpadState = ControllerTrackpadState(),
                touchpad: ControllerTrackpadState? = nil,
                leftGripSense: Bool = false,
                rightGripSense: Bool = false,
                leftStickTouched: Bool = false,
                rightStickTouched: Bool = false,
                motion: ControllerMotionSample? = nil) {
        self.buttons = buttons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
        self.leftPad = leftPad
        self.rightPad = rightPad
        self.touchpad = touchpad
        self.leftGripSense = leftGripSense
        self.rightGripSense = rightGripSense
        self.leftStickTouched = leftStickTouched
        self.rightStickTouched = rightStickTouched
        self.motion = motion
    }
}

