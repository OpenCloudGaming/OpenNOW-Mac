import Foundation
import simd

/// What one gyro processing step produced.
///
/// The two output families are carried together because a single profile can drive the right
/// stick while a later profile drives the mouse, and because the caller decides what the current
/// output mode means for the wire. `pointer` is only ever populated in `mouse` mode and
/// `stick*` only in the two joystick modes.
public struct GyroMotionOutput: Equatable, Sendable {
    public var pointer = ControllerPointerActions()
    public var stickX: Float = 0
    public var stickY: Float = 0
    /// Whether the gyro asked for a non-zero right-stick deflection this step. A caller that
    /// sums gyro into the forwarded stick still needs this to know whether to force a report.
    public var isStickActive = false

    public init() {}

    public var isEmpty: Bool { pointer.isEmpty && !isStickActive }

    public static let none = GyroMotionOutput()
}

/// The 1-euro filter: a low-pass whose cutoff rises with the signal's own speed, so slow motion
/// is smoothed hard and fast motion is not delayed. This is the filter Steam credits with
/// "smoothed low level gyro noise without adding delay", and the reason a plain moving average
/// is not used here — a moving average spends latency on exactly the fast flicks that must not
/// be late.
private struct OneEuroFilter: Sendable {
    /// Cutoff at zero signal speed, in Hz.
    var minCutoff: Float
    var beta: Float = 0.02
    var derivativeCutoff: Float = 1.0

    private var filtered: Float?
    private var filteredDerivative: Float = 0

    init(minCutoff: Float) {
        self.minCutoff = minCutoff
    }

    mutating func reset() {
        filtered = nil
        filteredDerivative = 0
    }

    private static func alpha(cutoff: Float, deltaTime: Float) -> Float {
        let tau = 1 / (2 * Float.pi * max(cutoff, 0.0001))
        return deltaTime / (deltaTime + tau)
    }

    mutating func filter(_ value: Float, deltaTime: Float) -> Float {
        guard let previous = filtered else {
            filtered = value
            return value
        }
        let derivative = (value - previous) / max(deltaTime, 0.0001)
        let smoothedDerivative = filteredDerivative + Self.alpha(cutoff: derivativeCutoff, deltaTime: deltaTime) * (derivative - filteredDerivative)
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let next = previous + Self.alpha(cutoff: cutoff, deltaTime: deltaTime) * (value - previous)
        filtered = next
        filteredDerivative = smoothedDerivative
        return next
    }
}

/// Turns raw angular rates into camera input.
///
/// The whole pipeline runs per inertial sample, in physical units, and is deliberately a plain
/// value type: every stage is reachable from a test with synthetic rates, and none of it needs
/// IOKit, SwiftUI, or a clock. Callers pass `deltaTime` rather than a timestamp so the same
/// sample sequence replays identically.
///
/// Bias handling is the one place this deliberately diverges from the controller's own firmware.
/// The 2026 Steam Controller auto-calibrates onboard and treats slow, steady, *intentional*
/// rotation as drift, cancelling it — the single most reported gyro complaint about the hardware,
/// and one Steam Input cannot switch off. This estimator only adapts while gyro is *inactive*,
/// so deliberate slow aim is never mistaken for drift.
/// One sample's shaped rotation rates, in degrees per second, ahead of the output mode.
///
/// Carries the clamped `deltaTime` the shaping ran with, so a caller that continues into mode
/// routing accumulates with the same step the shaping used.
public struct GyroShapedRates: Equatable, Sendable {
    public let horizontal: Float
    public let vertical: Float
    public let deltaTime: Float

    public init(horizontal: Float, vertical: Float, deltaTime: Float) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.deltaTime = deltaTime
    }
}

public struct GyroProcessor: Sendable {
    /// Counts per degree used when `useNaturalSensitivity` is off, chosen so the default
    /// sensitivity reproduces a 1440-count 360-degree turn — the common shooter default.
    public static let legacyCountsPerDegree: Float = 4.0

