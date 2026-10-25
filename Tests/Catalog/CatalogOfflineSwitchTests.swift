import Foundation
import Testing
@testable import OpenNOW

@MainActor
private final class OfflineCatalogPresence: DiscordPresenceServing {
    var isEnabled = false
    private(set) var lastState = DiscordPresenceState.idle

    func update(_ state: DiscordPresenceState) { lastState = state }
}

@MainActor
@Suite struct CatalogOfflineSwitchTests {
    @Test(arguments: [false, true])
    func anOfflineSwitchKeepsDetachedMembershipOwnedByItsSavedSession(_ isRequestPendingDuringSwitch: Bool) async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            installOfflineRefreshResponse()
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }
            let fixture = try DetachedAccountTestFixture()
            defer { fixture.tearDown() }
            try expireIDTokens(in: fixture)
            let service = CatalogAccountServiceStub()
            let model = makeDetachedCatalog(fixture: fixture, service: service)
            let ownerCredentials = credentials(for: fixture.detachedSession)
            try await restoreOfflineSession(fixture.detachedAccount, fixture: fixture)
            if isRequestPendingDuringSwitch { model.loadAccount() }

            try await restoreOfflineSession(fixture.mainAccount, fixture: fixture)
            #expect(fixture.login.activeSession === fixture.mainSession)
            #expect(!fixture.detachedAccount.isActive && !fixture.detachedSession.isActive)
            #expect(fixture.detachedAccount.authStatus == JarvisAuthStatus.notLoggedIn.rawValue)
            #expect(credentials(for: fixture.detachedSession) == ownerCredentials)
            if !isRequestPendingDuringSwitch { model.loadAccount() }

            try #require(service.subscriptionRequestCount == 1)
            #expect(model.dlssMembershipState == .loading)
            #expect(service.subscriptionUserIDs == [fixture.detachedSession.userId])
            let mainService = CatalogAccountServiceStub()
            let mainCatalog = CatalogViewModel(account: fixture.mainAccount, session: fixture.mainSession, gameService: mainService, onRefreshAuth: { false })
            #expect(mainCatalog.configureCatalogService())
            #expect(model.configureCatalogService())
            #expect(service.configuredCredentials == ownerCredentials)
            #expect(mainService.configuredCredentials == credentials(for: fixture.mainSession))
            withPreservedPreferences(["OpenNOW.Stream.DlssEntitlements", "OpenNOW.Stream.EntitledAudioChannelCount", "OpenNOW.Stream.EntitledInGameSettingsPersistence"]) {
                OPNStreamPreferences.clearDlssEntitlements()
                OPNStreamPreferences.saveEntitledAudioChannelCount(2)
                OPNStreamPreferences.saveEntitledInGameSettingsPersistence(false)
                service.completeSubscription(at: 0, subscription: membership())
                #expect(model.dlssMembershipState == .loaded(membership().dlssEntitlements))
                #expect(model.currentLaunchEntitlements == OPNLaunchEntitlements(subscription: membership()))
                #expect(OPNStreamPreferences.loadDlssEntitlements() == .none)
                #expect(OPNStreamPreferences.loadEntitledAudioChannelCount() == 2)
                #expect(!OPNStreamPreferences.loadEntitledInGameSettingsPersistence())
            }
            try expectDetachedResumeIsAdmitted(model, fixture: fixture)
            #expect(fixture.login.activeSession === fixture.mainSession)
            #expect(SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").count == 2)
        }
    }

    @Test(arguments: [false, true])
    func signingOutAfterAnOfflineSwitchRevokesDetachedCatalogAccess(_ isMembershipLoaded: Bool) async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            installOfflineRefreshResponse()
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }
            let fixture = try DetachedAccountTestFixture()
            defer { fixture.tearDown() }
            try expireIDTokens(in: fixture)
            try await restoreOfflineSession(fixture.detachedAccount, fixture: fixture)
            try await restoreOfflineSession(fixture.mainAccount, fixture: fixture)
            let service = CatalogAccountServiceStub()
            let model = makeDetachedCatalog(fixture: fixture, service: service)
            model.loadAccount()
            try #require(service.subscriptionRequestCount == 1)
            if isMembershipLoaded {
                service.completeSubscription(at: 0, subscription: membership())
                #expect(model.currentLaunchEntitlements.audioChannelCount == 8)
            }
            let membershipBeforeSignOut = model.account.membershipTier

            await fixture.login.signOutAccount(fixture.detachedAccount)
            #expect(fixture.auth.endedEmails == [fixture.detachedEmail])
            #expect(fixture.detachedSession.accessToken.isEmpty && fixture.detachedSession.idToken.isEmpty)
            #expect(fixture.detachedSession.refreshToken.isEmpty && fixture.detachedSession.clientToken.isEmpty)
            #expect(!model.configureCatalogService())
            if !isMembershipLoaded { service.completeSubscription(at: 0, subscription: membership()) }
            #expect(model.account.membershipTier == membershipBeforeSignOut)
            #expect(model.currentLaunchEntitlements == .none)
            model.activeHomeSession = resumableSession()
            model.resumeActiveHomeSession()
            #expect(!fixture.registry.hasSessions)
            #expect(model.launchErrorMessage == "Sign in again before launching a game.")
            model.loadAccount()
            #expect(service.subscriptionRequestCount == 1)
            #expect(model.dlssMembershipState == .signedOut)
            #expect(fixture.login.activeSession === fixture.mainSession)
        }
    }

    private func installOfflineRefreshResponse() {
        SessionManagerURLProtocol.install(host: "login.nvidia.com") { _ in
            SessionManagerURLProtocol.response(json: ["error": "invalid_grant"], status: 401)
        }
    }

    private func expireIDTokens(in fixture: DetachedAccountTestFixture) throws {
        for session in [fixture.mainSession, fixture.detachedSession] {
            let claims: [String: Any] = ["sub": session.userId, "email": session.accountEmail, "exp": 1]
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            session.idToken = "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.\(payload)."
            try #require(JarvisSessionParser.idTokenExpiry(session.idToken) == 1_000)
            try #require(session.canContinueOffline && !session.isExpired)
        }
    }

    private func restoreOfflineSession(_ account: LoginAccount, fixture: DetachedAccountTestFixture) async throws {
        let previousRequestCount = SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").count
        try #require(await fixture.login.restoreAccountSession(account))
        try #require(fixture.login.successMessage.contains("offline session"))
        let refreshRequests = SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").dropFirst(previousRequestCount)
        try #require(refreshRequests.count == 1)
        let request = try #require(refreshRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/token")
        #expect(fixture.login.activeAccount === account)
    }

    private func makeDetachedCatalog(fixture: DetachedAccountTestFixture, service: CatalogAccountServiceStub) -> CatalogViewModel {
        CatalogViewModel(
            account: fixture.detachedAccount, session: fixture.detachedSession, gameService: service,
            discordPresence: OfflineCatalogPresence(), sessionRegistry: fixture.registry,
            sessionResultStore: OPNGameSessionResultStore(), onRefreshAuth: { false }
        )
    }

    private func credentials(for session: LoginSession) -> CatalogAccountServiceStub.SessionCredentials {
        .init(accessToken: session.accessToken, idToken: session.idToken, userID: session.userId)
    }

    private func membership() -> OPNSubscriptionInfo {
        var subscription = OPNSubscriptionInfo()
        subscription.membershipTier = "Ultimate"
        subscription.entitledAudioChannelCount = 8
        subscription.isInGameSettingsPersistenceEntitled = true
        subscription.dlssEntitlements = DlssEntitlements(superResolution: DlssCapability(isEntitled: true))
        return subscription
    }

    private func resumableSession() -> OPNActiveSessionObject {
        OPNActiveSessionObject(sessionId: "offline-owner-seat", appId: 123, status: 2, serverIp: "owner-seat.nvidiagrid.net", streamingBaseUrl: OPNGameService.defaultStreamingBaseUrl, signalingUrl: "")
    }

    private func expectDetachedResumeIsAdmitted(_ model: CatalogViewModel, fixture: DetachedAccountTestFixture) throws {
        try withPreservedPreferences([OPNSessionReadyAction.modeKey]) {
            OPNSessionReadyAction.mode = .off
            model.activeHomeSession = resumableSession()
            model.resumeActiveHomeSession()
            let ownerID = try #require(fixture.detachedAccount.resolveStableAccountID())
            let owned = try #require(fixture.registry.session(ownedBy: ownerID))
            defer { owned.cancelStreamLaunch() }
            let configuration = try #require(owned.configuration)
            #expect(configuration.accessToken == fixture.detachedSession.idToken)
            #expect(configuration.owningAccountID == ownerID.rawValue)
            #expect(configuration.launchEntitlements == OPNLaunchEntitlements(subscription: membership()))
            #expect(configuration.resumeSessionID == "offline-owner-seat")
            #expect(model.launchErrorMessage.isEmpty)
        }
    }
}
