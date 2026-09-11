import SwiftUI

extension OpenNOWStartupMetrics: Equatable {
    static func == (lhs: OpenNOWStartupMetrics, rhs: OpenNOWStartupMetrics) -> Bool {
        lhs.size == rhs.size && lhs.uiScale == rhs.uiScale
    }
}

func startupClamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
}

func startupSmoothStep(_ edge0: Double, _ edge1: Double, _ value: Double) -> Double {
    guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
    let clampedValue = startupClamp((value - edge0) / (edge1 - edge0))
    return clampedValue * clampedValue * (3 - 2 * clampedValue)
}

/// Slow out of the top edge, decelerate onto the rail.
func startupEaseInOut(_ value: Double) -> Double {
    let clamped = startupClamp(value)
    return clamped < 0.5
        ? 2 * clamped * clamped
        : 1 - pow(-2 * clamped + 2, 2) / 2
}

/// Deterministic hash for grain placement; no `Math.random` state to carry
/// between frames, so the pattern is reproducible for a given frame index.
func startupHash(_ seed: Int) -> Double {
    let value = sin(Double(seed) * 12.9898) * 43758.5453
    return value - floor(value)
}