    /// Mouse events are released in batches at this interval. Reports arrive at up to 1 kHz and
    /// GeForce NOW's mouse channel is partially reliable with a 512-byte backlog, so per-report
    /// mouse events would flood it and delay real mouse input.
    public static let defaultFlushInterval: Float = 1.0 / 120.0

    /// Rates below this are treated as "held still" for bias estimation. Public because the
    /// calibration capture has to judge stillness by the same threshold the estimator does: a second
    /// copy of the number is how a capture and the estimator it feeds end up disagreeing about
    /// whether the pad was still.
    public static let autoBiasStillRate: Float = 4
    /// Time constant of the bias estimate, in seconds.
    private static let autoBiasTimeConstant: Float = 1.5
    /// Time constant of the gravity estimate, in seconds.
    private static let gravityTimeConstant: Float = 0.45
    /// Half-life of the momentum tail, in seconds.
    private static let momentumHalfLife: Float = 0.09
    /// How far the acceleration magnitude may stray from its running estimate before the sample
    /// is treated as a transient and ignored for gravity. Expressed as a ratio on purpose: the
    /// controller's accelerometer full-scale range is not documented, so nothing here may depend
    /// on absolute g — only on the direction, and on the magnitude being *stable*.
    private static let gravityStabilityRatio: ClosedRange<Float> = 0.4...2.5
    /// Time constant for the running acceleration magnitude, in seconds.
    private static let accelMagnitudeTimeConstant: Float = 2.0

    public let flushInterval: Float

    private var bias: SIMD3<Float> = .zero
    private var hasBias = false
    private var gravity: SIMD3<Float>?
    private var accelMagnitudeEstimate: Float?
    private var horizontalFilter = OneEuroFilter(minCutoff: 12)
    private var verticalFilter = OneEuroFilter(minCutoff: 12)
    private var lookFilter = OneEuroFilter(minCutoff: 12)
    private var momentumHorizontal: Float = 0
    private var momentumVertical: Float = 0
    private var pendingMoveX: Float = 0
    private var pendingMoveY: Float = 0
    private var timeSinceFlush: Float = 0
    private var turnDebtDegrees: Float = 0
    private var deflectionCenterHorizontal: Float = 0
    private var deflectionCenterVertical: Float = 0
    private var accumulatedYawDegrees: Float = 0
    private var accumulatedPitchDegrees: Float = 0
    private var lookAngleYawDegrees: Float = 0
    private var lookAnglePitchDegrees: Float = 0

    public init(flushInterval: Float = GyroProcessor.defaultFlushInterval) {
        self.flushInterval = flushInterval
    }

    /// Forget every derived value but keep the learned bias — a profile or device change should
    /// not force the user to recalibrate.
    public mutating func resetTransientState() {
        horizontalFilter.reset()
        verticalFilter.reset()
        lookFilter.reset()
        momentumHorizontal = 0
        momentumVertical = 0
        pendingMoveX = 0
        pendingMoveY = 0
        timeSinceFlush = 0
        turnDebtDegrees = 0
        deflectionCenterHorizontal = 0
        deflectionCenterVertical = 0
        accumulatedYawDegrees = 0
        accumulatedPitchDegrees = 0
        lookAngleYawDegrees = 0
        lookAnglePitchDegrees = 0
    }

    /// Forget the learned bias too, so the next still sample becomes the new zero.
    public mutating func resetAll() {
        resetTransientState()
        bias = .zero
        hasBias = false
        gravity = nil
        accelMagnitudeEstimate = nil
    }

    /// Seed the bias from the profile, so a saved calibration survives a relaunch.
    public mutating func applyBias(from settings: ControllerGyroSettings) {
        bias = SIMD3(settings.biasX, settings.biasY, settings.biasZ)
        hasBias = true
    }

    public var currentBias: SIMD3<Float> { bias }

