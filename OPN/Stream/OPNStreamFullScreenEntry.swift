//  What a session-ready request to enter native full screen should do before it is issued.
//
//  The window is not always mutable when the seat reports ready: it may not be in a hierarchy yet,
//  AppKit may be inside a nested run loop, or the user may be dragging an edge. The predicate is
//  pure, so the whole matrix is assertable without a window server.
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

    /// Why one attempt did not issue the transition.
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

    /// A dead session stops the loop without a failure event, because nothing was asked of the
    /// window. AppKit refuses a second style-mask change mid-transition, and needs the nested loop or
    /// live resize over before the mask can change at all.
    static func attempt(
        isLive: Bool,
        isWindowReachable: Bool,
        isFullScreenTransitioning: Bool,
        isWindowFullScreen: Bool,
        isGeometryDeferred: Bool
    ) -> Attempt {
        guard isLive else { return .stop }
        guard isWindowReachable else { return .wait(reason: .windowUnreachable) }
        guard !isFullScreenTransitioning else { return .wait(reason: .transitionInFlight) }
        guard !isGeometryDeferred else { return .wait(reason: .geometryDeferred) }
        guard !isWindowFullScreen else { return .alreadyFullScreen }
        return .enter
    }
}
