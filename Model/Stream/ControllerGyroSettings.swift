import Foundation

/// What the gyroscope drives once it is active.
///
/// The vocabulary is Steam Input's, minus the two modes Valve has retired: "As Mouse" and
/// "As Joystick". Valve's own release notes replaced the former with `mouse` ("less prone to
/// errors") and the latter with the two `joystick*` modes, so carrying them here would mean
/// shipping two behaviours nobody should choose.
///
/// `joystickCamera` is the default on GeForce NOW. GeForce NOW normalizes every controller to
/// XInput, and a game that also sees mouse input while a pad is live flips its detected input
/// device continuously — button glyphs and HUD prompts flicker and aim assist silently drops.
/// A pure-gamepad output cannot cause that; `mouse` is available, but opt-in and labelled.
public enum GyroOutputMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case joystickCamera
    case mouse
    case joystickDeflection

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Off"
        case .joystickCamera: "Joystick Camera"
        case .mouse: "Mouse"
        case .joystickDeflection: "Joystick Deflection"
        }
    }

    public var detail: String? {
        switch self {
        case .off: nil
        case .joystickCamera: "Right stick. Never trips input-mode switching."
        case .mouse: "Best fidelity; games may flip between pad and keyboard glyphs."
        case .joystickDeflection: "Wheel or yoke: angle, not rate."
        }
    }
}

/// Steam Input's "3DOF to 2D conversion style" — which physical rotation becomes horizontal
/// camera movement when the controller is held like a gamepad.
///
/// `yaw` is Steam's "Local Space": both axes come straight off the hardware. `playerSpace` and
/// `worldSpace` derive horizontal movement from rotation about the gravity axis instead, which
/// lets the player twist their wrists over a turn without the horizon rolling — the same
/// three spaces Jibb Smart popularised for flick stick. They need the accelerometer, so a pad
/// that reports no acceleration falls back to `yaw`.
public enum GyroConversion: String, Codable, CaseIterable, Identifiable, Sendable {
    case yaw
    case roll
    case yawRoll
    case playerSpace
    case worldSpace
    case laserPointer

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .yaw: "Yaw"
        case .roll: "Roll"
        case .yawRoll: "Yaw + Roll"
        case .playerSpace: "Player Space"
        case .worldSpace: "World Space"
        case .laserPointer: "Laser Pointer"
        }
    }

    public var requiresGravity: Bool {
        self == .playerSpace || self == .worldSpace
    }

    public var detail: String? {
        switch self {
        case .yaw: "Twist only. Steam's \"Local Space\"."
        case .roll: "Steering-wheel motion only."
        case .yawRoll: "Twist and steer blended. Steam's default onramp."
        case .playerSpace: "Horizontal from rotation about gravity, vertical from local pitch."
        case .worldSpace: "Both axes from rotation about gravity. Laser-pointer feel."
        case .laserPointer: "Drives a cursor from an imagined forward ray."
        }
    }
}

/// How the activation source's state becomes gyro-active.
public enum GyroActivationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Gyro is always on. Only useful with a hard `speedDeadzone`.
    case always
    /// Active while the source is held. Steam's recommendation for ratcheting.
    case hold
    /// Each press flips between active and inactive.
    case toggle
    /// Active while the source is *not* held — Steam's "Release".
    case release

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .always: "Always On"
        case .hold: "Hold"
        case .toggle: "Toggle"
        case .release: "Release"
        }
    }
}

/// What turns the gyroscope on.
///
/// `gripSense*` is the 2026 Steam Controller's own answer to this: Valve added the capacitive
/// handle sensors explicitly so gyro users could suspend and re-grip to ratchet. It is the
/// default here for the same reason — but fingers shift, and users report dropping out of
/// capacitive range mid-aim, so every alternative is one pick away and the processor debounces
/// every source (`GyroActivationDebouncer`).
public enum GyroActivationSource: Hashable, Codable, Sendable {
    case none
    /// Any bindable control, including the four rear grip buttons and the Steam/QAM buttons.
    case control(ControllerControl)
    case gripSenseLeft
    case gripSenseRight
    case gripSenseEither
    case gripSenseBoth
    case stickTouchLeft
    case stickTouchRight
    case stickTouchEither
    case padTouchLeft
    case padTouchRight

