import Testing
import Testing
import Foundation
@testable import Jarvis

private struct MockJarvisTransport: JarvisHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://login.nvidia.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

private func jsonBody(_ request: URLRequest) throws -> [String: Any] {
    let data = try #require(request.httpBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func jarvisOperationNamesMatchVendorNames() {
    #expect(Jarvis.systemName == "Jarvis")
    #expect(Jarvis.Operation.getLoginToken.rawValue == "JARVIS_Get_Login_Token")
    #expect(Jarvis.Operation.getPin.rawValue == "JARVIS_Get_Pin")
    #expect(Jarvis.Operation.getSessionToken.rawValue == "JARVIS_Get_Session_Token")
    #expect(Jarvis.Operation.setPin.rawValue == "JARVIS_Set_Pin")
    #expect(Jarvis.Operation.verifyPin.rawValue == "JARVIS_Verify_Pin")
    #expect(Jarvis.oauthLoggerName == "jarvis/o-auth")
}

@Test func jarvisBuildsVendorOAuthRequests() throws {
    let state = JarvisOAuthState(codeVerifier: "verifier", codeChallenge: "challenge", state: "state", nonce: "nonce")
    let url = try #require(JarvisOAuthRequestFactory.authorizationURL(deviceId: "device", redirectURI: "http://localhost:2259", locale: "en_US", oauthState: state, providerIdpId: "idp"))
    let text = url.absoluteString
    #expect(text.contains("response_type=code"))
    #expect(text.contains("client_id=ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ"))
    #expect(text.contains("scope=openid%20consent%20email%20tk_client%20age"))
    #expect(text.contains("idp_id=idp"))

    let clientTokenBody = JarvisOAuthRequestFactory.clientTokenGrantBody(clientToken: "client", userId: "user")
    #expect(clientTokenBody.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Aclient_token"))
    #expect(clientTokenBody.contains("client_token=client"))
    #expect(clientTokenBody.contains("sub=user"))
}

@Test func jarvisParsesSessionTokenResponse() {
    let session = JarvisSessionParser.parseTokenResponse([
        "access_token": "access",
        "refresh_token": "refresh",
        "expires_in": 120,
    ])
    #expect(session.isAuthenticated)
    #expect(session.accessToken == "access")
    #expect(session.refreshToken == "refresh")
    #expect(session.idpId == Jarvis.defaultIdpId)
    #expect(session.accessTokenExpiry > JarvisSession.currentEpochMs())
}

@Test func jarvisClientTokenRefreshPolicyIsSelfContained() {
    let policy = JarvisClientTokenRefreshPolicy(fixedWindowMs: 300_000, percentageWindow: 20)
    #expect(policy.shouldRefresh(clientToken: "", clientTokenExpiry: 0, clientTokenExpiryLength: 0, currentEpochMs: 1_000))
    #expect(policy.shouldRefresh(clientToken: "client", clientTokenExpiry: 1_050, clientTokenExpiryLength: 1_000, currentEpochMs: 900))
    #expect(!policy.shouldRefresh(clientToken: "client", clientTokenExpiry: 1_500, clientTokenExpiryLength: 1_000, currentEpochMs: 900))
}

@Test func jarvisAuthServiceExchangesCodeAndRefreshesClientToken() async throws {
    let service = JarvisAuthService(transport: MockJarvisTransport { request in
        if request.url?.absoluteString == "https://login.nvidia.com/token" {
            return ["access_token": "access", "refresh_token": "refresh", "expires_in": 120]
        }
        if request.url?.absoluteString == "https://login.nvidia.com/client_token" {
            return ["client_token": "client", "expires_in": 240]
        }
        return [:]
    })
    let session = try await service.exchangeAuthorizationCode(authCode: "code", redirectURI: "http://localhost:2259", codeVerifier: "verifier", providerIdpId: "idp")
    #expect(session.accessToken == "access")
    #expect(session.refreshToken == "refresh")
    #expect(session.clientToken == "client")
    #expect(session.idpId == "idp")
    #expect(await service.status == .loggedIn)
}

@Test func jarvisAuthServiceFetchesCurrentUser() async throws {
    let initial = JarvisSession(
        accessToken: "access",
        userId: "user",
        idpId: "idp",
        expiresAt: Int64(Date().timeIntervalSince1970) + 120,
        isAuthenticated: true,
        clientToken: "client",
        clientTokenExpiry: JarvisSession.currentEpochMs() + 600_000,
        clientTokenExpiryLength: 600_000,
        accessTokenExpiry: JarvisSession.currentEpochMs() + 600_000
    )
    let service = JarvisAuthService(transport: MockJarvisTransport { request in
        #expect(request.url?.absoluteString == "https://login.nvidia.com/userinfo")
        return ["sub": "user", "name": "GFN User", "email": "user@example.com", "idp_id": "idp"]
    }, session: initial)
    let user = try await service.getCurrentUser()
    #expect(user.userId == "user")
    #expect(user.displayName == "GFN User")
    #expect(user.isAuthenticated)
}

@Test func jarvisOAuthCallbackValidationMatchesVendorStateFlow() async throws {
    let service = JarvisAuthService(transport: MockJarvisTransport { _ in [:] })
    let callback = try await service.parseCallback(query: "code=abc&state=expected", expectedState: "expected")
    #expect(callback.code == "abc")
    await #expect(throws: JarvisAuthError.stateMismatch) {
        _ = try await service.parseCallback(query: "code=abc&state=wrong", expectedState: "expected")
    }
}

