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

@Test func jarvisOperationNamesMatchVendorNames() {
    #expect(Jarvis.systemName == "Jarvis")
    #expect(Jarvis.Operation.getLoginToken.rawValue == "JARVIS_Get_Login_Token")
    #expect(Jarvis.Operation.getSessionToken.rawValue == "JARVIS_Get_Session_Token")
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
