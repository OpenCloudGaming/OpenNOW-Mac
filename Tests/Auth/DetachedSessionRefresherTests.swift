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