@Test func jarvisOperationFactoryBuildsVendorOperationDescriptors() {
    #expect(JarvisOperationFactory.getDelegateToken(userId: "user").operation == .getDelegateToken)
    #expect(JarvisOperationFactory.redeemDelegateToken(delegateToken: "delegate").parameters["delegateToken"] == "delegate")
    #expect(JarvisOperationFactory.verifyPin(pin: "1234").operation == .verifyPin)
    #expect(JarvisOperationFactory.requestEmailVerify(email: "user@example.com").parameters["email"] == "user@example.com")
}

@Test func jarvisOperationRequestBuildsVendorCommandEnvelope() throws {
    let request = try #require(JarvisOAuthRequestFactory.operationRequest(
        operation: .getDelegateToken,
        accessToken: "access",
        parameters: ["userId": "user"],
        configuration: JarvisOAuthConfiguration(operationURLString: "https://login.nvidia.com/jarvis")
    ))
    let body = try jsonBody(request)
    let parameters = try #require(body["parameters"] as? [String: String])
    #expect(request.url?.absoluteString == "https://login.nvidia.com/jarvis")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(body["operation"] as? String == Jarvis.Operation.getDelegateToken.rawValue)
    #expect(parameters["userId"] == "user")
}

@Test func jarvisAuthServiceExecutesDelegateProviderPinAndEmailOperations() async throws {
    let configuration = JarvisOAuthConfiguration(operationURLString: "https://login.nvidia.com/jarvis")
    let initial = JarvisSession(
        accessToken: "access",
        userId: "user",
        idpId: "idp",
        expiresAt: Int64(Date().timeIntervalSince1970) + 120,
        isAuthenticated: true,
        clientToken: "client",
        clientTokenExpiry: JarvisSession.currentEpochMs() + 600_000,
        clientTokenExpiryLength: 600_000,
        accessTokenExpiry: JarvisSession.currentEpochMs() + 600_000
    )
    let service = JarvisAuthService(configuration: configuration, transport: MockJarvisTransport { request in
        #expect(request.url?.absoluteString == "https://login.nvidia.com/jarvis")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        let body = try jsonBody(request)
        let operation = try #require(body["operation"] as? String)
        switch operation {
        case Jarvis.Operation.getDelegateToken.rawValue:
            return ["delegate_token": "delegate", "user_id": "user", "expires_in": 60]
        case Jarvis.Operation.redeemDelegateToken.rawValue:
            return ["userInfo": ["sub": "user", "name": "GFN User", "email": "user@example.com", "idp_id": "idp"]]
        case Jarvis.Operation.getThirdPartyProviderInfo.rawValue:
            return ["serviceEndpoint": ["idpId": "idp", "loginProvider": "nvidia", "loginProviderCode": "NV", "loginRequired": true, "loginPreferredProviders": ["nvidia", "steam"], "isAffiliate": true]]
        case Jarvis.Operation.requestEmailVerify.rawValue:
            return ["emailVerification": ["email": "user@example.com", "requested": true, "status": "SENT"]]
        case Jarvis.Operation.getPin.rawValue:
            return ["pin": ["isSet": true, "isVerified": false, "attemptsRemaining": 3, "challengeId": "challenge"]]
        case Jarvis.Operation.setPin.rawValue:
            return ["pin": ["isSet": true, "isVerified": true, "attemptsRemaining": 3]]
        case Jarvis.Operation.verifyPin.rawValue:
            return ["pin": ["isSet": true, "isVerified": true, "attemptsRemaining": 2]]
        default:
            return [:]
        }
    }, session: initial)

    let delegate = try await service.getDelegateToken(userId: "user")
    #expect(delegate.token == "delegate")
    #expect(delegate.expiresIn == "60")

    let redeemed = try await service.redeemDelegateToken("delegate")
    #expect(redeemed.userId == "user")
    #expect(redeemed.displayName == "GFN User")

    let provider = try await service.getThirdPartyProviderInfo(idpId: "idp")
    #expect(provider.loginProvider == "nvidia")
    #expect(provider.loginRequired)
    #expect(provider.preferredProviders == ["nvidia", "steam"])
    #expect(provider.isAffiliate)

    let email = try await service.requestEmailVerify(email: "user@example.com")
    #expect(email.requested)
    #expect(email.status == "SENT")

    let currentPin = try await service.getPin(userId: "user")
    #expect(currentPin.isSet)
    #expect(!currentPin.isVerified)
    #expect(currentPin.challengeId == "challenge")

    let setPin = try await service.setPin("1234")
    #expect(setPin.isVerified)

    let verifiedPin = try await service.verifyPin("1234")
    #expect(verifiedPin.isVerified)
    #expect(verifiedPin.attemptsRemaining == 2)
}

@Test func jarvisAuthServiceChainsSessionThroughOperationEndpoint() async throws {
    let configuration = JarvisOAuthConfiguration(operationURLString: "https://login.nvidia.com/jarvis")
    let initial = JarvisSession(
        accessToken: "access",
        userId: "old-user",
        isAuthenticated: true,
        clientToken: "client",
        clientTokenExpiry: JarvisSession.currentEpochMs() + 600_000,
        clientTokenExpiryLength: 600_000,
        accessTokenExpiry: JarvisSession.currentEpochMs() + 600_000
    )
    let service = JarvisAuthService(configuration: configuration, transport: MockJarvisTransport { request in
        let body = try jsonBody(request)
        #expect(body["operation"] as? String == Jarvis.Operation.chainSession.rawValue)
        return ["session": ["access_token": "new-access", "refresh_token": "new-refresh", "expires_in": 300]]
    }, session: initial)
    let chained = try await service.chainSession(sessionId: "session")
    #expect(chained.accessToken == "new-access")
    #expect(chained.refreshToken == "new-refresh")
    #expect(await service.status == .loggedIn)
}
