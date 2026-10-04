//  Whether an account may be signed out or removed right now.
//
//  Enforced at the mutation rather than only by disabling the controls that reach it. Sign-out and
//  removal are each reachable from the catalog's account dropdown, the controller catalog and the
//  windowless menu bar, and all of them funnel through the same two view-model calls; a disabled
//  button is a hint, not a guarantee. The check is also re-evaluated immediately before the
//  credential purge, so a session that started while a confirmation was on screen still blocks the
//  write instead of being stopped underneath the user.

import Foundation

@MainActor
enum OPNAccountMutationGuard {
    static let activeGameSessionMessage = "This account owns an active game session. End the session before signing out or removing the account."

    /// The reason the mutation must not proceed, or nil when it may.
    static func blockReason(for accountID: OPNAccountID?, registry: OPNGameSessionRegistry = .shared) -> String? {
        guard let accountID, registry.isOwned(by: accountID) else { return nil }
        return activeGameSessionMessage
    }
}
