//  What a game session produced, tagged with the account it belongs to.
//
//  A session can outlive the catalog that started it - that is the point of owning it at application
//  scope - so its result cannot be handed straight to a view model. It is published here under the
//  owner's identity and adopted by the owner's catalog: the one on screen when the game ends, or the
//  one that mounts when the reader switches back to that account.

import Foundation

struct OPNGameSessionResult {
    let accountID: OPNAccountID
    /// The stream that ran, or nil when the launch never produced one.
    let configuration: StreamLaunchConfiguration?
    /// The catalog game the session was launched from, when the intent knew it. Its identity and box
    /// art are what let a finished session merge with the vendor's own history for the same game.
    let launchedGame: OPNCatalogGameObject?
    let success: Bool
    let message: String
    let report: StreamReport?
    /// A launch the reader abandoned rather than a session that ran. Nothing is recorded for it.
    let wasCancelled: Bool
}

/// Holds one result per account until that account's catalog takes it.
///
/// The store is keyed by account identity rather than by "the current account", so a game that ends
/// while another account is browsing cannot write into that account's history, playtime or summary.
@MainActor
final class OPNGameSessionResultStore {
    static let shared = OPNGameSessionResultStore()
    static let didPublishNotification = Notification.Name("OPNGameSessionResultDidPublish")

    private var pending: [String: OPNGameSessionResult] = [:]

    init() {}

    func publish(_ result: OPNGameSessionResult) {
        pending[result.accountID.rawValue] = result
        NotificationCenter.default.post(name: Self.didPublishNotification, object: nil)
    }

    /// Removes and returns the result waiting for this account. One local stream at a time, so an
    /// account can have at most one waiting.
    func takeResult(for accountID: OPNAccountID) -> OPNGameSessionResult? {
        pending.removeValue(forKey: accountID.rawValue)
    }
}
