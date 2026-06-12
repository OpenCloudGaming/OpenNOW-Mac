import Testing
@testable import CloudMatch

@Test func cloudMatchVendorEndpointsMatchEvidence() throws {
    #expect(CloudMatch.systemName == "CloudMatch")
    #expect(CloudMatch.productionBaseURLString == "https://prod.cloudmatchbeta.nvidiagrid.net")
    #expect(CloudMatch.Endpoint.serviceUrls.path == "/v1/serviceUrls")
    #expect(CloudMatch.Endpoint.serverInfo.path == "/v2/serverInfo")
    #expect(CloudMatch.Endpoint.networkTestSession.path == "/v2/nettestsession")
    #expect(CloudMatch.Endpoint.subscriptions.path == "/v4/subscriptions")
    #expect(CloudMatch.Endpoint.serviceUrls.cachePolicy.maxAgeSeconds == 1_209_600)
    #expect(CloudMatch.Endpoint.subscriptions.cachePolicy.flushCacheOnResponseCodes == [404])
}

@Test func cloudMatchBuildsAuthenticatedRequests() throws {
    let request = try #require(CloudMatchRequestFactory.request(endpoint: .serverInfo, accessToken: "access", queryItems: [.init(name: "locale", value: "en_US")]))
    #expect(request.url?.absoluteString == "https://prod.cloudmatchbeta.nvidiagrid.net/v2/serverInfo?locale=en_US")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
}

@Test func cloudMatchParsesVendorServerInfoMetadata() {
    let info = CloudMatchServerInfoParser.parse([
        "vpcId": "vpc",
        "serverType": "prod",
        "metadata": [
            ["key": "gfn-regions", "value": "np-sjc-01, np-lax-01"],
            ["key": "np-sjc-01", "value": "https://sjc.cloudmatch.example/"],
            ["key": "np-lax-01", "value": "lax.cloudmatch.example"],
            ["key": "local-region", "value": "https://sjc.cloudmatch.example/"],
        ],
    ])
    #expect(info.vpcId == "vpc")
    #expect(info.serverType == "prod")
    #expect(info.zones["sjc.cloudmatch.example"]?.name == "np-sjc-01")
    #expect(info.detectedLocalZone?.address == "sjc.cloudmatch.example")
}
