//  The full-screen entry decision is a pure predicate, so the whole matrix is assertable without a
//  window server. Each test varies one condition against the healthy baseline.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite("OPNStreamFullScreenEntry")
struct OPNStreamFullScreenEntryTests {
    private func attempt(
        isLive: Bool = true,
        isWindowReachable: Bool = true,
        isFullScreenTransitioning: Bool = false,
        isWindowFullScreen: Bool = false,
        isGeometryDeferred: Bool = false
    ) -> OPNStreamFullScreenEntry.Attempt {
        OPNStreamFullScreenEntry.attempt(
            isLive: isLive,
            isWindowReachable: isWindowReachable,
            isFullScreenTransitioning: isFullScreenTransitioning,
            isWindowFullScreen: isWindowFullScreen,
            isGeometryDeferred: isGeometryDeferred
        )
    }

    @Test("a live session with a settled window asks for the transition")
    func settledWindowRequestsTheTransition() {
        #expect(attempt() == .enter)
    }

    @Test("a window already in full screen is left alone")
    func fullScreenWindowNeedsNoTransition() {
        #expect(attempt(isWindowFullScreen: true) == .alreadyFullScreen)
    }

    @Test("a session that has ended stops without asking anything of the window")
    func endedSessionStops() {
        #expect(attempt(isLive: false) == .stop)
        #expect(attempt(isLive: false, isWindowReachable: false, isFullScreenTransitioning: true, isGeometryDeferred: true) == .stop)
    }

    @Test("a missing window defers on the window before any other block")
    func missingWindowDefersFirst() {
        #expect(attempt(isWindowReachable: false, isFullScreenTransitioning: true, isGeometryDeferred: true) == .wait(reason: .windowUnreachable))
    }

    @Test("a transition already running defers before the geometry does")
    func runningTransitionDefersFirst() {
        #expect(attempt(isFullScreenTransitioning: true, isGeometryDeferred: true) == .wait(reason: .transitionInFlight))
    }

    @Test("a nested run loop or live resize defers even when the window is windowed")
    func busyAppKitDefers() {
        #expect(attempt(isGeometryDeferred: true) == .wait(reason: .geometryDeferred))
    }

    @Test("the failure reason names the blocking condition")
    func failureReasonNamesTheBlockingCondition() {
        #expect(OPNStreamFullScreenEntry.FailureReason(deferral: .windowUnreachable) == .windowUnreachable)
        #expect(OPNStreamFullScreenEntry.FailureReason(deferral: .transitionInFlight) == .transitionInFlight)
        #expect(OPNStreamFullScreenEntry.FailureReason(deferral: .geometryDeferred) == .geometryDeferred)
    }

    @Test("no recorded condition falls back to the attempt limit")
    func noRecordedConditionFallsBackToTheAttemptLimit() {
        #expect(OPNStreamFullScreenEntry.FailureReason(deferral: nil) == .attemptLimitReached)
    }
}
