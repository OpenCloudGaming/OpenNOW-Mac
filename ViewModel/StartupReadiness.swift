//  Lets the launch splash hold its last frame until the page behind it has something real to draw.
//
//  Dismissal used to be a plain timer. A slow session restore pushed the catalog's first layout past
//  the fade, so the splash uncovered a page that then settled - the top bar took its full height, the
//  marquee skeleton swapped for the hero - in full view. The hold that covers it is adaptive: it
//  waits while the launch is still fetching, and gives up early on a stalled one rather than hanging
//  on content that will never arrive.
//

import Combine
import Foundation

/// Which real content let the splash open. Recorded so the hold can be attributed to a query rather
/// than only timed.
enum StartupContentGate: String, Sendable {
    case hero
    case rails
    /// The splash is not holding for the catalog at all (a signed-out launch), so the animation's own
    /// end is the app's readiness.
    case notHeld
}

@MainActor
final class StartupReadiness: ObservableObject {
    static let shared = StartupReadiness()

    /// The adaptive hold. A fixed cap uncovered a slow-but-working launch mid-settle; no cap at all
    /// pinned the splash open on a fetch that had stalled. So the hold is bounded two ways: it gives
    /// up after `stallTimeout` with no progress, and never past `maximumTimeout` regardless. The
    /// stall window is wider than a fast response so a cold network's first byte is not mistaken for
    /// a stall; repeated deliveries keep resetting it, so a slow-but-moving launch can use the whole
    /// `maximumTimeout`.
    static let stallTimeout = Duration.seconds(2.5)
    static let maximumTimeout = Duration.seconds(6)

    /// Published so the splash can tell a finished animation from a finished app: the rail must not
    /// read 100% - or say READY - while dismissal is still holding for the catalog.
    @Published private(set) var isContentReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastProgressAt = ContinuousClock.now

    /// Resets the hold for a fresh launch. The singleton outlives a single process's splash, so the
    /// latched-ready flag has to be cleared before the next one could ever wait again. A launch with
    /// no session does not hold for the catalog, so it starts ready and the animation's end is its
    /// completion.
    func beginLaunch(holdsForContent: Bool) {
        lastProgressAt = ContinuousClock.now
        OPNStartupTrace.recordLaunch()
        if holdsForContent {
            isContentReady = false
        } else {
            isContentReady = true
            OPNStartupTrace.recordContentReady(gate: .notHeld)
        }
    }

    /// Called whenever a launch fetch starts or delivers, so the adaptive hold knows the work is
    /// still moving and does not give up on a slow network.
    func noteProgress() {
        lastProgressAt = ContinuousClock.now
    }

    func markContentReady(gate: StartupContentGate) {
        guard !isContentReady else { return }
        isContentReady = true
        OPNStartupTrace.recordContentReady(gate: gate)
        resumeWaiters()
    }

    /// Returns as soon as the page reports content, or when the hold decides it will not - a page
    /// that will never load (no network, an expired session, a failed fetch) must not pin the splash.
    func waitForContent() async {
        guard !isContentReady else { return }
        OPNStartupTrace.recordHoldStarted()
        let watchdog = Task { @MainActor in
            let startedAt = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                let now = ContinuousClock.now
                if now - startedAt >= Self.maximumTimeout {
                    OPNStartupTrace.recordHoldEnded(reason: "maximum")
                    resumeWaiters()
                    return
                }
                if now - lastProgressAt >= Self.stallTimeout {
                    OPNStartupTrace.recordHoldEnded(reason: "stalled")
                    resumeWaiters()
                    return
                }
            }
        }
        await withCheckedContinuation { waiters.append($0) }
        watchdog.cancel()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}
