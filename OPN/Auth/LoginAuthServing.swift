import Foundation

protocol LoginAuthServing {
    func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback)
    func startStarfleetDeviceCodeLogin(providerIdpId: String, challengeHandler: @escaping OPNDeviceCodeChallengeCallback, completion: @escaping OPNAuthCallback)
}

extension OPNAuthService: LoginAuthServing {}
