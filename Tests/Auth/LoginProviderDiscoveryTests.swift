import Foundation
import Testing
@testable import OpenNOW

private final class FakeLoginAuthService: LoginAuthServing, @unchecked Sendable {
    let outcome: (Bool, String)

    init(outcome: (Bool, String)) {
        self.outcome = outcome
    }

    func endSavedSession(userId: String, email: String) {}

    func invalidatePendingAuthentication() {}

    func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback) {
        let outcome = self.outcome
        Task { @MainActor in completion(outcome.0, OPNAuthSession(), outcome.1) }
    }

    func startStarfleetDeviceCodeLogin(providerIdpId: String, challengeHandler: @escaping OPNDeviceCodeChallengeCallback, completion: @escaping OPNAuthCallback) {
        let outcome = self.outcome
        Task { @MainActor in completion(outcome.0, OPNAuthSession(), outcome.1) }
    }
}

private final class FakeGameProviderInfoService: GameProviderInfoServing, @unchecked Sendable {
    let info: OPNGameProviderInfo

    init(info: OPNGameProviderInfo) {
        self.info = info
    }

    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        let endpoint = OPNGameService.shared.selectGameProviderEndpoint(info, idpId: idpId)
        Task { @MainActor in completion(true, info, endpoint, "") }
    }
}

/// Records which provider lookups a test actually issued. The picker's data is the whole point of
/// the gate this file covers, so a call count is the assertion, not the resulting list.
private final class CountingGameProviderInfoService: GameProviderInfoServing, @unchecked Sendable {
    private(set) var requestedIdpIds: [String] = []

    func fetchProviderInfo(idpId: String, completion: @escaping OPNProviderInfoCallback) {
        requestedIdpIds.append(idpId)
        Task { @MainActor in completion(true, OPNGameProviderInfo(), OPNGameProviderEndpoint(), "") }
    }
}

private func makeActiveSession(email: String = "player@example.com") -> LoginSession {
    LoginSession(
        id: "session-\(email)",
        accountEmail: email,
        authMethod: "getSessionToken",
        accessToken: "access",
        clientToken: "client",
        idToken: "id",
        refreshToken: "refresh",
        userId: "user",
        idpId: LoginProvider.nvidia.idpId,
        deviceId: "device",
        expiresAt: Date(timeIntervalSinceNow: 3600),
        clientTokenExpiresAt: Date(timeIntervalSinceNow: 3600)
    )
}

private func makeExpiredSession() -> LoginSession {
    LoginSession(
        id: "expired-session",
        accountEmail: "player@example.com",
        authMethod: "getSessionToken",
        accessToken: "access",
        clientToken: "client",
        idToken: "id",
        deviceId: "device",
        expiresAt: Date(timeIntervalSinceNow: -3600),
        clientTokenExpiresAt: Date(timeIntervalSinceNow: -3600),
        canContinueOffline: false
    )
}

@MainActor
@Test func providerDiscoveryUsesInjectedService() async throws {
    var digevo = OPNGameProviderEndpoint()
    digevo.loginProvider = "Digevo"
    digevo.loginProviderCode = "DIG"
    digevo.loginProviderDisplayName = "Digevo"
    digevo.streamingServiceUrl = "https://prod.DIG.geforcenow.nvidiagrid.net/"
    digevo.idpId = "digevo-idp"
    digevo.priority = 10

    var nvidia = OPNGameProviderEndpoint()
    nvidia.loginProvider = "NVIDIA"
    nvidia.loginProviderCode = "NVIDIA"
    nvidia.loginProviderDisplayName = "NVIDIA"
    nvidia.streamingServiceUrl = "https://prod.cloudmatchbeta.nvidiagrid.net/"
    nvidia.idpId = "nvidia-idp"
    nvidia.priority = 1

    var info = OPNGameProviderInfo()
    info.defaultProvider = "NVIDIA"
    info.loggedInProvider = "NVIDIA"
    info.loginPreferredProviders = ["NVIDIA"]
    info.endpoints = [nvidia, digevo]

    let viewModel = LoginViewModel(providerInfoService: FakeGameProviderInfoService(info: info))
    #expect(viewModel.providers.map(\.idpId) == [LoginProvider.nvidia.idpId])

    viewModel.bootstrap()
    try await Task.sleep(for: .milliseconds(100))

    #expect(viewModel.providers.count == 2)
    #expect(viewModel.providers.contains { $0.idpId == "digevo-idp" && $0.title == "Digevo" })
    #expect(viewModel.isLoadingProviders == false)
}

