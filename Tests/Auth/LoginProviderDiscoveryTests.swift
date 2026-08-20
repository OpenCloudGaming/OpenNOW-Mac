import Foundation
import Testing
@testable import MacForceNow

private final class FakeLoginAuthService: LoginAuthServing, @unchecked Sendable {
    let outcome: (Bool, String)

    init(outcome: (Bool, String)) {
        self.outcome = outcome
    }

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
