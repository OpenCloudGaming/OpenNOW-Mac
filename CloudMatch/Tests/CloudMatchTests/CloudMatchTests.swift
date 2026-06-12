import Foundation
import Testing
@testable import CloudMatch

private struct MockCloudMatchTransport: CloudMatchHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://prod.cloudmatchbeta.nvidiagrid.net")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Test func cloudMatchVendorEndpointsMatchEvidence() throws {
    #expect(CloudMatch.systemName == "CloudMatch")
    #expect(CloudMatch.productionBaseURLString == "https://prod.cloudmatchbeta.nvidiagrid.net")
    #expect(CloudMatch.Endpoint.serviceUrls.path == "/v1/serviceUrls")
    #expect(CloudMatch.Endpoint.serverInfo.path == "/v2/serverInfo")
    #expect(CloudMatch.Endpoint.networkTestSession.path == "/v2/nettestsession")
    #expect(CloudMatch.Endpoint.subscriptions.path == "/v4/subscriptions")
    #expect(CloudMatch.Endpoint.serviceUrls.cachePolicy.maxAgeSeconds == 1_209_600)
    #expect(CloudMatch.Endpoint.subscriptions.cachePolicy.flushCacheOnResponseCodes == [404])
    #expect(CloudMatch.Endpoint.subscriptions.cachePolicy.shouldFlush(responseStatusCode: 404))
    #expect(CloudMatch.Endpoint.serviceUrls.cachePolicy.isExpired(cachedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 1_209_600)))
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

@Test func cloudMatchClearsUnavailableRouteOverrides() {
    let available = CloudMatchZone(name: "np-sjc-01", address: "sjc.cloudmatch.example")
    let unavailable = CloudMatchRouteOverride(zone: CloudMatchZone(name: "np-removed", address: "removed.example"))
    let internalOverride = CloudMatchRouteOverride(zone: CloudMatchZone(name: "internal", address: "internal.example"), isInternal: true)
    let serverInfo = CloudMatchServerInfo(zones: [available.address: available], defaultZone: available)
    #expect(CloudMatchRoutingPolicy.decision(serverInfo: serverInfo, override: nil) == .useDefault(available))
    #expect(CloudMatchRoutingPolicy.decision(serverInfo: serverInfo, override: CloudMatchRouteOverride(zone: available)) == .useOverride(CloudMatchRouteOverride(zone: available)))
    #expect(CloudMatchRoutingPolicy.decision(serverInfo: serverInfo, override: unavailable) == .clearUnavailableOverride(unavailable))
    #expect(CloudMatchRoutingPolicy.decision(serverInfo: serverInfo, override: internalOverride) == .useOverride(internalOverride))
}

@Test func cloudMatchServiceFetchesServerInfoAndSubscriptions() async throws {
    let service = CloudMatchService(transport: MockCloudMatchTransport { request in
        if request.url?.path == "/v2/serverInfo" {
            return [
                "vpcId": "vpc",
                "serverType": "prod",
                "metadata": [
                    ["key": "gfn-regions", "value": "np-sjc-01"],
                    ["key": "np-sjc-01", "value": "sjc.cloudmatch.example"],
                ],
            ]
        }
        #expect(request.url?.path == "/v4/subscriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
        return ["subscriptions": [["id": "sub"]]]
    })
    let serverInfo = try await service.fetchServerInfo()
    #expect(serverInfo.zones["sjc.cloudmatch.example"]?.name == "np-sjc-01")
    let subscriptions = try await service.fetchSubscriptions(accessToken: "access")
    let items = try #require(subscriptions["subscriptions"] as? [[String: Any]])
    #expect(items.first?["id"] as? String == "sub")
}
