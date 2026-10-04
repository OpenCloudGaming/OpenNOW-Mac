//  Sign-out and account removal are refused while the account owns a game this application started.
//
//  These are the mutations themselves, not the controls that reach them: the catalog dropdown, the
//  controller catalog and the menu bar all end up here, and the point of the guard is that a path
//  nobody thought about still cannot pull the credentials out from under a running session.

import Foundation
import SwiftData
import Testing
@testable import OpenNOW

private final class RecordingAccountMutationAuthService: LoginAuthServing, @unchecked Sendable {
    private(set) var endedSessions: [(userId: String, email: String)] = []

    func invalidatePendingAuthentication() {}

    func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback) {
        Task { @MainActor in completion(false, OPNAuthSession(), "Unused by this test") }
    }

    func startStarfleetDeviceCodeLogin(providerIdpId: String, challengeHandler: @escaping OPNDeviceCodeChallengeCallback, completion: @escaping OPNAuthCallback) {
        Task { @MainActor in completion(false, OPNAuthSession(), "Unused by this test") }
    }

    func endSavedSession(userId: String, email: String) {
        endedSessions.append((userId, email))
    }
}

/// Holds the in-memory store for the length of a test. The container has to outlive the helper that
/// built it, or the context it hands out invalidates the models the test is still reading.
@MainActor
private final class GuardFixture {
    let container: ModelContainer
    let viewModel: LoginViewModel
    let registry: OPNGameSessionRegistry
    let authService: RecordingAccountMutationAuthService
    let account: LoginAccount
    let session: LoginSession

