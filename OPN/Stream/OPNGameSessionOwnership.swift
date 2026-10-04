//  The application-owned record of the game this app is running, keyed by an explicit account id.
//  One slot: this release admits a single local stream, decided before any cloud allocation.

import Foundation
import Observation

/// The application-owned record of running and starting games.
@MainActor
@Observable
final class OPNGameSessionRegistry {
    static let shared = OPNGameSessionRegistry()

    /// Posted whenever the owned session, or the stream it presents, changes. The stream window
    /// presenter follows this, so the window belongs to the session and not to a replaceable catalog.
    static let sessionDidChangeNotification = Notification.Name("OPNGameSessionDidChange")

    private(set) var current: OPNGameSession?

    init() {}

    var isOccupied: Bool { current != nil }

    /// Starts a launch for `account`, or returns nil when the one-local-stream limit is taken. Every
    /// launch entry point shares this, so a second launch is refused rather than ending the game.
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

    /// Releases the slot, once the local session no longer requires the owner's credentials.
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

    /// Carries ownership across a legacy `localOnly` identity moving to its vendor subject, so a game
    /// started before that upgrade does not end up owned by an identity nothing resolves to.
    func rekeyOwnership(from previous: OPNAccountID, to newIdentity: OPNAccountID) {
        guard previous != newIdentity, let gameSession = session(ownedBy: previous) else { return }
        gameSession.rekey(to: newIdentity)
        notifySessionDidChange()
    }

    func notifySessionDidChange() {
        NotificationCenter.default.post(name: Self.sessionDidChangeNotification, object: nil)
    }
}
