import Foundation
import SwiftData
import Testing
@testable import OpenNOW

@MainActor
@Suite struct DetachedSessionRefresherTests {
    enum Invalidation: CaseIterable, Equatable, Sendable {
        case purge
        case signOut
        case forget
        case deleteSession
        case replaceSession
        case replaceSessionUsingOriginalID
        case deleteAccount
        case replaceAccount
        case replaceCredentials
    }

    @Test(.timeLimit(.minutes(1)), arguments: Invalidation.allCases)
    func aSuspendedRefreshDiscardsInvalidatedCredentials(_ invalidation: Invalidation) async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let originalToken = fixture.detachedSession.accessToken
        let suspended = SuspendedDetachedRefresh()
        let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext, refreshSession: suspended.refresh)
        let task = Task { await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession) }
        await suspended.waitUntilStarted()

        try await invalidate(invalidation, fixture: fixture)
        await suspended.complete()

        #expect(await task.value == false)
        #expect(fixture.mainAccount.isActive)
        #expect(fixture.mainSession.isActive)
        let persisted = GFNTokenStore.load(forIdentity: "session.\(fixture.detachedSessionID)")
        switch invalidation {
        case .replaceCredentials:
            #expect(persisted?.accessToken == "new-login-access")
            #expect(persisted?.refreshToken == "new-login-refresh")
        case .purge, .signOut, .forget:
            #expect(persisted == nil)
        default:
            #expect(persisted?.accessToken == originalToken)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func aFreshRefreshPersistsOnlyTheInactiveAccountsTokens() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let originalMainToken = fixture.mainSession.accessToken
        let suspended = SuspendedDetachedRefresh()
        let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext, refreshSession: suspended.refresh)
        let task = Task { await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession) }
        await suspended.waitUntilStarted()
        await suspended.complete()

        #expect(await task.value)
        #expect(fixture.detachedSession.accessToken == "refreshed-access")
        #expect(GFNTokenStore.load(forIdentity: "session.\(fixture.detachedSessionID)")?.refreshToken == "refreshed-refresh")
        #expect(!fixture.detachedAccount.isActive)
        #expect(!fixture.detachedSession.isActive)
        #expect(fixture.login.activeAccount === fixture.mainAccount)
        #expect(fixture.mainSession.accessToken == originalMainToken)
    }

    @Test(.timeLimit(.minutes(1)))
    func aFailedRefreshCannotOfferOfflineContinuationAfterAPurge() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let suspended = SuspendedDetachedRefresh()
        let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext, refreshSession: suspended.refresh)
        let task = Task { await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession) }
        await suspended.waitUntilStarted()
        fixture.detachedSession.purgeTokens()
        await suspended.complete(isSuccessful: false)

        #expect(await task.value == false)
        #expect(fixture.detachedSession.accessToken.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledRefreshDiscardsItsLateResponse() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let originalToken = fixture.detachedSession.accessToken
        let suspended = SuspendedDetachedRefresh()
        let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext, refreshSession: suspended.refresh)
        let task = Task { await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession) }
        await suspended.waitUntilStarted()
        task.cancel()
        await suspended.complete()

        #expect(await task.value == false)
        #expect(fixture.detachedSession.accessToken == originalToken)
    }

    @Test(.timeLimit(.minutes(1)))
    func aResponseForAnotherSubjectNeverReplacesTheSelectedAccountsTokens() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let originalToken = fixture.detachedSession.accessToken
        let suspended = SuspendedDetachedRefresh()
        let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext, refreshSession: suspended.refresh)
        let task = Task { await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession) }
        await suspended.waitUntilStarted()
        await suspended.complete(replacementUserID: fixture.mainAccount.userId)

        #expect(await task.value == false)
        #expect(fixture.detachedSession.accessToken == originalToken)
    }

    @Test func deletedModelsAreRejectedBeforeStartingARefresh() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let context = fixture.container.mainContext
        context.delete(fixture.detachedSession)
        context.delete(fixture.detachedAccount)
        try context.save()
        let refresher = DetachedSessionRefresher(modelContext: context) { session in
            Issue.record("Deleted models reached the refresh transport")
            return session
        }

        #expect(await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession) == false)
    }

    @Test func anUnchangedUnexpiredSessionCanContinueOfflineWhenRefreshFails() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext) { _ in
            throw SuspendedDetachedRefresh.Failure.unavailable
        }

        #expect(await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession))
        #expect(!fixture.detachedAccount.isActive)
        #expect(!fixture.detachedSession.isActive)
    }

    @Test func aServiceCancellationCannotOfferOfflineContinuationForUnexpiredCredentials() async throws {
        let fixture = try DetachedAccountTestFixture()
        defer { fixture.tearDown() }
        try #require(fixture.detachedSession.canContinueOffline && !fixture.detachedSession.isExpired)
        let mainTokens = fixture.tokens(for: fixture.mainSession)
        let detachedTokens = fixture.tokens(for: fixture.detachedSession)
        let issuedAt = fixture.detachedSession.issuedAt
        let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext) { _ in
            throw CancellationError()
        }

        #expect(await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession) == false)
        #expect(!Task.isCancelled)
        #expect(fixture.tokens(for: fixture.mainSession) == mainTokens)
        #expect(fixture.tokens(for: fixture.detachedSession) == detachedTokens)
        #expect(GFNTokenStore.load(forIdentity: "session.\(fixture.detachedSessionID)") == detachedTokens)
        #expect(fixture.detachedSession.issuedAt == issuedAt)
        #expect(fixture.login.activeSession === fixture.mainSession)
        #expect(!fixture.detachedAccount.isActive && !fixture.detachedSession.isActive)
    }

    @Test(arguments: [400, 401, 403, 503])
    func theDefaultRefresherOnlyContinuesOfflineForNonCredentialFailures(_ status: Int) async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let fixture = try DetachedAccountTestFixture()
            defer { fixture.tearDown() }
            try fixture.expireIDTokens()
            let mainTokens = fixture.tokens(for: fixture.mainSession)
            let detachedTokens = fixture.tokens(for: fixture.detachedSession)
            let detachedStatus = fixture.detachedAccount.authStatus
            SessionManagerURLProtocol.install(host: "login.nvidia.com") { _ in
                SessionManagerURLProtocol.response(json: ["error": status == 503 ? "temporarily_unavailable" : "invalid_grant"], status: status)
            }
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }

            let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext)
            #expect(await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession) == (status == 503))
            #expect(fixture.tokens(for: fixture.detachedSession) == detachedTokens)
            #expect(fixture.tokens(for: fixture.mainSession) == mainTokens)
            #expect(GFNTokenStore.load(forIdentity: "session.\(fixture.detachedSessionID)") == detachedTokens)
            #expect(fixture.detachedAccount.authStatus == detachedStatus)
            #expect(!fixture.detachedAccount.isActive && !fixture.detachedSession.isActive)
            #expect(fixture.login.activeSession === fixture.mainSession)
            let requests = SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com")
            #expect(requests.count == (status == 503 ? JarvisRetryPolicy.gfnPC.maxRetries + 1 : 2))
            #expect(requests.allSatisfy { $0.httpMethod == "POST" && $0.url?.path == "/token" })
        }
    }

    @Test func theDefaultRefresherReplacesARejectedClientTokenThroughTheOwnersRefreshGrant() async throws {
        try await networkTestIsolationLock.withLock { @MainActor @Sendable in
            let fixture = try DetachedAccountTestFixture()
            defer { fixture.tearDown() }
            try fixture.expireIDTokens()
            let mainTokens = fixture.tokens(for: fixture.mainSession)
            SessionManagerURLProtocol.install(host: "login.nvidia.com") { request in
                if request.url?.path == "/client_token" {
                    return SessionManagerURLProtocol.response(json: ["client_token": "fresh-owner-client", "expires_in": 240])
                }
                if SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").count == 1 {
                    return SessionManagerURLProtocol.response(json: ["error": "invalid_grant"], status: 401)
                }
                return SessionManagerURLProtocol.response(json: ["access_token": "fresh-owner-access", "refresh_token": "fresh-owner-refresh", "id_token": "fresh-owner-id", "expires_in": 3600])
            }
            defer { SessionManagerURLProtocol.uninstall(host: "login.nvidia.com") }

            let refresher = DetachedSessionRefresher(modelContext: fixture.container.mainContext)
            #expect(await refresher.refresh(account: fixture.detachedAccount, session: fixture.detachedSession))
            let expected = GFNTokenStore.Tokens(accessToken: "fresh-owner-access", idToken: "fresh-owner-id", refreshToken: "fresh-owner-refresh", clientToken: "fresh-owner-client")
            #expect(fixture.tokens(for: fixture.detachedSession) == expected)
            #expect(GFNTokenStore.load(forIdentity: "session.\(fixture.detachedSessionID)") == expected)
            #expect(fixture.tokens(for: fixture.mainSession) == mainTokens)
            #expect(!fixture.detachedAccount.isActive && !fixture.detachedSession.isActive)
            #expect(fixture.login.activeSession === fixture.mainSession)
            #expect(SessionManagerURLProtocol.recordedRequests(host: "login.nvidia.com").map { $0.url?.path } == ["/token", "/token", "/client_token"])
        }
    }

    private func invalidate(_ invalidation: Invalidation, fixture: DetachedAccountTestFixture) async throws {
        let context = fixture.container.mainContext
        switch invalidation {
        case .purge:
            fixture.detachedSession.purgeTokens()
        case .signOut:
            await fixture.login.signOutAccount(fixture.detachedAccount)
        case .forget:
            fixture.login.forgetAccount(fixture.detachedAccount)
        case .deleteSession:
            context.delete(fixture.detachedSession)
        case .replaceSession:
            context.delete(fixture.detachedSession)
            try context.save()
            _ = try fixture.insertReplacementSession()
        case .replaceSessionUsingOriginalID:
            context.delete(fixture.detachedSession)
            try context.save()
            _ = try fixture.insertReplacementSession(id: fixture.detachedSessionID)
        case .deleteAccount:
            context.delete(fixture.detachedAccount)
        case .replaceAccount:
            let userID = fixture.detachedAccount.userId
            context.delete(fixture.detachedAccount)
            try context.save()
            context.insert(makeLoginAccountForTesting(email: fixture.detachedEmail, userId: userID, isActive: false))
        case .replaceCredentials:
            fixture.detachedSession.accessToken = "new-login-access"
            fixture.detachedSession.refreshToken = "new-login-refresh"
        }
        try context.save()
    }
}
