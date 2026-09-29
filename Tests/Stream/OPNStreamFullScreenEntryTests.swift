//  The full-screen entry decision is a pure predicate so the whole matrix - a missing window, a
//  transition already running, AppKit inside a nested run loop - is assertable without a window
//  server. The driver exists only to read the live state and spend the retry budget.
//

import Foundation
import Testing
@testable import OpenNOW

@Suite("OPNStreamFullScreenEntry")
struct OPNStreamFullScreenEntryTests {
    @Test("a live session with a settled window asks for the transition")
    func settledWindowRequestsTheTransition() {
        let attempt = OPNStreamFullScreenEntry.attempt(
            isLive: true,
            hasWindow: true,
            isFullScreenTransitioning: false,
            windowIsFullScreen: false,
            geometryDeferred: false
        )
        #expect(attempt == .enter)
    }

    @Test("a window already in full screen is left alone")
    func fullScreenWindowNeedsNoTransition() {
        let attempt = OPNStreamFullScreenEntry.attempt(
            isLive: true,
            hasWindow: true,
            isFullScreenTransitioning: false,
            windowIsFullScreen: true,
            geometryDeferred: false
        )
        #expect(attempt == .alreadyFullScreen)
    }

    @Test("an ended session stops the loop without asking anything of the window")
    func deadSessionStops() {
        for isFullScreenTransitioning in [false, true] {
            let attempt = OPNStreamFullScreenEntry.attempt(
                isLive: false,
                hasWindow: true,
                isFullScreenTransitioning: isFullScreenTransitioning,
                windowIsFullScreen: false,
                geometryDeferred: true
            )
            #expect(attempt == .stop)
        }
    }

    @Test("a missing window defers on the window, even with everything else blocked")
    func missingWindowDefersFirst() {
        let attempt = OPNStreamFullScreenEntry.attempt(
            isLive: true,
            hasWindow: false,
            isFullScreenTransitioning: true,
            windowIsFullScreen: true,
            geometryDeferred: true
        )
        #expect(attempt == .wait(reason: .windowUnreachable))
    }

    @Test("a transition already running defers before the geometry does")
    func runningTransitionDefersFirst() {
        let attempt = OPNStreamFullScreenEntry.attempt(
            isLive: true,
            hasWindow: true,
            isFullScreenTransitioning: true,
            windowIsFullScreen: false,
            geometryDeferred: true
        )
        #expect(attempt == .wait(reason: .transitionInFlight))
    }

    @Test("a nested run loop or live resize defers even when the window is windowed")
    func busyAppKitDefers() {
        let attempt = OPNStreamFullScreenEntry.attempt(
            isLive: true,
            hasWindow: true,
            isFullScreenTransitioning: false,
            windowIsFullScreen: false,
            geometryDeferred: true
        )
        #expect(attempt == .wait(reason: .geometryDeferred))
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
