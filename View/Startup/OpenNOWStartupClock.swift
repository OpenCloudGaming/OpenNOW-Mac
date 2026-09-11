import Foundation

/// Wall-clock time for the boot sequence, with the stalls taken out.
///
/// The splash plays while bootstrap saturates the main thread, so timeline ticks
/// arrive in bursts: a 300ms gap, then one tick carrying 300ms of progress. Keying
/// the choreography straight off `Date()` turns that into the freeze-then-teleport
/// the screen is meant to hide. This advances by a capped step instead and pays the
/// stall debt back over the following frames, so motion stays continuous and still
/// converges on real time before the dismissal fires.
@MainActor
final class OpenNOWStartupClock {
    /// One dropped frame at 60Hz still reads as motion; past that the step is a visible jump.
    private static let maximumStep: TimeInterval = 1.0 / 30.0
    /// Catch-up speed after a stall. Above ~1.6x the recovery itself reads as a lurch.
    private static let catchUpRate: Double = 1.6
    /// Hard ceiling on how far behind real time the animation may drift.
    private static let maximumLag: TimeInterval = 0.35

    private var lastTick: Date?
    private var realElapsed: TimeInterval = 0
    private var smoothedElapsed: TimeInterval = 0

    /// Idempotent for a repeated date, so a body evaluated twice for one tick does not double-step.
    func advance(to date: Date) -> TimeInterval {
        guard let lastTick else {
            self.lastTick = date
            return smoothedElapsed
        }
        let delta = max(date.timeIntervalSince(lastTick), 0)
        guard delta > 0 else { return smoothedElapsed }
        self.lastTick = date

        realElapsed += delta
        let step = min(delta, Self.maximumStep)
        let debt = realElapsed - smoothedElapsed - step
        let recovery = max(min(debt, step * (Self.catchUpRate - 1)), 0)
        smoothedElapsed = min(smoothedElapsed + step + recovery, realElapsed)
        smoothedElapsed = max(smoothedElapsed, realElapsed - Self.maximumLag)
        return smoothedElapsed
    }
}