    public var label: String {
        switch self {
        case .none: "None"
        case .control(let control): control.label
        case .gripSenseLeft: "Grip Sense L"
        case .gripSenseRight: "Grip Sense R"
        case .gripSenseEither: "Grip Sense L/R"
        case .gripSenseBoth: "Grip Sense Both"
        case .stickTouchLeft: "Stick Touch L"
        case .stickTouchRight: "Stick Touch R"
        case .stickTouchEither: "Stick Touch L/R"
        case .padTouchLeft: "Pad Touch L"
        case .padTouchRight: "Pad Touch R"
        }
    }

    /// The curated picker order. `.control` is reachable through `controlSources` instead of
    /// appearing as a bare case, because a picker entry that then needs a *second* picker is
    /// worse than listing the controls that make sense for gyro directly.
    public static let nonControlSources: [GyroActivationSource] = [
        .none,
        .gripSenseEither,
        .gripSenseLeft,
        .gripSenseRight,
        .gripSenseBoth,
        .stickTouchEither,
        .stickTouchLeft,
        .stickTouchRight,
        .padTouchLeft,
        .padTouchRight,
    ]

    /// The controls worth offering as an activation button, in Steam's own order of usefulness.
    public static let controlSources: [ControllerControl] = [
        .leftTrigger, .rightTrigger,
        .leftShoulder, .rightShoulder,
        .leftGrip, .rightGrip, .leftGrip2, .rightGrip2,
        .leftPadClick, .rightPadClick,
        .leftStickClick, .rightStickClick,
        .select, .start,
    ]
}

/// How the reported zero-rate is kept honest.
public enum GyroCalibrationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Track the bias while the controller is held still. Steam calls this auto-calibration;
    /// the same estimator is what the 2026 controller's own firmware applies too aggressively
    /// for slow deliberate motion, which is why `deadband` exists alongside it.
    case automatic
    /// Only the explicit recalibrate action updates the bias.
    case manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .automatic: "Automatic"
        case .manual: "Manual"
        }
    }
}

/// Every gyroscope setting, per mapping profile.
///
/// Values are clamped in `init`, and decoded field-by-field so a profile written by an older
/// build loads with defaults rather than failing — the same forward-compatibility contract
/// `ControllerMappingProfile` uses.
public struct ControllerGyroSettings: Equatable, Codable, Sendable {
    public static let minimumPixelsPer360: Float = 100
    public static let maximumPixelsPer360: Float = 32000

    public var mode: GyroOutputMode
    public var activationStyle: GyroActivationStyle
    public var activationSource: GyroActivationSource

    /// Multiplier applied when `useNaturalSensitivity` is off. Steam's plain sensitivity slider.
    public var sensitivity: Float
    /// Horizontal output scale. A vertical/horizontal ratio of 0.35 is the usual flick-stick pairing.
    public var verticalScale: Float
    public var horizontalScale: Float
    public var invertX: Bool
    public var invertY: Bool

    /// When on, `pixelsPer360` alone decides sensitivity and `sensitivity` is ignored, so one
    /// calibration value reproduces the same physical turn in every game that shares an in-game
    /// sensitivity. This is Steam's "Natural Sensitivity Scale".
    public var useNaturalSensitivity: Bool
    /// Screen pixels (or in-game counts) for one physical 360-degree turn. Set by the calibration
    /// wizard, not typed in by hand if the user takes the wizard.
    public var pixelsPer360: Float