    /// Fold one sample into the bias estimate. Called repeatedly while the controller is known to
    /// be still — in automatic mode whenever gyro is inactive, which is the whole procedure: hold
    /// the pad still for a second or two. Manual mode never calls this.
    public mutating func captureBias(_ sample: ControllerMotionSample, deltaTime: Float) {
        let measured = SIMD3(sample.gyroX, sample.gyroY, sample.gyroZ)
        guard hasBias else {
            bias = measured
            hasBias = true
            return
        }
        let step = min(1, deltaTime / Self.autoBiasTimeConstant)
        bias += (measured - bias) * step
    }

    /// One processing step.
    ///
    /// - Parameters:
    ///   - sample: the inertial sample, in physical units. `nil` (a pad with motion reporting
    ///     off) yields no output and does not disturb the learned bias.
    ///   - settings: the profile's gyro settings.
    ///   - isActive: whether the activation source is engaged, already debounced and latched.
    ///   - deltaTime: seconds since the previous step.
    public mutating func process(_ sample: ControllerMotionSample?,
                                 settings: ControllerGyroSettings,
                                 isActive: Bool,
                                 deltaTime: Float) -> GyroMotionOutput {
        guard let shaped = shapedRates(sample,
                                       settings: settings,
                                       isActive: isActive,
                                       deltaTime: deltaTime) else { return .none }
        return producedOutput(horizontal: shaped.horizontal,
                              vertical: shaped.vertical,
                              settings: settings,
                              deltaTime: shaped.deltaTime)
    }

    /// The shaped rotation rates one sample produces, in degrees per second, before the profile's
    /// output mode is applied.
    ///
    /// `process` is this plus mode routing and deliberately nothing more. The calibration wizard
    /// measures a user's turn rate through these exact numbers, so the rate it reads is the rate the
    /// stick receives; shaping a sample twice — once to measure, once to emit — is how a wizard ends
    /// up recommending a value its own output path disagrees with.
    ///
    /// Returns `nil` for a profile whose gyro is off and for a missing sample: the two cases that
    /// produce no output at all and reset the transient state.
    public mutating func shapedRates(_ sample: ControllerMotionSample?,
                                     settings: ControllerGyroSettings,
                                     isActive: Bool,
                                     deltaTime rawDeltaTime: Float) -> GyroShapedRates? {
        let deltaTime = min(max(rawDeltaTime, 0.0001), 0.05)
        guard settings.isEnabled else {
            resetTransientState()
            return nil
        }
        guard let sample else {
            resetTransientState()
            return nil
        }

        // The first sample is NOT taken as the bias. Doing that would read every session's first
        // report as perfectly still and would make the resume of a slow aim look like drift, which
        // is the very failure the estimator above exists to avoid. Start from whatever the profile
        // saved (zero by default) and let adaptation converge while the pad is idle.
        if !hasBias {
            applyBias(from: settings)
        }

        // Adaptation is gated on inactivity on purpose: a live gyro must never be able to talk
        // itself into believing deliberate slow movement is drift.
        if settings.calibrationMode == .automatic, !isActive, sample.gyroMagnitude < Self.autoBiasStillRate {
            captureBias(sample, deltaTime: deltaTime)
        }

        updateGravity(with: sample, deltaTime: deltaTime)

        let corrected = SIMD3(sample.gyroX, sample.gyroY, sample.gyroZ) - bias
        let (rawHorizontal, rawVertical) = Self.axes(corrected, conversion: settings.conversion, gravity: gravity)

        // A deactivated gyro must not steer anything. Its live rate is dropped here rather than
        // inside the smoother so that only the momentum tail — a deliberate, decaying echo of the
        // last live rate — can still reach the output.
        var horizontal = isActive ? Self.applySpeedZone(rawHorizontal, settings: settings) : 0
        var vertical = isActive ? Self.applySpeedZone(rawVertical, settings: settings) : 0

        horizontal = updateMomentum(current: horizontal,
                                    previous: &momentumHorizontal,
                                    factor: settings.momentumHorizontal,
                                    isActive: isActive,
                                    deltaTime: deltaTime)
        vertical = updateMomentum(current: vertical,
                                  previous: &momentumVertical,
                                  factor: settings.momentumVertical,
                                  isActive: isActive,
                                  deltaTime: deltaTime)

        horizontalFilter.minCutoff = Self.cutoff(for: settings.smoothing)
        verticalFilter.minCutoff = Self.cutoff(for: settings.smoothing)
        lookFilter.minCutoff = Self.cutoff(for: settings.smoothing)
        horizontal = horizontalFilter.filter(horizontal, deltaTime: deltaTime)
        vertical = verticalFilter.filter(vertical, deltaTime: deltaTime)

        return GyroShapedRates(horizontal: horizontal, vertical: vertical, deltaTime: deltaTime)
    }

