import Foundation
import SwiftData
import Testing
@testable import OpenNOW

@MainActor
@Suite struct DetachedAccountActionTests {
    @Test func signOutTargetsTheDetachedAccountWithoutChangingTheMainAccount() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let confirmation = OPNConfirmationPresentation()
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [] })
        defer { handoff.end() }
        let actions = OPNMainAccountActions(confirmation: confirmation, handoff: handoff)
        await actions.bind(login: fixture.login).value

        await actions.request(.signOut(.init(account: fixture.detachedAccount)))?.value

        #expect(fixture.auth.endedEmails == [fixture.detachedEmail])
        #expect(fixture.detachedSession.accessToken.isEmpty)
        #expect(fixture.login.activeAccount === fixture.mainAccount)
        #expect(!fixture.mainSession.accessToken.isEmpty)
        #expect(confirmation.request == nil)
    }

    @Test func forgettingAnAccountQueuedWithoutAMainSceneUsesTheCapturedIdentity() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [] })
        defer { handoff.end() }
        let actions = OPNMainAccountActions(confirmation: OPNConfirmationPresentation(), handoff: handoff)
        let request = actions.request(.forget(.init(account: fixture.detachedAccount)))
        #expect(request == nil)
        #expect(fixture.auth.endedEmails.isEmpty)

        await actions.bind(login: fixture.login).value

        #expect(fixture.auth.endedEmails == [fixture.detachedEmail])
        #expect(fixture.login.accounts.map(\.email) == [fixture.mainAccount.email])
        #expect(fixture.login.activeAccount === fixture.mainAccount)
        #expect(GFNTokenStore.load(forIdentity: "session.\(fixture.detachedSessionID)") == nil)
    }

    @Test func aReplacedAccountDoesNotReceiveAPreviouslyQueuedDestructiveAction() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let confirmation = OPNConfirmationPresentation()
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [] })
        defer { handoff.end() }
        let actions = OPNMainAccountActions(confirmation: confirmation, handoff: handoff)
        actions.request(.forget(.init(account: fixture.detachedAccount)))
        let userID = fixture.detachedAccount.userId
        let context = fixture.container.mainContext
        context.delete(fixture.detachedAccount)
        try context.save()
        let replacement = makeLoginAccountForTesting(email: fixture.detachedEmail, userId: userID, isActive: false)
        context.insert(replacement)
        try context.save()

        await actions.bind(login: fixture.login).value

        #expect(fixture.login.accounts.contains { $0 === replacement })
        #expect(fixture.auth.endedEmails.isEmpty)
        #expect(confirmation.request?.title == "Account action unavailable")
        #expect(fixture.login.activeAccount === fixture.mainAccount)
        confirmation.dismiss()
    }

    @Test func accountActionsRecheckOwnershipWhenTheRequestArrives() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let confirmation = OPNConfirmationPresentation()
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [] })
        defer { handoff.end() }
        let actions = OPNMainAccountActions(confirmation: confirmation, handoff: handoff)
        let target = OPNMainAccountActions.Target(account: fixture.detachedAccount)
        actions.request(.signOut(target))
        _ = try #require(fixture.registry.begin(
            account: fixture.detachedAccount, session: fixture.detachedSession,
            gameService: OPNGameService.shared, launchBridge: OPNGameLaunchBridge.shared,
            discordPresence: DiscordRichPresence.shared, streamProfile: OPNStreamPreferenceProfile()
        ))

        await actions.bind(login: fixture.login).value
        #expect(confirmation.request?.message == OPNAccountMutationGuard.activeGameSessionMessage)
        confirmation.dismiss()
        await actions.request(.forget(target))?.value

        #expect(confirmation.request?.message == OPNAccountMutationGuard.activeGameSessionMessage)
        #expect(fixture.auth.endedEmails.isEmpty)
        #expect(!fixture.detachedSession.accessToken.isEmpty)
        #expect(fixture.login.accounts.contains { $0.email == fixture.detachedEmail })
        confirmation.dismiss()
    }

    @Test func addingAnAccountUsesTheMainLoginFlow() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [] })
        defer { handoff.end() }
        let actions = OPNMainAccountActions(confirmation: OPNConfirmationPresentation(), handoff: handoff)
        actions.request(.addAccount)

        await actions.bind(login: fixture.login).value
        #expect(fixture.login.signInRequest == .addAccount)
    }

    @Test(arguments: [false, true])
    func reauthenticationRevealsTheExactAccountWhileTheMainChooserIsOpen(isQueuedBeforeBind: Bool) async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [] })
        defer { handoff.end() }
        let actions = OPNMainAccountActions(confirmation: OPNConfirmationPresentation(), handoff: handoff)
        let mainAccessToken = fixture.mainSession.accessToken
        let detachedAccessToken = fixture.detachedSession.accessToken
        let gameSession = try #require(fixture.registry.begin(
            account: fixture.detachedAccount, session: fixture.detachedSession,
            gameService: OPNGameService.shared, launchBridge: OPNGameLaunchBridge.shared,
            discordPresence: DiscordRichPresence.shared, streamProfile: OPNStreamPreferenceProfile()
        ))
        if !isQueuedBeforeBind { await actions.bind(login: fixture.login).value }
        let chooserReason: AccountChooserReason = isQueuedBeforeBind ? .startup : .switchAccount
        fixture.login.accountChooserReason = chooserReason

        let request = actions.request(.reauthenticate(.init(account: fixture.detachedAccount)))
        if isQueuedBeforeBind {
            #expect(request == nil)
            #expect(fixture.login.signInRequest == nil)
            #expect(fixture.login.accountChooserReason == chooserReason)
            await actions.bind(login: fixture.login).value
        }
        await request?.value

        #expect(fixture.login.signInRequest == .reauthenticate(email: fixture.detachedEmail))
        #expect(fixture.login.accountChooserReason == nil)
        #expect(fixture.login.reauthAccount === fixture.detachedAccount)
        #expect(fixture.login.email == fixture.detachedEmail)
        #expect(fixture.login.activeAccount === fixture.mainAccount)
        #expect(fixture.login.activeSession === fixture.mainSession)
        #expect(fixture.mainSession.accessToken == mainAccessToken)
        #expect(fixture.detachedSession.accessToken == detachedAccessToken)
        #expect(fixture.registry.sessions.count == 1)
        #expect(fixture.registry.sessions.first === gameSession)
        #expect(fixture.auth.endedEmails.isEmpty)

        fixture.login.cancelReauthentication()

        #expect(fixture.login.signInRequest == nil)
        #expect(fixture.login.accountChooserReason == nil)
        #expect(fixture.login.activeAccount === fixture.mainAccount)
        #expect(fixture.login.activeSession === fixture.mainSession)
        #expect(fixture.registry.sessions.first === gameSession)
    }

    @Test(arguments: [false, true])
    func rejectedSavedGrantsRevealTheExactAccountWithoutOfflineContinuation(_ isSavedSessionUnexpired: Bool) async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let fixture = try DetachedAccountTestFixture()
            defer { fixture.tearDown() }
            try fixture.expireIDTokens()
            if !isSavedSessionUnexpired { fixture.detachedSession.expiresAt = .distantPast }
            let mainTokens = fixture.tokens(for: fixture.mainSession)
            let detachedTokens = fixture.tokens(for: fixture.detachedSession)
            SessionManagerURLProtocol.install(host: "login.nvidia.com") { _ in
                SessionManagerURLProtocol.response(json: ["error": "invalid_grant"], status: 401)
            }
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }
            fixture.login.accountChooserReason = .switchAccount

            fixture.login.activateAccount(fixture.detachedAccount)
            try await waitUntil { fixture.login.signInRequest == .reauthenticate(email: fixture.detachedEmail) }

            #expect(fixture.login.accountChooserReason == nil)
            #expect(fixture.login.reauthAccount === fixture.detachedAccount)
            #expect(fixture.login.validationMessage.contains("saved session was rejected"))
            #expect(fixture.login.successMessage.isEmpty)
            #expect(fixture.login.activeSession === fixture.mainSession)
            #expect(fixture.tokens(for: fixture.mainSession) == mainTokens)
            #expect(fixture.tokens(for: fixture.detachedSession) == detachedTokens)
            let authSession = await fixture.login.jarvisAuthService.session
            #expect(authSession.clientToken.isEmpty)
            let requests = SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com")
            #expect(requests.count == 2)
            #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.path == "/token" })
        }
    }

    @Test func aTransientFailureForAnExpiredSavedSessionShowsARetryNoticeInsteadOfSignIn() async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let fixture = try DetachedAccountTestFixture()
            defer { fixture.tearDown() }
            defer { fixture.login.dismissAccountSwitchNotice() }
            fixture.detachedSession.expiresAt = .distantPast
            let detachedTokens = fixture.tokens(for: fixture.detachedSession)
            SessionManagerURLProtocol.install(host: "login.nvidia.com") { _ in
                SessionManagerURLProtocol.response(json: ["error": "temporarily_unavailable"], status: 503)
            }
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }

            fixture.login.activateAccount(fixture.detachedAccount)
            try await waitUntil { fixture.login.accountSwitchNotice != nil }

            #expect(fixture.login.accountSwitchNotice == fixture.login.validationMessage)
            #expect(fixture.login.validationMessage.contains("Check your connection"))
            #expect(fixture.login.signInRequest == nil)
            #expect(fixture.login.activeSession === fixture.mainSession)
            #expect(fixture.tokens(for: fixture.detachedSession) == detachedTokens)
            #expect(SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").count == JarvisRetryPolicy.gfnPC.maxRetries + 1)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aRejectedRestoreCannotDisplaceANewerExactAccountHandoffAfterSignOut() async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let fixture = try DetachedAccountTestFixture()
            defer { fixture.tearDown() }
            fixture.detachedSession.expiresAt = .distantPast
            let mainTokens = fixture.tokens(for: fixture.mainSession)
            let handoff = OPNMainWindowAccountHandoff(mainWindow: { nil }, coveringLevels: { [] })
            defer { handoff.end() }
            let actions = OPNMainAccountActions(confirmation: OPNConfirmationPresentation(), handoff: handoff)
            await actions.bind(login: fixture.login).value
            let revokeBeforeResponse: @MainActor @Sendable () async -> Void = {
                await actions.request(.signOut(.init(account: fixture.detachedAccount)))?.value
                await actions.request(.reauthenticate(.init(account: fixture.mainAccount)))?.value
            }
            SessionManagerURLProtocol.install(host: "login.nvidia.com") { _ in
                if SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").count == 1 {
                    let revocation = DispatchSemaphore(value: 0)
                    Task { @MainActor in
                        await revokeBeforeResponse()
                        revocation.signal()
                    }
                    revocation.wait()
                }
                return SessionManagerURLProtocol.response(json: ["error": "invalid_grant"], status: 401)
            }
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }
            fixture.login.accountChooserReason = .switchAccount

            fixture.login.activateAccount(fixture.detachedAccount)
            try await waitUntil {
                SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").count == 2 && !fixture.login.isAuthenticating
            }

            #expect(fixture.auth.endedEmails == [fixture.detachedEmail])
            #expect(fixture.detachedSession.accessToken.isEmpty && fixture.detachedSession.refreshToken.isEmpty)
            #expect(fixture.login.signInRequest == .reauthenticate(email: fixture.mainAccount.email))
            #expect(fixture.login.reauthAccount === fixture.mainAccount)
            #expect(fixture.login.email == fixture.mainAccount.email)
            #expect(fixture.login.accountChooserReason == nil)
            #expect(fixture.login.activeSession === fixture.mainSession)
            #expect(fixture.tokens(for: fixture.mainSession) == mainTokens)
        }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(predicate(), "The scripted account restore did not finish")
    }
}