/// A restored session lands straight in the catalog, where the picker is unreachable.
@MainActor
@Test func aRestoredSessionLaunchIssuesNoProviderLookup() async throws {
    let service = CountingGameProviderInfoService()
    let viewModel = LoginViewModel(providerInfoService: service)
    viewModel.sessions = [makeActiveSession()]

    viewModel.bootstrap()
    try await Task.sleep(for: .milliseconds(50))

    #expect(viewModel.activeSession != nil)
    #expect(service.requestedIdpIds.isEmpty)
}

/// No session and an expired one both land on the login wall, which renders the picker.
@MainActor
@Test(arguments: [false, true])
func aLaunchWithoutUsableSessionDiscoversProviders(isSessionExpired: Bool) async throws {
    let service = CountingGameProviderInfoService()
    let viewModel = LoginViewModel(providerInfoService: service)
    viewModel.sessions = isSessionExpired ? [makeExpiredSession()] : []

    viewModel.bootstrap()
    try await Task.sleep(for: .milliseconds(50))

    #expect(viewModel.activeSession == nil)
    #expect(service.requestedIdpIds == [LoginProvider.nvidia.idpId])
}

/// ADD ACCOUNT opens the sign-in panel over a restored session, so the panel loads the list.
@MainActor
@Test func addingAnAccountMidSessionDiscoversProviders() async throws {
    let service = CountingGameProviderInfoService()
    let viewModel = LoginViewModel(providerInfoService: service)
    viewModel.sessions = [makeActiveSession()]
    viewModel.bootstrap()
    try await Task.sleep(for: .milliseconds(50))
    #expect(service.requestedIdpIds.isEmpty)

    viewModel.beginAddAccount()
    try await Task.sleep(for: .milliseconds(50))

    #expect(service.requestedIdpIds == [LoginProvider.nvidia.idpId])
}

/// Signing out uncovers the wall without a relaunch, so the picker loads the region's providers.
@MainActor
@Test func signingOutMidSessionDiscoversProviders() async throws {
    let service = CountingGameProviderInfoService()
    let viewModel = LoginViewModel(authService: FakeLoginAuthService(outcome: (true, "")), providerInfoService: service)
    let account = LoginAccount(
        email: "player@example.com",
        displayName: "Player",
        providerIdpId: LoginProvider.nvidia.idpId,
        providerName: LoginProvider.nvidia.title,
        userId: "user",
        isActive: true
    )
    viewModel.accounts = [account]
    viewModel.sessions = [makeActiveSession()]
    viewModel.bootstrap()
    try await Task.sleep(for: .milliseconds(50))
    #expect(service.requestedIdpIds.isEmpty)

    await viewModel.signOutCurrentSession()
    try await Task.sleep(for: .milliseconds(50))

    #expect(viewModel.activeSession == nil)
    #expect(service.requestedIdpIds == [LoginProvider.nvidia.idpId])
}

@MainActor
@Test func oauthFailureSurfacesInjectedServiceError() async throws {
    let viewModel = LoginViewModel(authService: FakeLoginAuthService(outcome: (false, "Injected auth failure")))
    viewModel.acceptedTerms = true

    viewModel.launchOAuth()
    for _ in 0..<200 {
        if viewModel.validationMessage == "Injected auth failure" { break }
        try await Task.sleep(for: .milliseconds(10))
    }

    #expect(viewModel.validationMessage == "Injected auth failure")
    #expect(viewModel.isLaunchingOAuth == false)
}
