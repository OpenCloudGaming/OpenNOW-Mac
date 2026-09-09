import SwiftUI

/// Every derived value the layers need, computed once per frame so no subview
/// re-derives an easing curve the others already paid for.
struct OpenNOWStartupStage {
    let progress: Double
    let elapsed: TimeInterval
    let duration: TimeInterval
    let reduceMotion: Bool

    /// Grid, vignette and frame marks arrive first so the beam has a stage to fall through.
    var ignite: Double { startupSmoothStep(0.00, 0.18, progress) }
    /// Primary beam travel, top edge to rail.
    var sweep: Double { reduceMotion ? 1 : startupEaseInOut(startupSmoothStep(0.04, 0.60, progress)) }
    /// Fast priming pass that crosses the whole screen before the real sweep.
    var preSweep: Double { reduceMotion ? 1 : startupSmoothStep(0.00, 0.13, progress) }
    /// Chromatic split on the logo, collapsing to a clean register.
    var chroma: Double { reduceMotion ? 0 : 1 - startupSmoothStep(0.08, 0.54, progress) }
    var wordmark: Double { startupSmoothStep(0.30, 0.62, progress) }
    var telemetry: Double { startupSmoothStep(0.16, 0.34, progress) }
    var rail: Double { startupSmoothStep(0.46, 0.98, progress) }
    /// Single confirmation pulse once the client is up.
    var bloom: Double { startupSmoothStep(0.84, 1.00, progress) }
    var frameMarks: Double { startupSmoothStep(0.06, 0.26, progress) }
    /// Tracks the lockup reveal so the core bloom lights with the logo, not before it.
    var develop: Double { reduceMotion ? startupSmoothStep(0.05, 0.45, progress) : startupSmoothStep(0.18, 0.60, progress) }

    var frameIndex: Int { Int(elapsed * 60) }
    var drift: Double { reduceMotion ? 0 : elapsed.truncatingRemainder(dividingBy: 2.6) / 2.6 }

    var statusText: String {
        if progress < 0.20 { return "IGNITING CORE" }
        if progress < 0.44 { return "ATTACHING SERVICES" }
        if progress < 0.68 { return "INDEXING CATALOG" }
        if progress < 0.90 { return "ARMING STREAM SURFACE" }
        return "READY"
    }
}

struct OpenNOWStartupMetrics {
    let size: CGSize
    let uiScale: CGFloat

    var compact: Bool { min(size.width, size.height) < 620 }

    var bandWidth: CGFloat { (compact ? 208 : 296) * uiScale }
    /// logo-isolated.svg ships at 680x410.
    var logoHeight: CGFloat { bandWidth * (410.0 / 680.0) }
    var bandHeight: CGFloat { logoHeight + (compact ? 74 : 96) * uiScale }
    /// The lockup is wider than the logo so the wordmark never clips its mask.
    var lockupWidth: CGFloat { bandWidth * 2.1 }
    var bandCenterY: CGFloat { size.height * 0.43 }
    var bandTop: CGFloat { bandCenterY - bandHeight / 2 }

    var inset: CGFloat { (compact ? 22 : 40) * uiScale }
    var railY: CGFloat { size.height - (compact ? 46 : 68) * uiScale }
    var railWidth: CGFloat { min(size.width - inset * 2, (compact ? 420 : 760) * uiScale) }
    var railCells: Int { compact ? 22 : 38 }

    /// Absolute y of the falling beam for a given sweep value.
    func beamY(_ sweep: Double) -> CGFloat {
        let start = -size.height * 0.06
        return start + (railY - start) * CGFloat(sweep)
    }

    /// How much of the logo band the beam has already developed, 0...1.
    func revealFraction(beamY: CGFloat) -> Double {
        guard bandHeight > 0 else { return 1 }
        return startupClamp(Double((beamY - bandTop) / bandHeight))
    }
}
