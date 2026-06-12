import Testing
import Testing
@testable import Jarvis

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
