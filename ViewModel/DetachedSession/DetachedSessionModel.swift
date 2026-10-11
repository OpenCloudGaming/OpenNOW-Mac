//  What the Detach New Session window decides, as plain values.
//
//  The window picks an account for a new stream and the controllers that stream leaves out. Which
//  accounts can be picked, and what the controller choice becomes, do not need a window or a store,
//  so they live here where a test can reach them.

import Foundation

struct DetachedAccountCandidate: Equatable, Sendable {
    let email: String
    let displayName: String
    let membershipTier: String
    let accountID: OPNAccountID?
    let hasSavedSession: Bool
}

enum DetachedAccountAvailability: Equatable, Sendable {
    case available
    case runningGame
    case signInRequired

    var isSelectable: Bool { self == .available }

    var detail: String {
        switch self {
        case .available: "Ready to stream"
        case .runningGame: "Already streaming in another window"
        case .signInRequired: "Sign in required"
        }
    }
}

struct DetachedAccountRow: Identifiable, Equatable, Sendable {
    let email: String
    let displayName: String
    let membershipTier: String
    let availability: DetachedAccountAvailability

    var id: String { email }
}

enum DetachedSessionModel {
    /// An account that already owns a game cannot start a second one, and one with no saved session
    /// has nothing to stream with, so neither is offered as a choice.
    static func rows(candidates: [DetachedAccountCandidate], ownedAccountIDs: Set<OPNAccountID>) -> [DetachedAccountRow] {
        candidates.map { candidate in
            DetachedAccountRow(
                email: candidate.email,
                displayName: candidate.displayName,
                membershipTier: candidate.membershipTier,
                availability: availability(of: candidate, ownedAccountIDs: ownedAccountIDs)
            )
        }
    }

    static func availability(of candidate: DetachedAccountCandidate, ownedAccountIDs: Set<OPNAccountID>) -> DetachedAccountAvailability {
        guard candidate.hasSavedSession, let accountID = candidate.accountID else { return .signInRequired }
        return ownedAccountIDs.contains(accountID) ? .runningGame : .available
    }

    /// The pads the reader switched off for the new stream become its preset, and the hand-off
    /// toggle says whether the pads it keeps are taken out of the streams already running.
    static func selection(disabled: Set<InputDeviceID>, takesPadsFromOtherStreams: Bool) -> OPNStreamControllerSelection {
        OPNStreamControllerSelection(disabled: disabled, takesPadsFromOtherStreams: takesPadsFromOtherStreams)
    }

    /// The pads a stream would keep, in the order the reader sees them.
    static func keptControllers(connected: [InputDeviceID], disabled: Set<InputDeviceID>) -> [InputDeviceID] {
        connected.filter { !disabled.contains($0) }
    }
}