    public var conversion: GyroConversion
    /// 1-euro filter strength, 0...1. Smooths sensor noise without the lag a moving average adds.
    public var smoothing: Float
    /// Rates below this (deg/s) produce no output at all. Steam's "Speed Deadzone".
    public var speedDeadzoneDegreesPerSecond: Float
    /// Width (deg/s) of the ramp from silence to full output above `speedDeadzoneDegreesPerSecond`.
    /// Steam's "Precision Zone": a soft shoulder instead of a cliff, so fine aim does not stutter.
    public var precisionZoneDegreesPerSecond: Float

    /// Fraction of the last output rate retained for a moment after deactivation, per axis.
    /// Steam's "Gyro Momentum": lets a flick coast instead of stopping dead on release.
    public var momentumHorizontal: Float
    public var momentumVertical: Float

    /// Exponent applied to joystick deflection. Above 1 enlarges small deflections, cancelling
    /// part of the game's own response curve — Steam's "Joystick Power Curve".
    public var joystickPowerCurve: Float
    /// Minimum deflection emitted for any non-zero output, to clear the game's own stick deadzone.
    /// Steam's "Minimum Joystick Output", which is implemented there as a deadzone rather than a
    /// floor; here it does what the name says.
    public var antiDeadzone: Float
    /// Deflection cap for `joystickCamera`, in deg/s of controller rotation.
    public var maxTurnRateDegreesPerSecond: Float
    /// When a turn exceeds `maxTurnRateDegreesPerSecond`, keep the excess in a queue and spend it
    /// on later frames instead of dropping it. Steam's "Catch Up".
    public var catchUp: Bool
    /// `joystickDeflection` only: rotating past the deflection limit drags the centre with it
    /// instead of saturating, so a wheel can be wound past half a turn.
    public var lockExtents: Bool
    /// Rotation (degrees) that maps to full deflection in `joystickDeflection`.
    public var deflectionAngleDegrees: Float

    /// Flick stick: how much of the physical stick angle becomes a camera turn.
    public var flickStickSensitivity: Float
    /// Flick stick: snap the camera to the stick's heading on forward push, rather than sweeping.
    public var flickStickSnap: Bool
    /// Flick stick: minimum stick deflection before a heading change is read.
    public var flickStickActivationThreshold: Float

    public var calibrationMode: GyroCalibrationMode
    /// Measured zero-rate offset per axis, in deg/s. Written by calibration, never typed.
    public var biasX: Float
    public var biasY: Float
    public var biasZ: Float

