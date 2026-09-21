import Foundation

/// One calibration pass in the gyro editor: capture the zero-rate offset, or measure the turn rate.
///
/// Both passes exist because the editor previously offered controls for a capture flow that had never
/// been implemented — a Recalibrate button that zeroed an already-zero stored value, and a manual
/// mode whose documented "explicit recalibrate action" did not exist. This is that flow: it reads the
/// live IMU, drives the estimator the runtime itself uses, and produces a value the profile can store.
///
/// It reuses rather than reimplements. The offset comes from `GyroProcessor.captureBias`, the same
/// estimator that adapts during a stream, so a value captured here means the same thing as one the
/// runtime learns; the turn rate comes from `GyroTurnRateCapture` fed by `GyroProcessor.shapedRates`,
/// the same shaping the stick receives.
public struct GyroCalibrationSession: Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Hold the pad still; store the sensor's zero-rate offset in the profile.
        case zeroRateOffset
        /// Turn the pad as you would swing the camera; store the rate as Maximum Turn Rate.
        case turnRate
    }

    public enum Outcome: Equatable, Sendable {
        case none
        case measuredOffset(x: Float, y: Float, z: Float)
        /// The pad moved during the offset capture, so what was measured is the user's hands, not the
        /// sensor. The stored offset is untouched and the pass can be run again.
        case movedDuringCapture
        /// The controller reports no motion at all — a pad with no IMU, or motion reporting off.
        case noMotionData
        case turnRateRecommended(Float)
        case noTurnDetected
    }

    /// How long the offset capture runs. The estimator converges with a 1.5 s time constant, so three
    /// seconds is about 86 % of the way to a stationary offset: enough for a stored seed, and short
    /// enough that a user will hold still for it.
    public static let offsetCaptureDuration: Float = 3

    /// Movement above this voids an offset capture. Twice the "held still" rate the estimator itself
    /// uses, so a capture cannot be voided by the same jitter the estimator would have accepted.
    public static let movementVoidRate: Float = GyroProcessor.autoBiasStillRate * 2

    public private(set) var kind: Kind?
    public private(set) var result: Outcome = .none
    /// Seconds of the current pass, advanced by the caller's sampling cadence — not by the arrival of
    /// motion, so a controller that reports nothing still reaches the end of a capture and says so.
    public private(set) var elapsed: Float = 0
    public private(set) var sawMotion = false
    public private(set) var movedWhileCapturing = false

    private var estimator = GyroProcessor()
    private var turnRate = GyroTurnRateCapture()

    public init() {}

    public var isRunning: Bool { kind != nil }

    /// 0...1 for the current pass, for a progress readout.
    public var progress: Float {
        switch kind {
        case .zeroRateOffset:
            min(1, elapsed / Self.offsetCaptureDuration)
        case .turnRate:
            turnRate.rotationProgress
        case nil:
            result == .none ? 0 : 1
        }
    }

    /// The rate measured so far while a turn-rate pass runs, for a live readout. Zero until the pad
    /// has been turned enough to mean anything.
    public var liveTurnRate: Float {
        turnRate.peakSustainedRate
    }

    /// The running verdict, so the wizard can tell "keep turning" from "turn faster" while the pass
    /// is still running instead of waiting for it to finish and then explaining the failure.
    public var liveTurnRateVerdict: GyroTurnRateVerdict? {
        kind == .turnRate ? turnRate.verdict : nil
    }

    public mutating func start(_ kind: Kind) {
        self.kind = kind
        result = .none
        elapsed = 0
        sawMotion = false
        movedWhileCapturing = false
        estimator = GyroProcessor()
        turnRate = GyroTurnRateCapture()
    }

    public mutating func cancel() {
        kind = nil
        result = .none
        elapsed = 0
        sawMotion = false
        movedWhileCapturing = false
        estimator = GyroProcessor()
        turnRate = GyroTurnRateCapture()
    }

    /// Folds one poll of the live controller into the running pass.
    ///
    /// `deltaTime` is the caller's sampling cadence. A `nil` sample is a controller with no motion
    /// data, which is a reportable outcome rather than a reason to stall at zero progress.
    public mutating func ingest(_ sample: ControllerMotionSample?,
                                settings: ControllerGyroSettings,
                                deltaTime: Float) {
        guard let kind else { return }
        let step = min(max(deltaTime, 0.0001), 0.05)
        elapsed += step
        if sample != nil { sawMotion = true }

        switch kind {
        case .zeroRateOffset:
            // Completion is decided by elapsed time, deliberately ahead of whether a sample arrived:
            // a controller that reports nothing must still reach the end of the capture and say so,
            // rather than sitting at zero progress forever.
            if let sample {
                if sample.gyroMagnitude >= Self.movementVoidRate {
                    movedWhileCapturing = true
                } else if sample.gyroMagnitude < GyroProcessor.autoBiasStillRate {
                    estimator.captureBias(sample, deltaTime: step)
                }
            }
            guard elapsed >= Self.offsetCaptureDuration else { return }
            finishOffsetCapture()

        case .turnRate:
            guard let sample else { return }
            // Only joystick-camera reads this setting: `stickDeflection` divides the shaped rate by
            // it. Measuring it for any other output would recommend a number nothing consumes.
            guard settings.mode == .joystickCamera,
                  let shaped = estimator.shapedRates(sample, settings: settings, isActive: true, deltaTime: step)
            else { return }
            turnRate.add(horizontalDegreesPerSecond: shaped.horizontal, deltaTime: shaped.deltaTime)
            if case .recommend(let rate) = turnRate.verdict {
                result = .turnRateRecommended(rate)
                self.kind = nil
            }
        }
    }

    /// The profile change a measured offset applies, or the settings unchanged when there is nothing
    /// measured to apply.
    ///
    /// Manual mode is part of the result rather than a separate choice: a stored offset under
    /// automatic mode is only a seed the estimator re-learns over on the next idle moment, so
    /// "stored an offset and left it on automatic" is not a state that means anything.
    public func applyingMeasuredOffset(to settings: ControllerGyroSettings) -> ControllerGyroSettings {
        guard case .measuredOffset(let x, let y, let z) = result else { return settings }
        var updated = settings
        updated.biasX = x
        updated.biasY = y
        updated.biasZ = z
        updated.calibrationMode = .manual
        return updated
    }

    /// The profile change a measured turn rate applies, or the settings unchanged when there is
    /// nothing measured to apply.
    public func applyingMeasuredTurnRate(to settings: ControllerGyroSettings) -> ControllerGyroSettings {
        guard case .turnRateRecommended(let rate) = result else { return settings }
        var updated = settings
        updated.maxTurnRateDegreesPerSecond = rate
        return updated
    }

    private mutating func finishOffsetCapture() {
        kind = nil
        guard sawMotion else {
            result = .noMotionData
            return
        }
        guard !movedWhileCapturing else {
            result = .movedDuringCapture
            return
        }
        let bias = estimator.currentBias
        result = .measuredOffset(x: bias.x, y: bias.y, z: bias.z)
    }
}
