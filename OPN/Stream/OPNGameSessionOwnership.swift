//  Who owns a game this application started.
//
//  Ownership is fixed when a launch intent is accepted and does not follow the catalog's browsing
//  selection: switching accounts changes what the catalog browses, never which account's
//  credentials, provider route and history a starting or running game belongs to. It is held here,
//  at application scope, rather than on a catalog view model - a catalog is remounted whenever the
//  selected session changes, so a per-catalog record would be dropped exactly when it is needed.
//
//  A record is released only once the local session no longer requires the owner's credentials:
//  a session stays owned through its whole life, including the teardown that stops it on the
//  vendor's side and reports the end of it.

import Foundation
import Observation

/// One game this application started, and the account whose credentials it runs on.
///
/// The local session id is the handle every later lifecycle action targets. It is deliberately not
/// the vendor's cloud session id: that does not exist until allocation has succeeded, and ownership
/// has to be frozen before the queue, allocation and ad playback that precede it.
struct OPNOwnedGameSession: Identifiable, Equatable, Sendable {
    let id: UUID
    let accountID: OPNAccountID
}

/// The application-owned record of running and starting games.
///
/// Main-actor isolated because every writer is a launch or teardown step driven from the main
/// actor, and every reader is a control that has to agree with them in the same turn - a sign-out
/// button that is enabled one frame after the purge already ran is the bug this prevents.
@MainActor
@Observable
final class OPNGameSessionRegistry {
    static let shared = OPNGameSessionRegistry()

    private(set) var sessions: [OPNOwnedGameSession] = []

    init() {}

    /// Freezes ownership at the moment the launch intent is accepted, before any queue, allocation
    /// or ad playback has begun. Returns the local session id the launch flow releases it by.
    @discardableResult
    func claim(accountID: OPNAccountID) -> UUID {
        let session = OPNOwnedGameSession(id: UUID(), accountID: accountID)
        sessions.append(session)
        return session.id
    }

    func release(_ id: UUID) {
        sessions.removeAll { $0.id == id }
    }

    func isOwned(by accountID: OPNAccountID) -> Bool {
        sessions.contains { $0.accountID == accountID }
    }

    /// Carries ownership across an identity upgrade. A legacy row starts on a `localOnly` identity
    /// and moves to its vendor subject the first time a sign-in supplies one; without this, a game
    /// started before that sign-in would belong to an identity nothing resolves to any more, and
    /// its account would look free to sign out of.
    func rekeyOwnership(from previous: OPNAccountID, to current: OPNAccountID) {
        guard previous != current else { return }
        sessions = sessions.map { session in
            guard session.accountID == previous else { return session }
            return OPNOwnedGameSession(id: session.id, accountID: current)
        }
    }
}
