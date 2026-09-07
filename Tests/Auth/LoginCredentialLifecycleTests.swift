import Foundation
import SwiftData
import Testing
@testable import OpenNOW

private final class RecordingLoginAuthService: LoginAuthServing, @unchecked Sendable {
    private(set) var endedSessions: [(userId: String, email: String)] = []
    private(set) var startedProviderIdpIds: [String] = []

    func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback) {
        startedProviderIdpIds.append(providerIdpId)
        Task { @MainActor in completion(false, OPNAuthSession(), "Unused by this test") }
    }

    func startStarfleetDeviceCodeLogin(providerIdpId: String, challengeHandler: @escaping OPNDeviceCodeChallengeCallback, completion: @escaping OPNAuthCallback) {
        Task { @MainActor in completion(false, OPNAuthSession(), "Unused by this test") }
    }

    func endSavedSession(userId: String, email: String) {
        endedSessions.append((userId, email))
    }
}

private func makeSession(id: String, email: String) -> LoginSession {
    LoginSession(
        id: id,
        accountEmail: email,
        authMethod: "getSessionToken",
        accessToken: "access-\(id)",
        clientToken: "client-\(id)",
        idToken: "id-\(id)",
        refreshToken: "refresh-\(id)",
        deviceId: "device",
        expiresAt: Date(timeIntervalSinceNow: 3600),
        clientTokenExpiresAt: Date(timeIntervalSinceNow: 3600)
    )
}

private func makeAccount(email: String, userId: String, isActive: Bool) -> LoginAccount {
    LoginAccount(
        email: email,
        displayName: email,
        providerIdpId: LoginProvider.nvidia.idpId,
        providerName: LoginProvider.nvidia.title,
        userId: userId,
        isActive: isActive
    )
}

/// Sign-in stores every session twice: in SwiftData under the session id, and in the auth service
/// under the profile identity. Signing out has to end both — the auth-service copy carries the same
/// refresh token, which outlives the access token by far, and this view model's own Jarvis session
/// store is a no-op that never reaches it.
@MainActor
@Test func signOutEndsTheAuthServiceCredentialForSignedOutAccountsOnly() async throws {
    let container = try ModelContainer(
        for: LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let authService = RecordingLoginAuthService()
    let viewModel = LoginViewModel(authService: authService)
    viewModel.modelContext = container.mainContext

    let signedOut = makeAccount(email: "active@example.com", userId: "user-active", isActive: true)
    let kept = makeAccount(email: "kept@example.com", userId: "user-kept", isActive: false)
    container.mainContext.insert(signedOut)
    container.mainContext.insert(kept)
    viewModel.accounts = [signedOut, kept]

    await viewModel.signOutCurrentSession()

    #expect(authService.endedSessions.map { $0.email } == ["active@example.com"])
    #expect(authService.endedSessions.map { $0.userId } == ["user-active"])
    #expect(viewModel.accounts.allSatisfy { !$0.isActive })
}

/// Sign-out ends the signed-out account and nothing else. The other saved account has to keep a
/// restorable session, or the login wall has no way back in: `activateAccount` is only reachable
/// from the catalog, which itself only renders once a session is active again.
@MainActor
@Test func signOutKeepsTheOtherSavedAccountRestorable() async throws {
    let container = try ModelContainer(
        for: LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let authService = RecordingLoginAuthService()
    let viewModel = LoginViewModel(authService: authService)
    viewModel.modelContext = container.mainContext

    let signedOut = makeAccount(email: "active@example.com", userId: "user-active", isActive: true)
    let kept = makeAccount(email: "kept@example.com", userId: "user-kept", isActive: false)
    container.mainContext.insert(signedOut)
    container.mainContext.insert(kept)
    let signedOutSession = makeSession(id: "sign-out-restorable-active", email: "active@example.com")
    let keptSession = makeSession(id: "sign-out-restorable-kept", email: "kept@example.com")
    container.mainContext.insert(signedOutSession)
    container.mainContext.insert(keptSession)
    viewModel.accounts = [signedOut, kept]
    viewModel.sessions = [signedOutSession, keptSession]
    defer {
        signedOutSession.purgeTokens()
        keptSession.purgeTokens()
    }

    await viewModel.signOutCurrentSession()

    #expect(!viewModel.hasUsableSession(for: signedOut))
    #expect(viewModel.hasUsableSession(for: kept))
    #expect(viewModel.signedOutAccountEmails == ["active@example.com"])
}

/// The login wall's SIGN IN AGAIN row has to start the browser leg. Routing it through
/// `activateAccount` instead only marked the account pending re-authentication — the right answer
/// from the catalog, which sends the user to this wall, but on the wall itself it changed state and
/// started nothing.
@MainActor
@Test func signInAgainFromTheLoginWallStartsTheBrowserLeg() async throws {
    let container = try ModelContainer(
        for: LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let authService = RecordingLoginAuthService()
    let viewModel = LoginViewModel(authService: authService)
    viewModel.modelContext = container.mainContext

    let signedOut = makeAccount(email: "active@example.com", userId: "user-active", isActive: true)
    container.mainContext.insert(signedOut)
    let session = makeSession(id: "sign-in-again-session", email: "active@example.com")
    container.mainContext.insert(session)
    viewModel.accounts = [signedOut]
    viewModel.sessions = [session]
    defer { session.purgeTokens() }

    await viewModel.signOutCurrentSession()
    #expect(viewModel.signedOutAccountEmails == ["active@example.com"])

    viewModel.acceptedTerms = true
    viewModel.activateSavedAccount(signedOut)

    for _ in 0..<200 {
        if !authService.startedProviderIdpIds.isEmpty { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(authService.startedProviderIdpIds == [signedOut.providerIdpId])
    #expect(viewModel.selectedProvider.idpId == signedOut.providerIdpId)
}

/// Forgetting an account deletes its rows, which is not the same as ending its credential: the auth
/// service still holds the tokens under its own key, and nothing else ever looks them up again.
@MainActor
@Test func forgetAccountEndsTheAuthServiceCredential() throws {
    let container = try ModelContainer(
        for: LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let authService = RecordingLoginAuthService()
    let viewModel = LoginViewModel(authService: authService)
    viewModel.modelContext = container.mainContext

    let forgotten = makeAccount(email: "forgotten@example.com", userId: "user-forgotten", isActive: true)
    container.mainContext.insert(forgotten)
    viewModel.accounts = [forgotten]

    viewModel.forgetAccount(forgotten)

    #expect(authService.endedSessions.map { $0.email } == ["forgotten@example.com"])
    #expect(authService.endedSessions.map { $0.userId } == ["user-forgotten"])
    #expect(viewModel.accounts.isEmpty)
}