    /// Routes the shaped rates to the mode the profile asked for.
    private mutating func producedOutput(horizontal: Float,
                                        vertical: Float,
                                        settings: ControllerGyroSettings,
                                        deltaTime: Float) -> GyroMotionOutput {
        var output = GyroMotionOutput()
        switch settings.mode {
        case .off:
            break
        case .mouse:
            output.pointer = accumulateMouse(horizontal: horizontal,
                                             vertical: vertical,
                                             settings: settings,
                                             deltaTime: deltaTime)
        case .joystickCamera:
            let deflection = Self.stickDeflection(horizontal: horizontal,
                                                  vertical: vertical,
                                                  settings: settings,
                                                  deltaTime: deltaTime,
                                                  debt: &turnDebtDegrees)
            output.stickX = deflection.x
            output.stickY = deflection.y
            output.isStickActive = deflection.active
        case .joystickDeflection:
            let deflection = updateDeflection(horizontal: horizontal,
                                              vertical: vertical,
                                              settings: settings,
                                              deltaTime: deltaTime)
            output.stickX = deflection.x
            output.stickY = deflection.y
            output.isStickActive = deflection.active
        }
        return output
    }

    // MARK: - Axis extraction

    /// Reduces the three local rates to the horizontal/vertical pair the chosen space asks for.
    private static func axes(_ rates: SIMD3<Float>,
                             conversion: GyroConversion,
                             gravity: SIMD3<Float>?) -> (horizontal: Float, vertical: Float) {
        let yaw = rates.y
        let pitch = rates.x
        let roll = rates.z
        switch conversion {
        case .yaw:
            return (yaw, pitch)
        case .roll:
            return (roll, pitch)
        case .yawRoll:
            // Valve's combined style sums the two so a pure twist keeps its full magnitude
            // instead of being halved by a blend.
            return (yaw + roll, pitch)
        case .playerSpace:
            guard let gravity else { return (yaw, pitch) }
            return (dot(rates, gravity), pitch)
        case .worldSpace:
            guard let gravity else { return (yaw, pitch) }
            let horizontal = dot(rates, gravity)
            let vertical = dot(rates, Self.gravityLevelRightAxis(gravity: gravity))
            return (horizontal, vertical)
        case .laserPointer:
            // The pointer's speed is the derivative of tan(angle): the same rotation moves a
            // cursor further the further off-axis it already is, which is what makes a laser
            // pointer feel absolute rather than rate-driven.
            return (yaw, pitch)
        }
    }

    /// The controller's local x axis projected perpendicular to gravity — the axis a level
    /// pitch rotates about, whatever the pad's roll happens to be.
    private static func gravityLevelRightAxis(gravity: SIMD3<Float>) -> SIMD3<Float> {
        let localX = SIMD3<Float>(1, 0, 0)
        let projected = localX - gravity * dot(localX, gravity)
        let projectedLength = length(projected)
        guard projectedLength > 0.0001 else { return SIMD3(0, 0, 0) }
        return projected / projectedLength
    }

