//  Whether an account may be signed out or removed right now. Enforced at the mutation rather than
//  only by the controls that reach it, and re-read immediately before the credential purge.

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
