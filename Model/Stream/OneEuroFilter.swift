import Foundation

/// The 1-euro filter: a low-pass whose cutoff rises with the signal's own speed, so slow motion
/// is smoothed hard and fast motion is not delayed. This is the filter Steam credits with
/// "smoothed low level gyro noise without adding delay", and the reason a plain moving average
/// is not used here — a moving average spends latency on exactly the fast flicks that must not
/// be late.
///
/// Shared by the gyro pipeline and the trackpad pointer translators. The filter is unit-agnostic;
/// `beta` is what has to be matched to the signal's units, so a caller filtering pad *positions*
/// (pad units) passes a larger `beta` than one filtering gyro *rates* (degrees per second).
struct OneEuroFilter: Sendable {
    /// Cutoff at zero signal speed, in Hz.
    var minCutoff: Float
    /// How far the cutoff rises per unit of signal speed, in Hz per (unit / second).
    var beta: Float
    /// Cutoff of the speed estimate itself, in Hz. Lower values average out a fast tremor into a
    /// near-zero speed (so the cutoff stays low and the tremor is smoothed), at the cost of a
    /// slower response when real motion starts.
    var derivativeCutoff: Float

    private var filtered: Float?
    private var filteredDerivative: Float = 0

    init(minCutoff: Float, beta: Float = 0.02, derivativeCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
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
