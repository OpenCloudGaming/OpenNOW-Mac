import Foundation

protocol LoginAuthServing {
    func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback)
    func startStarfleetDeviceCodeLogin(providerIdpId: String, challengeHandler: @escaping OPNDeviceCodeChallengeCallback, completion: @escaping OPNAuthCallback)
    /// Ends the credential the auth service holds for one account. Sign-in writes every session
    /// twice — into SwiftData under the session id, and into the auth service under the profile
    /// identity — so ending it has to reach both, or a refresh token outlives the sign-out.
    func endSavedSession(userId: String, email: String)
}

extension OPNAuthService: LoginAuthServing {}
