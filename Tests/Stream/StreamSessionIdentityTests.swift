//  Two invariants the per-session work depends on, both of which the stream surface can silently
//  break: the configuration has to carry the session's own id, and a launch that ends before its
//  stream does still has to take its Discord line back down.

import Foundation
import Testing
@testable import OpenNOW

@MainActor
private final class RecordingDiscordPresence: DiscordPresenceServing {
    var isEnabled = true
    private(set) var states: [DiscordPresenceState] = []

    func update(_ state: DiscordPresenceState) {
        states.append(state)
    }

    var isIdle: Bool {
        states.last == .idle
    }
}

@MainActor
@Suite struct StreamSessionIdentityTests {
    /// The stream surface registers its commands under the configuration's id and every targeted
    /// control looks the session up by the session's own id, so they have to be the same id: a
    /// different one leaves the catalog's END reaching no handler at all.
    @Test func theConfigurationCarriesTheOwningSessionsID() {
        let sessionID = UUID()
        let configuration = StreamLaunchConfiguration(
            title: "Cyberpunk 2077",
            applicationID: "1093630001",
            accessToken: "token",
            accountLinked: true,
            selectedStore: "steam"
        )

        let snapshotted = configuration.snapshottingSession(
            id: sessionID,
            ownerDisplayName: "Account A",
            mappingGameIdentity: "game-1"
        )

        #expect(snapshotted.id == sessionID)
        #expect(snapshotted.owningAccountDisplayName == "Account A")
        #expect(snapshotted.mappingGameIdentity == "game-1")
        #expect(snapshotted.applicationID == configuration.applicationID)
        #expect(snapshotted.title == configuration.title)
    }

    /// A launch that never reaches a stream still has to clear the "launching <game>" line, or
    /// Discord keeps showing a game that is not starting.
    @Test func aCancelledLaunchTakesItsDiscordLineBackDown() throws {
        let presence = RecordingDiscordPresence()
        let game = try makeSessionForDiscordTest(presence: presence)

        game.begin(game: makeMaintenanceGameForTesting(id: "id-1", title: "Manor Lords"), variantIndex: 0)
        #expect(!presence.isIdle)

        game.cancelLaunch()

        #expect(presence.isIdle)
    }

    @Test func aCancelledStreamLaunchTakesItsDiscordLineBackDown() throws {
        let presence = RecordingDiscordPresence()
        let game = try makeSessionForDiscordTest(presence: presence)
        game.begin(game: makeMaintenanceGameForTesting(id: "id-1", title: "Manor Lords"), variantIndex: 0)
        game.configuration = StreamLaunchConfiguration(
            title: "Manor Lords",
            applicationID: "123",
            accessToken: "token",
            accountLinked: true,
            selectedStore: "steam"
        )

        game.cancelStreamLaunch()

        #expect(presence.isIdle)
    }

    /// The session is built by hand rather than launched: `begin` only reaches the vendor through the
    /// launch bridge, and these assert the local state around it.
    private func makeSessionForDiscordTest(presence: RecordingDiscordPresence) throws -> OPNGameSession {
        let account = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
        let session = makeLoginSessionForTesting(accountEmail: account.email, id: "discord-session", userId: "user-a")
        let accountID = try #require(account.resolveStableAccountID())
        return OPNGameSession(
            account: account,
            session: session,
            accountID: accountID,
            gameService: OPNGameService.shared,
            launchBridge: OPNGameLaunchBridge.shared,
            discordPresence: presence,
            streamProfile: OPNStreamPreferenceProfile(),
            registry: OPNGameSessionRegistry(),
            results: OPNGameSessionResultStore()
        )
    }
}
