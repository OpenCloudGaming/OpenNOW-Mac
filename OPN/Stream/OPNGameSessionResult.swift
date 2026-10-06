//  What a finished game session produced, tagged with the account it belongs to. A session can
//  outlive the catalog that started it, so its result is published rather than handed to a model.

import Foundation

struct OPNGameSessionResult {
    let accountID: OPNAccountID
    /// The stream that ran, or nil when the launch never produced one.
    let configuration: StreamLaunchConfiguration?
    /// The catalog game the intent was accepted for, when it knew one. Its identity and box art are
    /// what let a finished session merge with the vendor's own history for the same game.
    let launchedGame: OPNCatalogGameObject?
    let success: Bool
    let message: String
    let report: StreamReport?
    /// A launch the reader abandoned rather than a session that ran. Nothing is recorded for it.
    let wasCancelled: Bool
}

/// Holds one result per account until that account's catalog takes it, so a game that ends while
/// another account is browsing cannot write into that account's history.
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

    /// Removes and returns the result waiting for this account.
    func takeResult(for accountID: OPNAccountID) -> OPNGameSessionResult? {
        pending.removeValue(forKey: accountID.rawValue)
    }
}
