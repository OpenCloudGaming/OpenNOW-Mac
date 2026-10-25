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

    /// With couch co-op on, two streams are tiled borderless and share the screens; with the flag off
    /// nothing is ever placed; ending one hands the survivor back its own placement.
    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func couchCoopTilesTwoStreamsAndReleasesTheSurvivor() async throws {
        let previousFlag = OPNLabs.isCouchCoopEnabled
        defer { OPNLabs.setEnabled(OPNLabs.couchCoop, previousFlag) }
        let registry = OPNGameSessionRegistry.shared
        let accountA = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
        let accountB = makeLoginAccountForTesting(email: "b@example.com", userId: "user-b", isActive: false)
        let sessionA = makeLoginSessionForTesting(accountEmail: accountA.email, id: "tile-a", userId: "user-a")
        let sessionB = makeLoginSessionForTesting(accountEmail: accountB.email, id: "tile-b", userId: "user-b")
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

        OPNLabs.setEnabled(OPNLabs.couchCoop, false)
        OPNStreamWindowPresenter.shared.syncWithOwnedSessions()
        let windowA = try #require(OPNStreamWindowPresenter.shared.windows[gameA.id])
        let windowB = try #require(OPNStreamWindowPresenter.shared.windows[gameB.id])
        #expect(!windowA.layoutState.isAutoTiled && !windowB.layoutState.isAutoTiled)
        #expect(!windowA.allowsBackgroundGamepadInput)

        OPNLabs.setEnabled(OPNLabs.couchCoop, true)
        OPNStreamWindowPresenter.shared.retileWindows()
        try await Task.sleep(for: .milliseconds(300))
        #expect(windowA.layoutState.isAutoTiled && windowB.layoutState.isAutoTiled)
        #expect(windowA.layoutState.isBorderless && windowB.layoutState.isBorderless)
        #expect(windowA.frame != windowB.frame)

        OPNStreamWindowPresenter.shared.dismiss(gameB.id)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!windowA.layoutState.isAutoTiled)
        #expect(!windowA.layoutState.isBorderless)
    }

    /// The reader taking one tiled window hands the layout back: the survivor is the only placeable
    /// window left, which is not a layout, so it goes back to its own placement too.
    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func movingOneTiledWindowRetilesTheOther() async throws {
        try await withTiledPair { windowA, windowB in
            windowA.setFrame(windowA.frame.offsetBy(dx: 40, dy: -40), display: false)
            try await Task.sleep(for: .milliseconds(300))

            #expect(windowA.layoutState.isManuallyPlaced)
            #expect(!windowA.layoutState.isAutoTiled)
            #expect(!windowB.layoutState.isAutoTiled)
            #expect(!windowB.layoutState.isBorderless)
        }
    }

    /// Sending a tiled window to Picture in Picture releases it the way the HUD does, and the other
    /// window is retiled rather than left holding a half-screen frame.
    @Test(.disabled(if: CIWindowTestGate.isHostedRunner, Comment(rawValue: CIWindowTestGate.skipReason)))
    func releasingATiledWindowToPictureInPictureRetilesTheOther() async throws {
        try await withTiledPair { windowA, windowB in
            OPNStreamBorderless.releaseToReader(windowA)
            windowA.isPictureInPicture = true
            OPNStreamWindowPresenter.shared.retileWindows()
            try await Task.sleep(for: .milliseconds(300))

            #expect(!windowA.layoutState.isAutoTiled)
            #expect(!windowB.layoutState.isAutoTiled)
            #expect(!windowB.layoutState.isBorderless)
        }
    }

    /// Runs `body` with two streams tiled by couch co-op, and puts the flag and sessions back after.
    private func withTiledPair(_ body: (OPNStreamWindow, OPNStreamWindow) async throws -> Void) async throws {
        let previousFlag = OPNLabs.isCouchCoopEnabled
        defer { OPNLabs.setEnabled(OPNLabs.couchCoop, previousFlag) }
        let registry = OPNGameSessionRegistry.shared
        let accountA = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
        let accountB = makeLoginAccountForTesting(email: "b@example.com", userId: "user-b", isActive: false)
        let sessionA = makeLoginSessionForTesting(accountEmail: accountA.email, id: "retile-a", userId: "user-a")
        let sessionB = makeLoginSessionForTesting(accountEmail: accountB.email, id: "retile-b", userId: "user-b")
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

        OPNLabs.setEnabled(OPNLabs.couchCoop, true)
        OPNStreamWindowPresenter.shared.syncWithOwnedSessions()
        let windowA = try #require(OPNStreamWindowPresenter.shared.windows[gameA.id])
        let windowB = try #require(OPNStreamWindowPresenter.shared.windows[gameB.id])
        try await Task.sleep(for: .milliseconds(300))
        try #require(windowA.layoutState.isAutoTiled && windowB.layoutState.isAutoTiled)

        try await body(windowA, windowB)
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
