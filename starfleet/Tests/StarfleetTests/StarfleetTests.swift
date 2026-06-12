import Testing
import Foundation
@testable import Starfleet

private struct MockStarfleetTransport: StarfleetHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://login.nvidia.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

private actor SequencedStarfleetTransport: StarfleetHTTPTransport {
    private var responses: [Result<(status: Int, json: [String: Any]), Error>]
    private var count = 0

    var requestCount: Int { count }

    init(_ responses: [Result<(status: Int, json: [String: Any]), Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        count += 1
        let response = responses.isEmpty ? .success((status: 200, json: [:])) : responses.removeFirst()
        switch response {
        case .success(let payload):
            let data = try JSONSerialization.data(withJSONObject: payload.json)
            let http = HTTPURLResponse(url: request.url ?? URL(string: "https://login.nvidia.com")!, statusCode: payload.status, httpVersion: nil, headerFields: nil)!
            return (data, http)
        case .failure(let error):
            throw error
        }
    }
}

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

@Test func starfleetAuthErrorClassifiesRetryConditions() {
    #expect(StarfleetAuthError.httpStatus(401).category == .authorization)
    #expect(StarfleetAuthError.httpStatus(408).category == .timeout)
    #expect(StarfleetAuthError.httpStatus(429).category == .rateLimited)
    #expect(StarfleetAuthError.httpStatus(503).category == .unavailable)
    #expect(StarfleetAuthError.transportFailure(URLError(.notConnectedToInternet)).category == .offline)
    #expect(StarfleetAuthError.transportFailure(URLError(.timedOut)).category == .timeout)
    #expect(StarfleetRetryPolicy(maxRetries: 1, baseDelayMs: 0).shouldRetry(.httpStatus(503), attempt: 0))
    #expect(!StarfleetRetryPolicy(maxRetries: 1, baseDelayMs: 0).shouldRetry(.httpStatus(401), attempt: 0))
}

@Test func starfleetServiceExchangesCodeAndFetchesClientToken() async throws {
    let service = StarfleetService(transport: MockStarfleetTransport { request in
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
}

@Test func starfleetServiceRefreshesWithClientTokenGrant() async throws {
    let initial = StarfleetSession(
        accessToken: "expired",
        refreshToken: "refresh",
        userId: "user",
        isAuthenticated: true,
        clientToken: "client",
        clientTokenExpiry: StarfleetSession.currentEpochMs() + 600_000,
        clientTokenExpiryLength: 600_000,
        accessTokenExpiry: StarfleetSession.currentEpochMs() - 1_000
    )
    let service = StarfleetService(transport: MockStarfleetTransport { request in
        #expect(request.url?.absoluteString == "https://login.nvidia.com/token")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Aclient_token"))
        return ["access_token": "fresh", "expires_in": 120]
    }, session: initial)

    let refreshed = try await service.refreshSession(force: true)
    #expect(refreshed.accessToken == "fresh")
    #expect(refreshed.refreshToken == "refresh")
    #expect(refreshed.clientToken == "client")
}

@Test func starfleetServiceFetchesCurrentUser() async throws {
    let initial = StarfleetSession(
        accessToken: "access",
        userId: "user",
        idpId: "idp",
        expiresAt: Int64(Date().timeIntervalSince1970) + 120,
        isAuthenticated: true,
        clientToken: "client",
        clientTokenExpiry: StarfleetSession.currentEpochMs() + 600_000,
        clientTokenExpiryLength: 600_000,
        accessTokenExpiry: StarfleetSession.currentEpochMs() + 600_000
    )
    let service = StarfleetService(transport: MockStarfleetTransport { request in
        #expect(request.url?.absoluteString == "https://login.nvidia.com/userinfo")
        return ["sub": "user", "name": "GFN User", "email": "user@example.com", "idp_id": "idp"]
    }, session: initial)

    let user = try await service.getCurrentUser()
    #expect(user.userId == "user")
    #expect(user.displayName == "GFN User")
    #expect(user.isAuthenticated)
}

@Test func starfleetServiceRetriesTransientFailures() async throws {
    let transport = SequencedStarfleetTransport([
        .success((status: 503, json: ["error": "unavailable"])),
        .success((status: 200, json: ["sub": "user", "name": "GFN User", "email": "user@example.com", "idp_id": "idp"])),
    ])
    let service = StarfleetService(retryPolicy: StarfleetRetryPolicy(maxRetries: 1, baseDelayMs: 0), transport: transport)
    let user = try await service.fetchUserInfo(accessToken: "access")
    #expect(user.userId == "user")
    #expect(await transport.requestCount == 2)
}
