import Dispatch
import Foundation

/// The `Turn Camera 360°` test action: exactly `pixelsPer360` worth of camera movement, emitted
/// into the live session so a user can rotate the controller one physical turn and see whether the
/// client's idea of a full turn matches the game's.
///
/// Two constraints shape the shape of the emission, and both come from the transport rather than
/// from taste:
///
/// - **It is split into bounded steps.** The mouse channel is partially reliable with a small
///   backlog, so a full turn sent as one event is a turn the seat can drop. The largest supported
///   calibration is 32 000 counts, which is one `Int16` but far past what a single packet should
///   carry.
/// - **It is paced across frames.** A single jump is useless as a measurement — the user has to
///   watch the camera travel and compare it against where the physical rotation left the view, and
///   a one-frame teleport reads as a glitch rather than as a turn.
///
/// The action holds nothing: it emits relative moves only, and a relative move has no button state
/// to leave stuck. Nothing here can strand a key, a button or an axis.
public enum GyroCalibrationTurn {
    /// The most one event carries. Small enough that a full turn is a bounded number of events the
    /// channel absorbs, large enough that the smallest calibration (100 counts per 360°) is still a
    /// single step.
    public static let maximumStepPixels: Float = 400

    /// Pacing between steps: one frame at 60 Hz, so the channel drains as fast as the turn fills it.
    public static let stepInterval: Duration = .milliseconds(16)

    /// One camera turn in whole-pixel steps, forward or backward, summing to exactly `pixelsPer360`.
    ///
    /// Exactness is the point, not a nicety. The acceptance test for this action is that repeating
    /// it returns the view to where it started, so a partition that drops its remainder leaves a
    /// small permanent offset that compounds with every repetition.
    ///
    /// The turn is clamped to the wire's range — one step is a signed 16-bit count — and a
    /// non-positive calibration emits nothing rather than an empty or reversed turn.
    public static func steps(pixelsPer360: Float, forward: Bool) -> [Int16] {
        let whole = Int(max(0, min(pixelsPer360, Float(Int(Int16.max)))).rounded())
        guard whole > 0 else { return [] }

        let limit = Int(maximumStepPixels)
        let count = (whole + limit - 1) / limit
        let base = whole / count
        let remainder = whole % count
        let sign: Int16 = forward ? 1 : -1

        return (0 ..< count).map { index in
            // The remainder is spread one pixel at a time over the leading steps, which keeps the
            // sum exact without letting any single step exceed the limit.
            sign * Int16(base + (index < remainder ? 1 : 0))
        }
    }

    /// Emits the turn into the live session, one step per `interval`.
    ///
    /// Returns how many steps the session accepted, so a caller can tell a completed turn from one
    /// cut short by a stream that ended mid-turn. `send` is the caller's route into the stream —
    /// in the app, `StreamSessionLifecycle.sendSyntheticInput` — which keeps this type free of any
    /// knowledge of transports.
    @MainActor
    public static func emit(pixelsPer360: Float,
                            forward: Bool,
                            interval: Duration = stepInterval,
                            send: (UserInputEvent) -> Bool) async -> Int {
        var accepted = 0
        for (index, step) in steps(pixelsPer360: pixelsPer360, forward: forward).enumerated() {
            if index > 0, interval > .zero {
                try? await Task.sleep(for: interval)
            }
            guard send(.relativeMouseMove(deltaX: step, deltaY: 0)) else { return accepted }
            accepted += 1
        }
        return accepted
    }

    /// Whether a turn of this size was delivered whole, for the wizard's own reporting.
    public static func stepCount(pixelsPer360: Float) -> Int {
        steps(pixelsPer360: pixelsPer360, forward: true).count
    }
}