    public init(mode: GyroOutputMode = .off,
                activationStyle: GyroActivationStyle = .hold,
                activationSource: GyroActivationSource = .gripSenseEither,
                sensitivity: Float = 1.0,
                verticalScale: Float = 1.0,
                horizontalScale: Float = 1.0,
                invertX: Bool = false,
                invertY: Bool = false,
                useNaturalSensitivity: Bool = true,
                pixelsPer360: Float = 2000,
                conversion: GyroConversion = .yawRoll,
                smoothing: Float = 0.35,
                speedDeadzoneDegreesPerSecond: Float = 2.0,
                precisionZoneDegreesPerSecond: Float = 6.0,
                momentumHorizontal: Float = 0,
                momentumVertical: Float = 0,
                joystickPowerCurve: Float = 1.4,
                antiDeadzone: Float = 0.12,
                maxTurnRateDegreesPerSecond: Float = 220,
                catchUp: Bool = true,
                lockExtents: Bool = false,
                deflectionAngleDegrees: Float = 45,
                flickStickSensitivity: Float = 1.0,
                flickStickSnap: Bool = true,
                flickStickActivationThreshold: Float = 0.45,
                calibrationMode: GyroCalibrationMode = .automatic,
                biasX: Float = 0,
                biasY: Float = 0,
                biasZ: Float = 0) {
        self.mode = mode
        self.activationStyle = activationStyle
        self.activationSource = activationSource
        self.sensitivity = Self.clamp(sensitivity, 0.05, 20)
        self.verticalScale = Self.clamp(verticalScale, 0.05, 4)
        self.horizontalScale = Self.clamp(horizontalScale, 0.05, 4)
        self.invertX = invertX
        self.invertY = invertY
        self.useNaturalSensitivity = useNaturalSensitivity
        self.pixelsPer360 = Self.clamp(pixelsPer360, Self.minimumPixelsPer360, Self.maximumPixelsPer360)
        self.conversion = conversion
        self.smoothing = Self.clamp(smoothing, 0, 1)
        self.speedDeadzoneDegreesPerSecond = Self.clamp(speedDeadzoneDegreesPerSecond, 0, 90)
        self.precisionZoneDegreesPerSecond = Self.clamp(precisionZoneDegreesPerSecond, 0, 180)
        self.momentumHorizontal = Self.clamp(momentumHorizontal, 0, 1)
        self.momentumVertical = Self.clamp(momentumVertical, 0, 1)
        self.joystickPowerCurve = Self.clamp(joystickPowerCurve, 0.25, 4)
        self.antiDeadzone = Self.clamp(antiDeadzone, 0, 0.6)
        self.maxTurnRateDegreesPerSecond = Self.clamp(maxTurnRateDegreesPerSecond, 10, 2000)
        self.catchUp = catchUp
        self.lockExtents = lockExtents
        self.deflectionAngleDegrees = Self.clamp(deflectionAngleDegrees, 5, 540)
        self.flickStickSensitivity = Self.clamp(flickStickSensitivity, 0.1, 4)
        self.flickStickSnap = flickStickSnap
        self.flickStickActivationThreshold = Self.clamp(flickStickActivationThreshold, 0.1, 0.95)
        self.calibrationMode = calibrationMode
        self.biasX = biasX
        self.biasY = biasY
        self.biasZ = biasZ
    }

    public static let `default` = ControllerGyroSettings()

    public var isEnabled: Bool { mode != .off }

    /// Whether the firmware's motion reporting needs to be switched on for this profile.
    public var needsMotionReporting: Bool { isEnabled }

    /// Whether this profile wants the physical right stick forwarded. Gyro stick output is summed
    /// into the forwarded stick value, so the two share one axis.
    public var drivesRightStick: Bool { mode == .joystickCamera || mode == .joystickDeflection }

    private static func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        guard value.isFinite else { return lower }
        return min(upper, max(lower, value))
    }
}

