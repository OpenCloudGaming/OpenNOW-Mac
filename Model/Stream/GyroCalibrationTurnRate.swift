import Foundation

/// What a finished measurement says about the rate the user rotates at.
public enum GyroTurnRateVerdict: Equatable, Sendable {
    /// Not enough rotation seen yet to tell a turn from a wobble.
    case keepRotating
    /// The user moved, but never fast enough for a rotation to be the thing being measured.
    case noTurnDetected
    /// A rate to write into `maxTurnRateDegreesPerSecond`.
    case recommend(Float)
}

/// Measures how fast a user actually rotates the controller, so `maxTurnRateDegreesPerSecond`
/// stops being a number typed in blind.
///
/// This is the whole of the joystick-camera calibration, and it works on a fact about that output
/// mode rather than on a reference the game has to supply: `stickDeflection` divides the shaped
/// rotation rate by `maxTurnRateDegreesPerSecond` and clamps, so the setting *is* the rate at which
/// the virtual stick reaches full deflection. Ask the user to turn the controller the way they
/// normally swing the camera, measure the rate they achieved, and the setting has a measured value
/// instead of a guess.
///
/// It deliberately does not promise a physical angle. There is no pixels-per-360 equivalent for a
/// stick: the camera's response belongs to the game's own look sensitivity, which the client cannot
/// see and must not pretend to control. What this fixes is the client-side half — where the stick's
/// full range sits — and the in-game sensitivity stays the user's.
///
/// The rates fed in must be the ones `GyroProcessor.shapedRates` produces, so the number measured is
/// the number the stick receives.
public struct GyroTurnRateCapture: Equatable, Sendable {
    /// Rotation below this is a wobble rather than a turn, and it cannot be a calibration: the
    /// setting's own floor is the same value, so anything under it would be clamped straight back.
    public static let minimumMeaningfulRate: Float = ControllerGyroSettings.minimumMaxTurnRate

    /// A turn is judged by rotation travelled, not by time spent: 120° is enough to see a rate
    /// sustained, and below it the user is still winding up.
    public static let minimumRotationDegrees: Float = 120

    /// The sustained-rate window: five samples is about 40 ms at the controller's report rate, long
    /// enough to smooth a real turn and short enough to still catch its peak.
    public static let averagingWindow = 5

    /// The spike window, applied before the average: the median of three consecutive reports. A
    /// single bad report — and controllers do emit them — is discarded outright rather than
    /// diluted, so it cannot raise the peak at all.
    ///
    /// Two consecutive bad reports would still pass (a median of three survives a majority of one),
    /// which is stated rather than hidden: the wizard is a measurement a user watches and can retry,
    /// not a filter that has to be right about sustained corruption.
    public static let medianWindow = 3

    /// The recommendation is rounded to this, so the wizard writes a readable number.
    public static let roundingStep: Float = 10

    public private(set) var sampleCount = 0
    /// Total rotation travelled, ignoring direction, in degrees.
    public private(set) var rotationDegrees: Float = 0
    /// The fastest *sustained* rate seen. A single report cannot raise it — see `averagingWindow`.
    public private(set) var peakSustainedRate: Float = 0

    private var recentRaw: [Float] = []
    private var recentRates: [Float] = []

    public init() {}

    /// Folds one shaped sample into the measurement.
    ///
    /// `deltaTime` is the shaping step, so `rate * deltaTime` is the rotation this sample
    /// represents. Direction is discarded here: a user rotating back and forth is still
    /// demonstrating how fast they rotate.
    public mutating func add(horizontalDegreesPerSecond: Float, deltaTime: Float) {
        let rate = abs(horizontalDegreesPerSecond)
        let step = max(0, deltaTime)
        sampleCount += 1
        rotationDegrees += rate * step

        recentRaw.append(rate)
        if recentRaw.count > Self.medianWindow {
            recentRaw.removeFirst()
        }

        recentRates.append(medianOfRecentRaw)
        if recentRates.count > Self.averagingWindow {
            recentRates.removeFirst()
        }
        let sustained = recentRates.reduce(0, +) / Float(recentRates.count)
        peakSustainedRate = max(peakSustainedRate, sustained)
    }

    /// Forgets everything, for a retry without leaving the wizard.
    public mutating func reset() {
        sampleCount = 0
        rotationDegrees = 0
        peakSustainedRate = 0
        recentRaw.removeAll()
        recentRates.removeAll()
    }

    /// The middle of the last three raw reports, or the newest one while the window fills.
    private var medianOfRecentRaw: Float {
        guard recentRaw.count >= Self.medianWindow else { return recentRaw.last ?? 0 }
        return recentRaw.sorted()[Self.medianWindow / 2]
    }

    /// How far along the user is, 0...1, for the wizard's progress readout.
    public var rotationProgress: Float {
        min(1, rotationDegrees / Self.minimumRotationDegrees)
    }

    public var verdict: GyroTurnRateVerdict {
        guard sampleCount > 0, rotationDegrees >= Self.minimumRotationDegrees else { return .keepRotating }
        guard peakSustainedRate >= Self.minimumMeaningfulRate else { return .noTurnDetected }
        return .recommend(recommendedRate)
    }

    /// The measured rate, rounded to a readable step and clamped to the range the settings model
    /// accepts — so what the wizard writes back is what the profile keeps.
    public var recommendedRate: Float {
        let rounded = (peakSustainedRate / Self.roundingStep).rounded() * Self.roundingStep
        return min(max(rounded, ControllerGyroSettings.minimumMaxTurnRate),
                   ControllerGyroSettings.maximumMaxTurnRate)
    }
}
