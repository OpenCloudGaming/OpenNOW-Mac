//  Instruments-visible marks for the launch splash, plus one timed summary at dismissal.
//
//  The splash holds for content when a session is restored, and which query ended the hold - or that
//  it timed out - was invisible: the wait was tuned from a fixed constant instead of measurement.
//  Each mark is a signpost on the "Startup" category, and dismissal logs the whole timeline so the
//  hold can be attributed and the tuning checked against real launches.

import Foundation
import os

@MainActor
enum OPNStartupTrace {
    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.interlaced-pixel.OpenNOW",
        category: "Startup"
    )

    private static var contentInterval: OSSignpostIntervalState?
    private static var launchedAt: ContinuousClock.Instant?
    private static var animationCompletedAt: ContinuousClock.Instant?
    private static var holdStartedAt: ContinuousClock.Instant?
    private static var contentReadyAt: ContinuousClock.Instant?
    private static var gate: StartupContentGate?

    static func recordLaunch() {
        guard launchedAt == nil else { return }
        launchedAt = ContinuousClock.now
        contentInterval = signposter.beginInterval("StartupToContent")
        OPNLog.info(.app, "Startup splash shown")
    }

    static func recordAnimationComplete(duration: TimeInterval) {
        guard animationCompletedAt == nil else { return }
        animationCompletedAt = ContinuousClock.now
        OPNLog.info(.app, "Startup animation complete duration=\(Int((duration * 1000).rounded()))ms")
    }

    static func recordHoldStarted() {
        guard holdStartedAt == nil else { return }
        holdStartedAt = ContinuousClock.now
        OPNLog.info(.catalog, "Startup hold for catalog began")
    }

    static func recordContentReady(gate: StartupContentGate) {
        guard contentReadyAt == nil else { return }
        contentReadyAt = ContinuousClock.now
        self.gate = gate
        if let contentInterval {
            signposter.endInterval("StartupToContent", contentInterval)
            self.contentInterval = nil
        }
        OPNLog.info(.catalog, "Startup content ready gate=\(gate.rawValue) hold=\(milliseconds(from: holdStartedAt, to: contentReadyAt))ms")
    }

    /// The hold gave up without content. Recorded so a launch that timed out is distinguishable from
    /// one whose content simply arrived late.
    static func recordHoldEnded(reason: String) {
        OPNLog.warning(.catalog, "Startup hold ended without content reason=\(reason) hold=\(milliseconds(from: holdStartedAt, to: ContinuousClock.now))ms")
    }

    static func recordDismissed() {
        OPNLog.info(.app, "Startup splash dismissed gate=\(gate?.rawValue ?? "timeout") launchToAnimation=\(milliseconds(from: launchedAt, to: animationCompletedAt))ms launchToContent=\(milliseconds(from: launchedAt, to: contentReadyAt))ms launchToDismiss=\(milliseconds(from: launchedAt, to: ContinuousClock.now))ms")
    }

    private static func milliseconds(from start: ContinuousClock.Instant?, to end: ContinuousClock.Instant?) -> Int {
        guard let start, let end else { return -1 }
        let components = (end - start).components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return Int((seconds * 1000).rounded())
    }
}
