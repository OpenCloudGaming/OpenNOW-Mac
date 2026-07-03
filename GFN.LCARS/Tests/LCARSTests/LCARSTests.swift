import Foundation
import Testing
@testable import LCARS

private struct MockLCARSTransport: LCARSHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://api.gfn.example/graphql")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Test func lcarsRequestTypesMatchVendorCacheRoutes() {
    #expect(LCARS.systemName == "LCARS")
    #expect(LCARS.productionGraphQLURLString == "https://games.geforce.com/graphql")
    #expect(LCARS.RequestType.panels.rawValue == "panels")
    #expect(LCARS.RequestType.staticAppData.rawValue == "staticAppData")
    #expect(LCARS.RequestType.userAccount.rawValue == "userAccount")
    #expect(LCARS.RequestType.clientStrings.rawValue == "clientStrings")
    #expect(LCARS.RequestType.loginWallData.rawValue == "loginWallData")
    #expect(LCARS.RequestType.loginWallStrings.rawValue == "loginWallStrings")
    #expect(LCARS.RequestType.overallGfnSupportedLanguages.rawValue == "overallGfnSupportedLanguages")
    #expect(LCARS.RequestType.panels.cachePolicy.maxEntries == 10)
    #expect(LCARS.RequestType.staticAppData.cachePolicy.cacheName == "LCARSStatic")
    #expect(LCARS.RequestType.loginWallData.cachePolicy.maxAgeSeconds == 604_800)
    #expect(LCARS.RequestType.overallGfnSupportedLanguages.cachePolicy.maxEntries == 1)
    #expect(LCARS.RequestType.panels.cachePolicy.cacheKey(prefix: "gfn", requestType: .panels) == "gfn-LCARS-panels")
    #expect(LCARS.RequestType.loginWallData.cachePolicy.isExpired(cachedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 604_800)))
}

@Test func lcarsBuildsPersistedGraphQLRequest() throws {
    let configuration = LCARSConfiguration(baseURLString: "https://api.gfn.example", headers: LCARSClientHeaders(clientId: "lcars-client"))
    let request = try #require(LCARSRequestFactory.persistedQueryRequest(operationName: "panels/MainV2", queryHash: "hash", variables: ["locale": "en_US"], accessToken: "access", configuration: configuration, huId: "hu"))
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })

    #expect(components.scheme == "https")
    #expect(components.host == "api.gfn.example")
    #expect(components.path == "/graphql")
    #expect(items["requestType"] == "panels/MainV2")
    #expect(items["huId"] == "hu")
    #expect(items["extensions"]?.contains("sha256Hash") == true)
    #expect(items["extensions"]?.contains("hash") == true)
    #expect(items["variables"]?.contains("en_US") == true)
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/graphql")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
    #expect(request.value(forHTTPHeaderField: "NV-Client-ID") == "lcars-client")
}

@Test func lcarsBuildsInlineGraphQLRequest() throws {
    let configuration = LCARSConfiguration(baseURLString: "https://api.gfn.example/graphql")
    let query = "query GetUserAccount { userAccount { subscriptions { id } } }"
    let request = try #require(LCARSRequestFactory.inlineGraphQLRequest(query: query, variables: ["locale": "en_US"], accessToken: "access", configuration: configuration))
    #expect(request.url?.absoluteString == "https://api.gfn.example/graphql")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["query"] as? String == query)
    let variables = try #require(json["variables"] as? [String: String])
    #expect(variables["locale"] == "en_US")
}

@Test func lcarsBuildsGraphQLRequestTypes() throws {
    let configuration = LCARSConfiguration(baseURLString: "https://api.gfn.example")
    let request = try #require(LCARSRequestFactory.graphQLRequest(requestType: .panels, accessToken: "access", configuration: configuration))
    #expect(request.url?.absoluteString == "https://api.gfn.example/graphql?requestType=panels")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/graphql")
}

@Test func lcarsMakesDeterministicHuIdForInjectedValues() {
    let uuid = UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!
    #expect(LCARSRequestFactory.makeHuId(date: Date(timeIntervalSince1970: 1), uuid: uuid) == "100012345678")
}

@Test func lcarsServiceFetchesGraphQLRequestTypes() async throws {
    let service = LCARSService(configuration: LCARSConfiguration(baseURLString: "https://api.gfn.example"), transport: MockLCARSTransport { request in
        #expect(request.url?.absoluteString == "https://api.gfn.example/graphql?requestType=loginWallData")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
        return ["data": ["loginWallData": ["enabled": true]]]
    })
    let json = try await service.fetch(requestType: .loginWallData, accessToken: "access")
    let data = try #require(json["data"] as? [String: Any])
    #expect(data["loginWallData"] != nil)
}