    init() throws {
        container = try ModelContainer(
            for: LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
        authService = RecordingAccountMutationAuthService()
        registry = OPNGameSessionRegistry()
        viewModel = LoginViewModel(authService: authService, sessionRegistry: registry)
        viewModel.modelContext = container.mainContext

        account = makeLoginAccountForTesting(email: "player@example.com", displayName: "Player", userId: "user-1")
        session = makeLoginSessionForTesting(accountEmail: account.email, id: "guard-session", userId: "user-1")
        container.mainContext.insert(account)
        container.mainContext.insert(session)
        viewModel.accounts = [account]
        viewModel.sessions = [session]
    }

    /// Occupies the registry with a session owned by the account, without starting a launch. The
    /// launch itself would reach the vendor, and the guard is only about ownership.
    @discardableResult
    func claimGameSession() -> OPNGameSession? {
        registry.begin(
            account: account,
            session: session,
            gameService: OPNGameService.shared,
            launchBridge: OPNGameLaunchBridge.shared,
            discordPresence: DiscordRichPresence.shared,
            streamProfile: OPNStreamPreferenceProfile()
        )
    }

    /// The second saved account every "unrelated account stays mutable" test needs.
    func addSecondAccount() throws -> LoginAccount {
        let other = makeLoginAccountForTesting(email: "other@example.com", displayName: "Other", userId: "user-2", isActive: false)
        let otherSession = makeLoginSessionForTesting(accountEmail: other.email, id: "guard-session-other", userId: "user-2")
        container.mainContext.insert(other)
        container.mainContext.insert(otherSession)
        viewModel.accounts.append(other)
        viewModel.sessions.append(otherSession)
        return other
    }

    func tearDown() {
        for stored in viewModel.sessions {
            stored.purgeTokens()
        }
    }
}

@MainActor
@Test func signOutIsRefusedWhileTheAccountOwnsAGameSession() async throws {
    let fixture = try GuardFixture()
    defer { fixture.tearDown() }
    fixture.claimGameSession()

    await fixture.viewModel.signOutAccount(fixture.account)

    #expect(fixture.viewModel.validationMessage == OPNAccountMutationGuard.activeGameSessionMessage)
    #expect(fixture.viewModel.hasUsableSession(for: fixture.account))
    #expect(fixture.account.isActive)
    #expect(fixture.authService.endedSessions.isEmpty)
}

@MainActor
@Test func accountRemovalIsRefusedWhileTheAccountOwnsAGameSession() async throws {
    let fixture = try GuardFixture()
    defer { fixture.tearDown() }
    fixture.claimGameSession()

    fixture.viewModel.forgetAccount(fixture.account)

    #expect(fixture.viewModel.validationMessage == OPNAccountMutationGuard.activeGameSessionMessage)
    #expect(fixture.viewModel.accounts.contains { $0.email == fixture.account.email })
    #expect(fixture.viewModel.sessions.contains { $0.accountEmail == fixture.account.email })
    #expect(fixture.viewModel.hasUsableSession(for: fixture.account))
}

/// The refusal is a property of the session, not a latch: once the game ends, the same account
/// signs out normally, credentials and all.
@MainActor
@Test func signOutProceedsOnceTheOwnedSessionHasEnded() async throws {
    let fixture = try GuardFixture()
    defer { fixture.tearDown() }
    let owned = try #require(fixture.claimGameSession())
    await fixture.viewModel.signOutAccount(fixture.account)
    #expect(fixture.authService.endedSessions.isEmpty)

    fixture.registry.end(owned)
    await fixture.viewModel.signOutAccount(fixture.account)

    #expect(!fixture.viewModel.hasUsableSession(for: fixture.account))
    #expect(!fixture.account.isActive)
    #expect(fixture.authService.endedSessions.map(\.email) == [fixture.account.email])
}

/// An unrelated account stays fully mutable while another one is playing. Blocking it too would
/// turn the guard into "you cannot manage accounts while anything is running".
@MainActor
@Test func anUnrelatedAccountCanStillBeSignedOutWhileAnotherOwnsAGameSession() async throws {
    let fixture = try GuardFixture()
    defer { fixture.tearDown() }
    let other = try fixture.addSecondAccount()
    fixture.claimGameSession()

    await fixture.viewModel.signOutAccount(other)

    #expect(!fixture.viewModel.hasUsableSession(for: other))
    #expect(fixture.authService.endedSessions.map(\.email) == [other.email])
    #expect(fixture.registry.isOwned(by: try #require(fixture.account.storedAccountID)))
    #expect(fixture.viewModel.hasUsableSession(for: fixture.account))
}

/// A row written before the identity existed gets one on bootstrap, and the vendor subject it
/// already stored is what it gets.
@MainActor
@Test func bootstrapGivesALegacyRowItsStableIdentity() async throws {
    let fixture = try GuardFixture()
    defer { fixture.tearDown() }
    fixture.account.stableAccountID = ""

    fixture.viewModel.backfillAccountIdentities()

    let resolved = try #require(fixture.account.storedAccountID)
    #expect(resolved.basis == .vendorSubject)
    #expect(resolved.subject == "user-1")
}

/// The upgrade path: a row that never stored a subject keeps a local-only identity, and gains the
/// verified one - with any ownership it held - the first time a sign-in supplies the subject.
@MainActor
@Test func aLocalOnlyIdentityUpgradesOnceTheVendorSubjectArrives() async throws {
    let fixture = try GuardFixture()
    defer { fixture.tearDown() }
    fixture.account.userId = ""
    fixture.account.stableAccountID = ""
    let local = try #require(fixture.account.resolveStableAccountID())
    #expect(local.basis == .localOnly)
    fixture.claimGameSession()
    #expect(fixture.registry.isOwned(by: local))

    fixture.account.userId = "user-1"
    fixture.viewModel.backfillAccountIdentities()

    let verified = try #require(fixture.account.storedAccountID)
    #expect(verified.basis == .vendorSubject)
    #expect(fixture.registry.isOwned(by: verified))
    #expect(!fixture.registry.isOwned(by: local))
    #expect(OPNAccountMutationGuard.blockReason(for: verified, registry: fixture.registry) == OPNAccountMutationGuard.activeGameSessionMessage)
}