extension ControllerGyroSettings {
    private enum CodingKeys: String, CodingKey {
        case mode, activationStyle, activationSource, activationControl
        case sensitivity, verticalScale, horizontalScale, invertX, invertY
        case useNaturalSensitivity, pixelsPer360, conversion, smoothing
        case speedDeadzoneDegreesPerSecond, precisionZoneDegreesPerSecond
        case momentumHorizontal, momentumVertical
        case joystickPowerCurve, antiDeadzone, maxTurnRateDegreesPerSecond
        case catchUp, lockExtents, deflectionAngleDegrees
        case flickStickSensitivity, flickStickSnap, flickStickActivationThreshold
        case calibrationMode, biasX, biasY, biasZ
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ControllerGyroSettings()
        let activationSource = try Self.decodeActivationSource(from: container, fallback: fallback.activationSource)
        self.init(
            mode: try container.decodeIfPresent(GyroOutputMode.self, forKey: .mode) ?? fallback.mode,
            activationStyle: try container.decodeIfPresent(GyroActivationStyle.self, forKey: .activationStyle) ?? fallback.activationStyle,
            activationSource: activationSource,
            sensitivity: try container.decodeIfPresent(Float.self, forKey: .sensitivity) ?? fallback.sensitivity,
            verticalScale: try container.decodeIfPresent(Float.self, forKey: .verticalScale) ?? fallback.verticalScale,
            horizontalScale: try container.decodeIfPresent(Float.self, forKey: .horizontalScale) ?? fallback.horizontalScale,
            invertX: try container.decodeIfPresent(Bool.self, forKey: .invertX) ?? fallback.invertX,
            invertY: try container.decodeIfPresent(Bool.self, forKey: .invertY) ?? fallback.invertY,
            useNaturalSensitivity: try container.decodeIfPresent(Bool.self, forKey: .useNaturalSensitivity) ?? fallback.useNaturalSensitivity,
            pixelsPer360: try container.decodeIfPresent(Float.self, forKey: .pixelsPer360) ?? fallback.pixelsPer360,
            conversion: try container.decodeIfPresent(GyroConversion.self, forKey: .conversion) ?? fallback.conversion,
            smoothing: try container.decodeIfPresent(Float.self, forKey: .smoothing) ?? fallback.smoothing,
            speedDeadzoneDegreesPerSecond: try container.decodeIfPresent(Float.self, forKey: .speedDeadzoneDegreesPerSecond) ?? fallback.speedDeadzoneDegreesPerSecond,
            precisionZoneDegreesPerSecond: try container.decodeIfPresent(Float.self, forKey: .precisionZoneDegreesPerSecond) ?? fallback.precisionZoneDegreesPerSecond,
            momentumHorizontal: try container.decodeIfPresent(Float.self, forKey: .momentumHorizontal) ?? fallback.momentumHorizontal,
            momentumVertical: try container.decodeIfPresent(Float.self, forKey: .momentumVertical) ?? fallback.momentumVertical,
            joystickPowerCurve: try container.decodeIfPresent(Float.self, forKey: .joystickPowerCurve) ?? fallback.joystickPowerCurve,
            antiDeadzone: try container.decodeIfPresent(Float.self, forKey: .antiDeadzone) ?? fallback.antiDeadzone,
            maxTurnRateDegreesPerSecond: try container.decodeIfPresent(Float.self, forKey: .maxTurnRateDegreesPerSecond) ?? fallback.maxTurnRateDegreesPerSecond,
            catchUp: try container.decodeIfPresent(Bool.self, forKey: .catchUp) ?? fallback.catchUp,
            lockExtents: try container.decodeIfPresent(Bool.self, forKey: .lockExtents) ?? fallback.lockExtents,
            deflectionAngleDegrees: try container.decodeIfPresent(Float.self, forKey: .deflectionAngleDegrees) ?? fallback.deflectionAngleDegrees,
            flickStickSensitivity: try container.decodeIfPresent(Float.self, forKey: .flickStickSensitivity) ?? fallback.flickStickSensitivity,
            flickStickSnap: try container.decodeIfPresent(Bool.self, forKey: .flickStickSnap) ?? fallback.flickStickSnap,
            flickStickActivationThreshold: try container.decodeIfPresent(Float.self, forKey: .flickStickActivationThreshold) ?? fallback.flickStickActivationThreshold,
            calibrationMode: try container.decodeIfPresent(GyroCalibrationMode.self, forKey: .calibrationMode) ?? fallback.calibrationMode,
            biasX: try container.decodeIfPresent(Float.self, forKey: .biasX) ?? fallback.biasX,
            biasY: try container.decodeIfPresent(Float.self, forKey: .biasY) ?? fallback.biasY,
            biasZ: try container.decodeIfPresent(Float.self, forKey: .biasZ) ?? fallback.biasZ
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(activationStyle, forKey: .activationStyle)
        try container.encode(activationSource.kindKey, forKey: .activationSource)
        if case .control(let control) = activationSource {
            try container.encode(control, forKey: .activationControl)
        }
        try container.encode(sensitivity, forKey: .sensitivity)
        try container.encode(verticalScale, forKey: .verticalScale)
        try container.encode(horizontalScale, forKey: .horizontalScale)
        try container.encode(invertX, forKey: .invertX)
        try container.encode(invertY, forKey: .invertY)
        try container.encode(useNaturalSensitivity, forKey: .useNaturalSensitivity)
        try container.encode(pixelsPer360, forKey: .pixelsPer360)
        try container.encode(conversion, forKey: .conversion)
        try container.encode(smoothing, forKey: .smoothing)
        try container.encode(speedDeadzoneDegreesPerSecond, forKey: .speedDeadzoneDegreesPerSecond)
        try container.encode(precisionZoneDegreesPerSecond, forKey: .precisionZoneDegreesPerSecond)
        try container.encode(momentumHorizontal, forKey: .momentumHorizontal)
        try container.encode(momentumVertical, forKey: .momentumVertical)
        try container.encode(joystickPowerCurve, forKey: .joystickPowerCurve)
        try container.encode(antiDeadzone, forKey: .antiDeadzone)
        try container.encode(maxTurnRateDegreesPerSecond, forKey: .maxTurnRateDegreesPerSecond)
        try container.encode(catchUp, forKey: .catchUp)
        try container.encode(lockExtents, forKey: .lockExtents)
        try container.encode(deflectionAngleDegrees, forKey: .deflectionAngleDegrees)
        try container.encode(flickStickSensitivity, forKey: .flickStickSensitivity)
        try container.encode(flickStickSnap, forKey: .flickStickSnap)
        try container.encode(flickStickActivationThreshold, forKey: .flickStickActivationThreshold)
        try container.encode(calibrationMode, forKey: .calibrationMode)
        try container.encode(biasX, forKey: .biasX)
        try container.encode(biasY, forKey: .biasY)
        try container.encode(biasZ, forKey: .biasZ)
    }

