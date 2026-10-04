//  Two accounts can stream at once, so the presenter has to hold one window per session rather than
//  one window for the app. Needs a window server, so it is gated the way the other AppKit tests are.

import AppKit
import Testing
@testable import OpenNOW

@MainActor @Suite(.serialized, .streamLifecycleExclusive) struct StreamWindowConcurrencyTests {
    /// Two live sessions get two windows, each identified by its own session, and ending one takes
    /// only that one away.
    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func twoSessionsGetTwoWindowsAndEndingOneTakesOnlyItsOwn() throws {
        // The presenter is the app's one window driver, so it follows the shared registry.
        let registry = OPNGameSessionRegistry.shared
        let accountA = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
        let accountB = makeLoginAccountForTesting(email: "b@example.com", userId: "user-b", isActive: false)
        let sessionA = makeLoginSessionForTesting(accountEmail: accountA.email, id: "window-a", userId: "user-a")
        let sessionB = makeLoginSessionForTesting(accountEmail: accountB.email, id: "window-b", userId: "user-b")
        defer {
            sessionA.purgeTokens()
            sessionB.purgeTokens()
        }
        let gameA = try #require(begin(registry: registry, account: accountA, session: sessionA))
        let gameB = try #require(begin(registry: registry, account: accountB, session: sessionB))
        defer {
            OPNStreamWindowPresenter.shared.dismiss(gameA.id)
            OPNStreamWindowPresenter.shared.dismiss(gameB.id)
            registry.end(gameA)
            registry.end(gameB)
        }
        gameA.configuration = Self.configuration(title: "Cyberpunk 2077")
        gameB.configuration = Self.configuration(title: "Manor Lords")

        OPNStreamWindowPresenter.shared.syncWithOwnedSessions()

        let windowA = try #require(OPNStreamWindowPresenter.shared.windows[gameA.id])
        let windowB = try #require(OPNStreamWindowPresenter.shared.windows[gameB.id])
        #expect(windowA !== windowB)
        #expect(windowA.identifier?.rawValue == OPNStreamWindowFactory.identifier(for: gameA.id))
        #expect(OPNStreamWindowFactory.existing(sessionID: gameB.id) === windowB)

        OPNStreamWindowPresenter.shared.dismiss(gameA.id)

        #expect(OPNStreamWindowPresenter.shared.windows[gameA.id] == nil)
        #expect(OPNStreamWindowPresenter.shared.windows[gameB.id] === windowB)
    }

    /// The sync is the app's only window driver, so it also has to take a window away once its
    /// session ends - whichever path ended it.
    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func aSessionThatEndsLosesItsWindow() throws {
        let registry = OPNGameSessionRegistry.shared
        let account = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
        let session = makeLoginSessionForTesting(accountEmail: account.email, id: "window-end", userId: "user-a")
        let game = try #require(begin(registry: registry, account: account, session: session))
        defer {
            OPNStreamWindowPresenter.shared.dismiss(game.id)
            registry.end(game)
            session.purgeTokens()
        }
        game.configuration = Self.configuration(title: "Cyberpunk 2077")

        OPNStreamWindowPresenter.shared.syncWithOwnedSessions()
        #expect(OPNStreamWindowPresenter.shared.windows[game.id] != nil)

        registry.end(game)
        OPNStreamWindowPresenter.shared.syncWithOwnedSessions()

        #expect(OPNStreamWindowPresenter.shared.windows[game.id] == nil)
    }

    private static func configuration(title: String) -> StreamLaunchConfiguration {
        StreamLaunchConfiguration(
            title: title,
            applicationID: "1093630001",
            accessToken: "token",
            accountLinked: true,
            selectedStore: "steam"
        )
    }

    private func begin(registry: OPNGameSessionRegistry, account: LoginAccount, session: LoginSession) -> OPNGameSession? {
        registry.begin(
            account: account,
            session: session,
            gameService: OPNGameService.shared,
            launchBridge: OPNGameLaunchBridge.shared,
            discordPresence: DiscordRichPresence.shared,
            streamProfile: OPNStreamPreferenceProfile(),
            results: OPNGameSessionResultStore()
        )
    }
}
