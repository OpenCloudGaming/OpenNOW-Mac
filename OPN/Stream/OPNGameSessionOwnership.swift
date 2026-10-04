//  The application-owned record of the game this app is running.
//
//  A session's owner is fixed when its launch intent is accepted and does not follow the catalog's
//  browsing selection: switching accounts changes what the catalog browses, never which account's
//  credentials, provider route and history a starting or running game belongs to. The session itself
//  lives at application scope for the same reason - a catalog is remounted whenever the selected
//  session changes, so a per-catalog record would be dropped exactly when it is needed.
//
//  One slot, not a list: this release admits a single local stream, and the limit is enforced here,
//  before any cloud allocation and before any window is replaced, so a second launch is refused
//  rather than ending the game already running. That is release policy, not an ownership
//  assumption - the slot is keyed by an explicit account id, never by the browsing selection.

import Foundation
import Observation

/// The application-owned record of running and starting games.
///
/// Main-actor isolated because every writer is a launch or teardown step driven from the main actor,
/// and every reader is a control that has to agree with them in the same turn - a sign-out button
/// that is enabled one frame after the purge already ran is the bug this prevents.
@MainActor
@Observable
final class OPNGameSessionRegistry {
    static let shared = OPNGameSessionRegistry()

    /// Posted whenever the owned session, or the stream it presents, changes. The stream window
    /// presenter follows this, so the window belongs to the session rather than to a catalog that
    /// can be replaced underneath it.
    static let sessionDidChangeNotification = Notification.Name("OPNGameSessionDidChange")

    private(set) var current: OPNGameSession?

    init() {}

    var isOccupied: Bool { current != nil }

    /// Starts a launch for `account`, or returns nil when the one-local-stream limit is already
    /// taken or the account has no stable identity to own a session with. Admission is decided here
    /// so every launch entry point - the catalog, a shortcut, the menu bar, a resumed session -
    /// shares it.
    func begin(
        account: LoginAccount,
        session: LoginSession,
        gameService: any CatalogGameServing,
        launchBridge: any GameLaunchBridging,
        discordPresence: any DiscordPresenceServing,
        streamProfile: OPNStreamPreferenceProfile,
        results: OPNGameSessionResultStore = .shared
    ) -> OPNGameSession? {
        guard current == nil else { return nil }
        guard let accountID = account.resolveStableAccountID() else {
            OPNLog.error(.launch, "Launch has no stable account identity to own it account=\(account.email)")
            return nil
        }
        let gameSession = OPNGameSession(
            account: account,
            session: session,
            accountID: accountID,
            gameService: gameService,
            launchBridge: launchBridge,
            discordPresence: discordPresence,
            streamProfile: streamProfile,
            registry: self,
            results: results
        )
        current = gameSession
        notifySessionDidChange()
        return gameSession
    }

    /// Releases the slot. Called once the local session no longer requires the owner's credentials.
    func end(_ gameSession: OPNGameSession) {
        guard current === gameSession else { return }
        current = nil
        notifySessionDidChange()
    }

    func session(ownedBy accountID: OPNAccountID) -> OPNGameSession? {
        guard let current, current.accountID == accountID else { return nil }
        return current
    }

    func isOwned(by accountID: OPNAccountID) -> Bool {
        session(ownedBy: accountID) != nil
    }

    /// Carries ownership across an identity upgrade. A legacy row starts on a `localOnly` identity
    /// and moves to its vendor subject the first time a sign-in supplies one; without this, a game
    /// started before that sign-in would belong to an identity nothing resolves to any more, and
    /// its account would look free to sign out of.
    func rekeyOwnership(from previous: OPNAccountID, to newIdentity: OPNAccountID) {
        guard previous != newIdentity, let gameSession = session(ownedBy: previous) else { return }
        gameSession.rekey(to: newIdentity)
        notifySessionDidChange()
    }

    func notifySessionDidChange() {
        NotificationCenter.default.post(name: Self.sessionDidChangeNotification, object: nil)
    }
}
