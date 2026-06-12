import Testing
@testable import CloudMatch

@Test func cloudMatchVendorEndpointsMatchEvidence() throws {
    #expect(CloudMatch.systemName == "CloudMatch")
    #expect(CloudMatch.productionBaseURLString == "https://prod.cloudmatchbeta.nvidiagrid.net")
    #expect(CloudMatch.Endpoint.serviceUrls.path == "/v1/serviceUrls")
    #expect(CloudMatch.Endpoint.serverInfo.path == "/v2/serverInfo")
    #expect(CloudMatch.Endpoint.networkTestSession.path == "/v2/nettestsession")
}

@Test func cloudMatchBuildsAuthenticatedRequests() throws {
    let request = try #require(CloudMatchRequestFactory.request(endpoint: .serverInfo, accessToken: "access", queryItems: [.init(name: "locale", value: "en_US")]))
    #expect(request.url?.absoluteString == "https://prod.cloudmatchbeta.nvidiagrid.net/v2/serverInfo?locale=en_US")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
}
