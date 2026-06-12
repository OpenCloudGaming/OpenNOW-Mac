import Testing
import Foundation
import Testing
@testable import Starfleet

@Test func starfleetEndpointNamesMatchVendorBackend() {
    #expect(Starfleet.systemName == "Starfleet")
    #expect(Starfleet.Endpoint.token.urlString == "https://login.nvidia.com/token")
    #expect(Starfleet.Endpoint.clientToken.urlString == "https://login.nvidia.com/client_token")
    #expect(Starfleet.GrantType.clientToken.rawValue == "urn:ietf:params:oauth:grant-type:client_token")
}

@Test func starfleetBuildsTokenGrantRequests() throws {
    let body = StarfleetOAuthRequestFactory.clientTokenGrantBody(clientToken: "client", userId: "user")
    #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Aclient_token"))
    #expect(body.contains("client_token=client"))
    #expect(body.contains("sub=user"))

    let request = try #require(StarfleetOAuthRequestFactory.tokenRequest(body: body))
    #expect(request.url?.absoluteString == "https://login.nvidia.com/token")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Origin") == "https://nvfile")
    #expect(request.value(forHTTPHeaderField: "Referer") == "https://nvfile/")
}

@Test func starfleetParsesTokenResponseExpiry() {
    let issuedAt = Date(timeIntervalSince1970: 1_000)
    let response = StarfleetTokenParser.parseTokenResponse([
        "access_token": "access",
        "id_token": "id",
        "refresh_token": "refresh",
        "client_token": "client",
        "expires_in": 120,
        "client_token_expires_in": 240,
    ], issuedAt: issuedAt)
    #expect(response.tokenSet.accessToken == "access")
    #expect(response.tokenSet.clientToken == "client")
    #expect(response.accessTokenExpiryMs == 1_120_000)
    #expect(response.clientTokenExpiryMs == 1_240_000)
    #expect(response.clientTokenExpiryLengthMs == 240_000)
}

@Test func starfleetClientTokenRefreshPolicyMatchesGFNWindow() {
    let policy = StarfleetClientTokenRefreshPolicy(fixedWindowMs: 300_000, percentageWindow: 20)
    #expect(policy.shouldRefresh(clientToken: "", clientTokenExpiry: 0, clientTokenExpiryLength: 0, currentEpochMs: 1_000))
    #expect(policy.shouldRefresh(clientToken: "client", clientTokenExpiry: 1_050, clientTokenExpiryLength: 1_000, currentEpochMs: 900))
    #expect(!policy.shouldRefresh(clientToken: "client", clientTokenExpiry: 1_500, clientTokenExpiryLength: 1_000, currentEpochMs: 900))
}