    private static func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(upper, max(lower, value))
    }

    private mutating func updateGravity(with sample: ControllerMotionSample, deltaTime: Float) {
        let magnitude = sample.accelMagnitude
        guard magnitude > 0.0001 else { return }
        if let estimate = accelMagnitudeEstimate {
            let ratio = magnitude / estimate
            guard Self.gravityStabilityRatio.contains(ratio) else { return }
            let step = min(1, deltaTime / Self.accelMagnitudeTimeConstant)
            accelMagnitudeEstimate = estimate + (magnitude - estimate) * step
        } else {
            accelMagnitudeEstimate = magnitude
        }
        let measured = SIMD3(sample.accelX, sample.accelY, sample.accelZ)
        let measuredLength = length(measured)
        guard measuredLength > 0.0001 else { return }
        let unit = measured / measuredLength
        guard let current = gravity else {
            gravity = unit
            return
        }
        let step = min(1, deltaTime / Self.gravityTimeConstant)
        let blended = current + (unit - current) * step
        let blendedLength = length(blended)
        gravity = blendedLength > 0.0001 ? blended / blendedLength : unit
    }

    private static func cutoff(for smoothing: Float) -> Float {
        // 12 Hz is effectively unfiltered at these sample rates; 0.5 Hz is heavy.
        12 * pow(0.04, min(max(smoothing, 0), 1))
    }

    // MARK: - Shared shaping

    /// Speed deadzone plus precision ramp: silence below the deadzone, then a soft shoulder up to
    /// full output. A cliff here is what makes fine aim stutter, which is why the ramp exists
    /// separately from the deadzone.
    private static func applySpeedZone(_ rate: Float, settings: ControllerGyroSettings) -> Float {
        let magnitude = abs(rate)
        let deadzone = settings.speedDeadzoneDegreesPerSecond
        guard magnitude > deadzone else { return 0 }
        let ramp = settings.precisionZoneDegreesPerSecond
        guard ramp > 0 else { return rate }
        let position = min(1, (magnitude - deadzone) / ramp)
        return rate * position
    }

    private func updateMomentum(current: Float,
                                previous: inout Float,
                                factor: Float,
                                isActive: Bool,
                                deltaTime: Float) -> Float {
        // Momentum of zero means no coast at all, so nothing may be banked for later — tracking a
        // live rate with a zero factor would hand the tail a value it was told to ignore.
        guard factor > 0 else {
            previous = 0
            return current
        }
        if isActive {
            previous = current * factor
            return current
        }
        guard previous != 0 else { return current }
        // A flick released mid-turn coasts instead of stopping dead. The factor is how much of
        // the last live rate is handed to the tail; the tail itself then decays.
        let decay = pow(0.5, deltaTime / Self.momentumHalfLife)
        let tail = previous * decay
        previous = abs(tail) < 0.5 ? 0 : tail
        return current + tail
    }

    private static func applyPowerCurve(_ deflection: Float, curve: Float) -> Float {
        let magnitude = abs(deflection)
        guard magnitude > 0 else { return 0 }
        let shaped = pow(magnitude, 1 / curve)
        return deflection < 0 ? -shaped : shaped
    }

    private static func applyAntiDeadzone(_ deflection: Float, antiDeadzone: Float) -> Float {
        let magnitude = abs(deflection)
        guard magnitude > 0 else { return 0 }
        let shaped = antiDeadzone + (1 - antiDeadzone) * magnitude
        return deflection < 0 ? -shaped : shaped
    }

    // MARK: - Joystick camera

    private static func stickDeflection(horizontal: Float,
                                        vertical: Float,
                                        settings: ControllerGyroSettings,
                                        deltaTime: Float,
                                        debt: inout Float) -> (x: Float, y: Float, active: Bool) {
        let limit = settings.maxTurnRateDegreesPerSecond
        var deflection = Self.clamp(horizontal / limit, -1, 1)

        if settings.catchUp {
            let excess = horizontal - Self.clamp(horizontal, -limit, limit)
            debt += excess * deltaTime
            let capacity = 1 - abs(deflection)
            if capacity > 0, debt != 0 {
                let spent = min(abs(debt) / limit, capacity)
                let direction: Float = debt < 0 ? -1 : 1
                deflection = Self.clamp(deflection + direction * spent, -1, 1)
                debt -= direction * spent * limit * deltaTime * 60
                if abs(debt) < 0.01 { debt = 0 }
            }
        } else {
            debt = 0
        }

        var x = Self.applyAntiDeadzone(Self.applyPowerCurve(deflection, curve: settings.joystickPowerCurve),
                                       antiDeadzone: settings.antiDeadzone)
        var y = Self.applyAntiDeadzone(Self.applyPowerCurve(Self.clamp(vertical / limit, -1, 1), curve: settings.joystickPowerCurve),
                                       antiDeadzone: settings.antiDeadzone)
        x = Self.clamp(x * settings.horizontalScale * (settings.invertX ? -1 : 1), -1, 1)
        y = Self.clamp(y * settings.verticalScale * (settings.invertY ? -1 : 1), -1, 1)
        return (x, y, x != 0 || y != 0)
    }

    // MARK: - Joystick deflection

    private mutating func updateDeflection(horizontal: Float,
                                           vertical: Float,
                                           settings: ControllerGyroSettings,
                                           deltaTime: Float) -> (x: Float, y: Float, active: Bool) {
        accumulatedYawDegrees += horizontal * deltaTime
        accumulatedPitchDegrees += vertical * deltaTime
        let limit = settings.deflectionAngleDegrees

        if settings.lockExtents {
            // Winding past the end drags the neutral with it, so a wheel can be held past lock
            // instead of pinning at the stop.
            deflectionCenterHorizontal = accumulatedYawDegrees - Self.clamp(accumulatedYawDegrees, -limit, limit)
            deflectionCenterVertical = accumulatedPitchDegrees - Self.clamp(accumulatedPitchDegrees, -limit, limit)
        } else {
            deflectionCenterHorizontal = 0
            deflectionCenterVertical = 0
        }

        let x = Self.clamp((accumulatedYawDegrees - deflectionCenterHorizontal) / limit, -1, 1)
        let y = Self.clamp((accumulatedPitchDegrees - deflectionCenterVertical) / limit, -1, 1)
        var shapedX = Self.applyAntiDeadzone(Self.applyPowerCurve(x, curve: settings.joystickPowerCurve), antiDeadzone: settings.antiDeadzone)
        var shapedY = Self.applyAntiDeadzone(Self.applyPowerCurve(y, curve: settings.joystickPowerCurve), antiDeadzone: settings.antiDeadzone)
        shapedX = Self.clamp(shapedX * settings.horizontalScale * (settings.invertX ? -1 : 1), -1, 1)
        shapedY = Self.clamp(shapedY * settings.verticalScale * (settings.invertY ? -1 : 1), -1, 1)
        return (shapedX, shapedY, x != 0 || y != 0)
    }

    // MARK: - Mouse

    private mutating func accumulateMouse(horizontal: Float,
                                          vertical: Float,
                                          settings: ControllerGyroSettings,
                                          deltaTime: Float) -> ControllerPointerActions {
        let countsPerDegree: Float
        if settings.useNaturalSensitivity {
            countsPerDegree = settings.pixelsPer360 / 360
        } else {
            countsPerDegree = Self.legacyCountsPerDegree * settings.sensitivity
        }

        var scaleHorizontal = countsPerDegree * settings.horizontalScale
        var scaleVertical = countsPerDegree * settings.verticalScale
        if settings.conversion == .laserPointer {
            (scaleHorizontal, scaleVertical) = laserPointerScales(horizontal: horizontal,
                                                                  vertical: vertical,
                                                                  settings: settings,
                                                                  deltaTime: deltaTime)
        }

        pendingMoveX += horizontal * deltaTime * scaleHorizontal * (settings.invertX ? -1 : 1)
        pendingMoveY += vertical * deltaTime * scaleVertical * (settings.invertY ? -1 : 1)

        timeSinceFlush += deltaTime
        guard timeSinceFlush >= flushInterval else { return ControllerPointerActions() }
        timeSinceFlush = 0

        var actions = ControllerPointerActions()
        let wholeX = pendingMoveX.rounded(.towardZero)
        let wholeY = pendingMoveY.rounded(.towardZero)
        pendingMoveX -= wholeX
        pendingMoveY -= wholeY
        // Anything past the wire's range is dropped rather than wrapped: a wrapped delta would
        // fling the aim across the screen.
        actions.moveDeltaX = Self.clampInt16(wholeX)
        actions.moveDeltaY = Self.clampInt16(wholeY)
        return actions
    }

    /// Accumulates the pointing angle and returns the sec² factor that turns an angular rate into
    /// the cursor speed of a ray projected onto a plane.
    private mutating func laserPointerScales(horizontal: Float,
                                             vertical: Float,
                                             settings: ControllerGyroSettings,
                                             deltaTime: Float) -> (horizontal: Float, vertical: Float) {
        lookAngleYawDegrees += horizontal * deltaTime
        lookAnglePitchDegrees += vertical * deltaTime
        let yawRadians = lookAngleYawDegrees * .pi / 180
        let pitchRadians = lookAnglePitchDegrees * .pi / 180
        // 1/cos^2 == sec^2, and it is what differentiates tan.
        let yawScale = 1 / max(pow(cos(yawRadians), 2), 0.05)
        let pitchScale = 1 / max(pow(cos(pitchRadians), 2), 0.05)
        let countsPerDegree = settings.useNaturalSensitivity
            ? settings.pixelsPer360 / 360
            : Self.legacyCountsPerDegree * settings.sensitivity
        return (countsPerDegree * settings.horizontalScale * yawScale,
                countsPerDegree * settings.verticalScale * pitchScale)
    }

    private static func clampInt16(_ value: Float) -> Int16 {
        Int16(max(Float(Int16.min), min(Float(Int16.max), value)))
    }
}

