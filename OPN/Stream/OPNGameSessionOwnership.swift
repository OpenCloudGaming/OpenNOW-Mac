//  The application-owned record of the games this app is running, keyed by an explicit account id.
//  One game per account, decided before any cloud allocation, so a second account can stream too.

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

    private(set) var sessions: [OPNGameSession] = []

    init() {}

    var hasSessions: Bool { !sessions.isEmpty }

    /// Starts a launch for `account`, or returns nil when that account already owns a game. Every
    /// launch entry point shares this, so a second game for one account is refused rather than
    /// ending the one already running; another account's launch is admitted alongside it.
    func begin(
        account: LoginAccount,
        session: LoginSession,
        gameService: any CatalogGameServing,
        launchBridge: any GameLaunchBridging,
        discordPresence: any DiscordPresenceServing,
        streamProfile: OPNStreamPreferenceProfile,
        results: OPNGameSessionResultStore = .shared
    ) -> OPNGameSession? {
        guard let accountID = account.resolveStableAccountID() else {
            OPNLog.error(.launch, "Launch has no stable account identity to own it account=\(account.email)")
            return nil
        }
        guard !isOwned(by: accountID) else { return nil }
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
        sessions.append(gameSession)
        notifySessionDidChange()
        return gameSession
    }

    /// Releases one account's slot, once that local session no longer requires its credentials.
    func end(_ gameSession: OPNGameSession) {
        guard sessions.contains(where: { $0 === gameSession }) else { return }
        sessions.removeAll { $0 === gameSession }
        notifySessionDidChange()
    }

    func session(ownedBy accountID: OPNAccountID) -> OPNGameSession? {
        sessions.first { $0.accountID == accountID }
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