    /// `.control(...)` round-trips through a flat `activationSource` key plus an optional control,
    /// so the probe can read the source without pattern-matching the control payload.
    private static func decodeActivationSource(from container: KeyedDecodingContainer<CodingKeys>,
                                               fallback: GyroActivationSource) throws -> GyroActivationSource {
        guard let kind = try container.decodeIfPresent(String.self, forKey: .activationSource) else { return fallback }
        if kind == GyroActivationSource.controlKindKey {
            guard let control = try container.decodeIfPresent(ControllerControl.self, forKey: .activationControl) else { return fallback }
            return .control(control)
        }
        return GyroActivationSource(kindKey: kind) ?? fallback
    }
}

extension GyroActivationSource {
    static let controlKindKey = "control"

    /// A stable string per case for the wire format. The associated-control form carries its
    /// control through a sibling key, so it encodes as `"control"` here.
    var kindKey: String {
        switch self {
        case .none: "none"
        case .control: Self.controlKindKey
        case .gripSenseLeft: "gripSenseLeft"
        case .gripSenseRight: "gripSenseRight"
        case .gripSenseEither: "gripSenseEither"
        case .gripSenseBoth: "gripSenseBoth"
        case .stickTouchLeft: "stickTouchLeft"
        case .stickTouchRight: "stickTouchRight"
        case .stickTouchEither: "stickTouchEither"
        case .padTouchLeft: "padTouchLeft"
        case .padTouchRight: "padTouchRight"
        }
    }

    init?(kindKey: String) {
        switch kindKey {
        case "none": self = .none
        case "gripSenseLeft": self = .gripSenseLeft
        case "gripSenseRight": self = .gripSenseRight
        case "gripSenseEither": self = .gripSenseEither
        case "gripSenseBoth": self = .gripSenseBoth
        case "stickTouchLeft": self = .stickTouchLeft
        case "stickTouchRight": self = .stickTouchRight
        case "stickTouchEither": self = .stickTouchEither
        case "padTouchLeft": self = .padTouchLeft
        case "padTouchRight": self = .padTouchRight
        case Self.controlKindKey: return nil
        default: return nil
        }
    }
}
