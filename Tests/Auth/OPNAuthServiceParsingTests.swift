import Testing
import Foundation
@testable import OpenNOW

private func makeIdToken(claims: [String: Any]) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: claims)
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "header.\(encoded).signature"
}

@Test func parseQueryStringDecodesPercentEncodingAndSkipsMalformedPairs() {
    let params = OPNAuthService.parseQueryString("code=abc%20123&state=xyz&novalue&redirect_uri=https%3A%2F%2Fexample.test%2Fcb")

    #expect(params["code"] as? String == "abc 123")
    #expect(params["state"] as? String == "xyz")
    #expect(params["redirect_uri"] as? String == "https://example.test/cb")
    #expect(params["novalue"] == nil)
    #expect(params.count == 3)
}

@Test func parseQueryStringIsEmptyForNilAndEmptyInput() {
    #expect(OPNAuthService.parseQueryString(nil).count == 0)
    #expect(OPNAuthService.parseQueryString("").count == 0)
}

@Test func parseQueryStringKeepsOnlyTheValueBeforeAnAmpersand() {
    let params = OPNAuthService.parseQueryString("token=a=b&next=c")

    #expect(params["token"] as? String == "a=b")
    #expect(params["next"] as? String == "c")
}

@Test func parseOAuthSessionMapsTokensAndClaims() {
    let idToken = makeIdToken(claims: ["sub": "user-42", "email": "player@example.test", "membership_tier": "PRIORITY"])
    let json: NSDictionary = [
        "access_token": "access-value",
        "id_token": idToken,
        "refresh_token": "refresh-value",
        "client_token": "client-value",
        "expires_in": 3600,
        "client_token_expires_in": 7200
    ]

    let session = OPNAuthService.parseOAuthSession(json: json)

    #expect(session.accessToken == "access-value")
    #expect(session.idToken == idToken)
    #expect(session.refreshToken == "refresh-value")
    #expect(session.clientToken == "client-value")
    #expect(session.userId == "user-42")
    #expect(session.membershipTier == "PRIORITY")
    #expect(session.isAuthenticated == true)
    #expect(session.expiresAt > 0)
}

@Test func parseOAuthSessionDefaultsMembershipTierToFreeWhenTheClaimIsAbsent() {
    let idToken = makeIdToken(claims: ["sub": "user-1"])
    let session = OPNAuthService.parseOAuthSession(json: ["access_token": "a", "id_token": idToken])

    #expect(session.membershipTier == "Free")
    #expect(session.userId == "user-1")
}

@Test func parseOAuthSessionLeavesMembershipTierEmptyWithoutAnIdToken() {
    let session = OPNAuthService.parseOAuthSession(json: ["access_token": "a"])

    #expect(session.membershipTier == "")
    #expect(session.userId == "")
}

@Test func parseOAuthSessionSurvivesAnUnparseableIdToken() {
    let session = OPNAuthService.parseOAuthSession(json: ["access_token": "a", "id_token": "not-a-jwt"])

    #expect(session.accessToken == "a")
    #expect(session.userId == "")
    #expect(session.membershipTier == "Free")
}

@Test func parseOAuthSessionIsEmptyForAnEmptyPayload() {
    let session = OPNAuthService.parseOAuthSession(json: [:])

    #expect(session.accessToken == "")
    #expect(session.idToken == "")
    #expect(session.refreshToken == "")
}

@Test func persistentDeviceUUIDIsStableAcrossCalls() {
    let first = OPNAuthService.getPersistentDeviceUUID()
    let second = OPNAuthService.getPersistentDeviceUUID()

    #expect(!first.isEmpty)
    #expect(first == second)
    #expect(UUID(uuidString: first) != nil)
}