/// Turns the physical right stick into instant heading changes — flick stick.
///
/// Flick stick is inherently a mouse feature: it works by handing the game a turn of a known
/// angular size, which only the mouse channel can express. On GeForce NOW that means it inherits
/// the mixed-input caveat described on `GyroOutputMode.mouse` — the game will flip between pad and
/// keyboard glyphs. It is therefore exposed as a right-stick behaviour the user opts into, never
/// as a default, and it never runs alongside `joystickCamera` because both own the same axis.
public struct FlickStickProcessor: Sendable {
    private var headingDegrees: Float = 0
    private var hasHeading = false

    public init() {}

    public mutating func reset() {
        headingDegrees = 0
        hasHeading = false
    }

    /// - Returns: mouse movement that realises the heading change, or nothing while the stick is
    ///   inside the activation threshold.
    public mutating func process(stickX: Float,
                                 stickY: Float,
                                 settings: ControllerGyroSettings) -> ControllerPointerActions {
        var actions = ControllerPointerActions()
        let magnitude = (stickX * stickX + stickY * stickY).squareRoot()
        guard magnitude >= settings.flickStickActivationThreshold else { return actions }

        let heading = atan2(stickX, stickY) * 180 / .pi
        guard hasHeading else {
            headingDegrees = heading
            hasHeading = true
            return actions
        }

        var delta = heading - headingDegrees
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        headingDegrees = heading
        guard delta != 0 else { return actions }

        let direction: Float = delta < 0 ? -1 : 1
        let applied: Float
        if settings.flickStickSnap {
            applied = delta
        } else {
            // Without snap the stick sweeps at a bounded rate instead of jumping to the heading.
            let maximumStep: Float = 12
            applied = direction * min(abs(delta), maximumStep)
            headingDegrees = heading - (delta - applied)
        }

        let countsPerDegree = (settings.pixelsPer360 / 360) * settings.flickStickSensitivity * settings.horizontalScale
        let counts = applied * countsPerDegree
        actions.moveDeltaX = Int16(max(Float(Int16.min), min(Float(Int16.max), counts.rounded(.towardZero))))
        return actions
    }
}
