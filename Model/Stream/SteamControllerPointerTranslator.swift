import Foundation

public struct SteamControllerPointerActions: Equatable, Sendable {
    public var moveDeltaX: Int16 = 0
    public var moveDeltaY: Int16 = 0
    public var wheelDelta: Int16 = 0

    public init() {}

    public var isEmpty: Bool {
        moveDeltaX == 0 && moveDeltaY == 0 && wheelDelta == 0
    }
}

private func clampedInt16(_ value: Float) -> Int16 {
    Int16(max(Float(Int16.min), min(Float(Int16.max), value)))
}

/// Converts one trackpad's touch-relative motion into mouse-move or scroll-wheel deltas.
/// Ported from the pre-remap `SteamControllerTrackpadMouseTranslator`, generalized to run
/// per-pad so each trackpad can pick its own behavior and sensitivity independently.
public struct SteamControllerPadPointerTranslator: Sendable {
    public static let basePointsPerPadUnit: Float = 700
    public static let baseWheelUnitsPerPadUnit: Float = 300

    private var previous = SteamControllerTrackpadState()
    private var moveRemainderX: Float = 0
    private var moveRemainderY: Float = 0
    private var wheelRemainder: Float = 0

    public init() {}

    public mutating func translate(_ pad: SteamControllerTrackpadState, settings: SteamControllerPadSettings) -> SteamControllerPointerActions {
        defer { previous = pad }
        var actions = SteamControllerPointerActions()
        guard pad.touched else {
            moveRemainderX = 0
            moveRemainderY = 0
            wheelRemainder = 0
            return actions
        }
        guard previous.touched else { return actions } // first frame of a touch just establishes the anchor

        switch settings.mode {
        case .mouse:
            let scaledX = (pad.x - previous.x) * Self.basePointsPerPadUnit * settings.sensitivity + moveRemainderX
            let ySign: Float = settings.invertY ? 1 : -1
            let scaledY = (pad.y - previous.y) * Self.basePointsPerPadUnit * settings.sensitivity * ySign + moveRemainderY
            let wholeX = scaledX.rounded(.towardZero)
            let wholeY = scaledY.rounded(.towardZero)
            moveRemainderX = scaledX - wholeX
            moveRemainderY = scaledY - wholeY
            actions.moveDeltaX = clampedInt16(wholeX)
            actions.moveDeltaY = clampedInt16(wholeY)
        case .scrollWheel:
            let ySign: Float = settings.invertY ? -1 : 1
            let scaledWheel = (pad.y - previous.y) * Self.baseWheelUnitsPerPadUnit * settings.sensitivity * ySign + wheelRemainder
            let wholeWheel = scaledWheel.rounded(.towardZero)
            wheelRemainder = scaledWheel - wholeWheel
            actions.wheelDelta = clampedInt16(wholeWheel)
        case .joystickPassthrough, .disabled:
            break
        }
        return actions
    }
}

/// Converts a stick's absolute deflection into a continuous mouse-move or scroll-wheel
/// velocity command, applied once per input report (the stick springs back to center on
/// release, so there's no touch-relative delta to read — unlike a trackpad).
public struct SteamControllerStickPointerTranslator: Sendable {
    public static let baseMouseUnitsPerTick: Float = 14
    public static let baseWheelUnitsPerTick: Float = 6
    private static let deadzone: Float = 0.12

    private var moveRemainderX: Float = 0
    private var moveRemainderY: Float = 0
    private var wheelRemainder: Float = 0

    public init() {}

    public mutating func translate(x: Float, y: Float, settings: SteamControllerPadSettings) -> SteamControllerPointerActions {
        var actions = SteamControllerPointerActions()
        guard sqrt(x * x + y * y) > Self.deadzone else {
            moveRemainderX = 0
            moveRemainderY = 0
            wheelRemainder = 0
            return actions
        }

        switch settings.mode {
        case .mouse:
            let scaledX = x * Self.baseMouseUnitsPerTick * settings.sensitivity + moveRemainderX
            let ySign: Float = settings.invertY ? 1 : -1
            let scaledY = y * Self.baseMouseUnitsPerTick * settings.sensitivity * ySign + moveRemainderY
            let wholeX = scaledX.rounded(.towardZero)
            let wholeY = scaledY.rounded(.towardZero)
            moveRemainderX = scaledX - wholeX
            moveRemainderY = scaledY - wholeY
            actions.moveDeltaX = clampedInt16(wholeX)
            actions.moveDeltaY = clampedInt16(wholeY)
        case .scrollWheel:
            let ySign: Float = settings.invertY ? -1 : 1
            let scaledWheel = y * Self.baseWheelUnitsPerTick * settings.sensitivity * ySign + wheelRemainder
            let wholeWheel = scaledWheel.rounded(.towardZero)
            wheelRemainder = scaledWheel - wholeWheel
            actions.wheelDelta = clampedInt16(wholeWheel)
        case .joystickPassthrough, .disabled:
            break
        }
        return actions
    }
}
