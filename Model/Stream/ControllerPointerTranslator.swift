import Foundation

public struct ControllerPointerActions: Equatable, Sendable {
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
///
/// A finger resting on a pad is never still. Physiological tremor around 10 Hz moves the reported
/// position by a fraction of a millimetre, which at `basePointsPerPadUnit` is several pixels of
/// cursor movement per report — the "cursor jumps while my finger is on the pad" the firmware's
/// own lizard-mode mouse path hides. This translation is host-side, so it has to reproduce that
/// filtering. Two stages do it:
///
/// 1. A 1-euro low-pass on the pad position, which smooths the tremor while still passing a flick
///    without delay.
/// 2. A minimum-movement threshold. Filtered displacement is measured from an anchor and held back
///    until it exceeds the threshold, so residual sub-pixel jitter emits nothing and the cursor
///    only moves once the finger really has.
public struct ControllerPadPointerTranslator: Sendable {
    public static let basePointsPerPadUnit: Float = 700
    public static let baseWheelUnitsPerPadUnit: Float = 300

    /// Cutoff of the resting low-pass, in Hz. The finger's tremor sits around 8-12 Hz, so a cutoff
    /// well below that removes it while leaving deliberate movement.
    public static let smoothingCutoff: Float = 0.8
    /// How far the cutoff rises per unit of pad speed, so a flick is not delayed by the resting
    /// filter.
    public static let smoothingSpeedFactor: Float = 1.5
    /// Cutoff of the speed estimate, in Hz. Low enough that a fast tremor averages to near-zero
    /// speed — keeping the filter strong — and high enough that real motion raises the cutoff
    /// quickly.
    public static let smoothingDerivativeCutoff: Float = 3.0
    /// Movement smaller than this many output points is held back until it accumulates past it.
    /// Small enough to be imperceptible as a step, large enough to swallow filtered tremor.
    public static let minimumMouseMovement: Float = 2
    /// The scroll wheel's equivalent of `minimumMouseMovement`, in wheel units.
    public static let minimumWheelMovement: Float = 1

    private var previous = ControllerTrackpadState()
    private var horizontalFilter = OneEuroFilter(minCutoff: smoothingCutoff,
                                                 beta: smoothingSpeedFactor,
                                                 derivativeCutoff: smoothingDerivativeCutoff)
    private var verticalFilter = OneEuroFilter(minCutoff: smoothingCutoff,
                                               beta: smoothingSpeedFactor,
                                               derivativeCutoff: smoothingDerivativeCutoff)
    /// Filtered pad position, in pad units.
    private var filteredX: Float = 0
    private var filteredY: Float = 0
    /// Filtered position at which the last movement was emitted. Displacement is measured from
    /// here, so a stationary finger's tremor cancels around the anchor instead of accumulating.
    private var anchorX: Float = 0
    private var anchorY: Float = 0

    public init() {}

    public mutating func translate(_ pad: ControllerTrackpadState,
                                   settings: ControllerPadSettings,
                                   deltaTime: Float) -> ControllerPointerActions {
        defer { previous = pad }
        var actions = ControllerPointerActions()
        guard pad.touched else {
            resetMotion()
            return actions
        }
        guard previous.touched else {
            seedMotion(pad, deltaTime: deltaTime)
            return actions
        }

        filteredX = horizontalFilter.filter(pad.x, deltaTime: deltaTime)
        filteredY = verticalFilter.filter(pad.y, deltaTime: deltaTime)

        switch settings.mode {
        case .mouse:
            let scale = Self.basePointsPerPadUnit * settings.sensitivity
            let ySign: Float = settings.invertY ? 1 : -1
            let pendingX = (filteredX - anchorX) * scale
            let pendingY = (filteredY - anchorY) * scale * ySign
            guard abs(pendingX) >= Self.minimumMouseMovement || abs(pendingY) >= Self.minimumMouseMovement else {
                return actions
            }
            let wholeX = pendingX.rounded(.towardZero)
            let wholeY = pendingY.rounded(.towardZero)
            anchorX += wholeX / scale
            anchorY += wholeY / (scale * ySign)
            actions.moveDeltaX = clampedInt16(wholeX)
            actions.moveDeltaY = clampedInt16(wholeY)
        case .scrollWheel:
            let scale = Self.baseWheelUnitsPerPadUnit * settings.sensitivity
            let ySign: Float = settings.invertY ? -1 : 1
            let pendingWheel = (filteredY - anchorY) * scale * ySign
            guard abs(pendingWheel) >= Self.minimumWheelMovement else { return actions }
            let wholeWheel = pendingWheel.rounded(.towardZero)
            anchorY += wholeWheel / (scale * ySign)
            anchorX = filteredX
            actions.wheelDelta = clampedInt16(wholeWheel)
        case .joystickPassthrough, .disabled, .flickStick:
            break
        }
        return actions
    }

    /// First frame of a touch: prime the filters and anchor so the touch itself is not motion.
    private mutating func seedMotion(_ pad: ControllerTrackpadState, deltaTime: Float) {
        horizontalFilter.reset()
        verticalFilter.reset()
        filteredX = horizontalFilter.filter(pad.x, deltaTime: deltaTime)
        filteredY = verticalFilter.filter(pad.y, deltaTime: deltaTime)
        anchorX = filteredX
        anchorY = filteredY
    }

    private mutating func resetMotion() {
        horizontalFilter.reset()
        verticalFilter.reset()
        filteredX = 0
        filteredY = 0
        anchorX = 0
        anchorY = 0
    }
}

/// Converts a stick's absolute deflection into a continuous mouse-move or scroll-wheel
/// velocity command, applied once per input report (the stick springs back to center on
/// release, so there's no touch-relative delta to read — unlike a trackpad).
public struct ControllerStickPointerTranslator: Sendable {
    public static let baseMouseUnitsPerTick: Float = 14
    public static let baseWheelUnitsPerTick: Float = 6
    private static let deadzone: Float = 0.12

    private var moveRemainderX: Float = 0
    private var moveRemainderY: Float = 0
    private var wheelRemainder: Float = 0

    public init() {}

    public mutating func translate(x: Float, y: Float, settings: ControllerPadSettings) -> ControllerPointerActions {
        var actions = ControllerPointerActions()
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
        case .joystickPassthrough, .disabled, .flickStick:
            break
        }
        return actions
    }
}
