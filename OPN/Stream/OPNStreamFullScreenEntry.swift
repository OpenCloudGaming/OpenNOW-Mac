//  What a session-ready request to enter native full screen should do before it is issued.
//
//  macOS only offers Game Mode to a game that is already in native full screen and frontmost, so
//  the stream enters full screen on every connect - the decision must not depend on a preference.
//  The window is not always mutable when the seat reports ready: it may not be in a hierarchy yet,
//  AppKit may be inside a nested run loop, or the user may be dragging an edge. This type is the
//  pure predicate behind the retry loop, so the whole matrix is assertable without a window server.
//

import Foundation

enum OPNStreamFullScreenEntry {
    /// What the driver does on one attempt.
    enum Attempt: Equatable {
        case enter
        case alreadyFullScreen
        case stop
        case wait(reason: DeferralReason)
    }

    /// Why one attempt did not issue the transition. The driver reports the last one it saw.
    enum DeferralReason: String, Equatable, Sendable {
        case windowUnreachable
        case transitionInFlight
        case geometryDeferred
    }

    /// The `reason` attribute of `nvst.ui.fullscreen.sessionReady.failed`.
    enum FailureReason: String, Equatable, Sendable {
        case windowUnreachable
        case transitionInFlight
        case geometryDeferred
        case attemptLimitReached

        init(deferral: DeferralReason?) {
            switch deferral {
            case .windowUnreachable: self = .windowUnreachable
            case .transitionInFlight: self = .transitionInFlight
            case .geometryDeferred: self = .geometryDeferred
            case nil: self = .attemptLimitReached
            }
        }
    }

    /// `isLive` is the session still wanted: connected and neither ending nor ended. A dead session
    /// stops the retry loop without a failure event, because nothing was asked of the window.
    ///
    /// Ordering mirrors the conditions AppKit imposes: the window has to exist before it can be
    /// inspected, a transition already running refuses a second style-mask change, and a nested run
    /// loop or live resize has to end before the mask can change at all.
    static func attempt(
        isLive: Bool,
        hasWindow: Bool,
        isFullScreenTransitioning: Bool,
        windowIsFullScreen: Bool,
        geometryDeferred: Bool
    ) -> Attempt {
        guard isLive else { return .stop }
        guard hasWindow else { return .wait(reason: .windowUnreachable) }
        guard !isFullScreenTransitioning else { return .wait(reason: .transitionInFlight) }
        guard !geometryDeferred else { return .wait(reason: .geometryDeferred) }
        guard !windowIsFullScreen else { return .alreadyFullScreen }
        return .enter
    }
}
