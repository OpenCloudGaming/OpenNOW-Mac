//  The service-provider list the sign-in picker renders, and the option lookup the account and
//  session rows are labelled from.
//

import Foundation

extension LoginViewModel {
    /// Loads the provider list the sign-in picker renders. The picker is the list's only reader, so
    /// nothing loads it until a session-less launch or a sign-in panel needs it.
    func refreshLoginProviders() {
        guard !isLoadingProviders else { return }
        isLoadingProviders = true
        let requestedProviderIdpId = selectedProvider.idpId
        providerInfoService.fetchProviderInfo(idpId: requestedProviderIdpId) { [weak self] success, info, _, error in
            guard let self else { return }
            self.isLoadingProviders = false
            guard success else {
                OPNLog.warning(.auth, "Provider discovery failed: \(error)")
                return
            }
            self.applyProviderInfo(info)
        }
    }

    private func applyProviderInfo(_ info: OPNGameProviderInfo) {
        let discoveredProviders = Self.providerOptions(from: info)
        guard !discoveredProviders.isEmpty else { return }

        let previousProviderIdpId = selectedProvider.idpId
        providers = discoveredProviders
        if let existingProvider = providerOptionIfAvailable(idpId: previousProviderIdpId) {
            selectedProvider = existingProvider
        } else if let preferredProvider = Self.preferredProvider(in: discoveredProviders, info: info) {
            selectedProvider = preferredProvider
        } else {
            selectedProvider = discoveredProviders[0]
        }
    }

    func providerOption(idpId: String, fallbackName: String = "") -> LoginProvider {
        if let provider = providerOptionIfAvailable(idpId: idpId) { return provider }
        if idpId.isEmpty || idpId == Jarvis.defaultIdpId { return .nvidia }
        let title = fallbackName.trimmed.isEmpty ? "Provider" : fallbackName.trimmed
        return LoginProvider(idpId: idpId, title: title, loginProvider: title, loginProviderCode: title, streamingServiceUrl: "")
    }

    private func providerOptionIfAvailable(idpId: String) -> LoginProvider? {
        guard !idpId.isEmpty else { return nil }
        return providers.first { $0.idpId == idpId }
    }

    private static func providerOptions(from info: OPNGameProviderInfo) -> [LoginProvider] {
        var seenIdpIds = Set<String>()
        let options = info.endpoints.compactMap { endpoint -> LoginProvider? in
            guard !endpoint.idpId.isEmpty, seenIdpIds.insert(endpoint.idpId).inserted else { return nil }
            return LoginProvider(endpoint: endpoint)
        }
        return options.isEmpty ? [.nvidia] : options
    }

    private static func preferredProvider(in providers: [LoginProvider], info: OPNGameProviderInfo) -> LoginProvider? {
        if info.loginPreferredProviders.count == 1,
           let provider = provider(matching: info.loginPreferredProviders[0], in: providers) {
            return provider
        }
        if let provider = provider(matching: info.loggedInProvider, in: providers) { return provider }
        if let provider = provider(matching: info.defaultProvider, in: providers) { return provider }
        return nil
    }

    private static func provider(matching vendorName: String, in providers: [LoginProvider]) -> LoginProvider? {
        let normalized = vendorName.trimmed.lowercased()
        guard !normalized.isEmpty else { return nil }
        return providers.first { provider in
            provider.loginProvider.lowercased() == normalized ||
            provider.loginProviderCode.lowercased() == normalized ||
            provider.title.lowercased() == normalized
        }
    }
}
