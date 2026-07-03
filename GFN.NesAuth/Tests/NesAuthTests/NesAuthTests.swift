import Testing
import Foundation
import Testing
@testable import NesAuth

private struct MockNesAuthTransport: NesAuthHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://mes.geforcenow.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Test func nesAuthNamesMatchVendorNames() {
    #expect(NesAuth.systemName == "NES Auth")
    #expect(NesAuth.ElementName.auth.rawValue == "gfn-nes-auth")
    #expect(NesAuth.uiServiceName == "gfn/NesAuthUIService")
    #expect(NesAuth.errorRouteName == "streamerError/nesAuthError")
    #expect(NesAuth.Operation.getServiceUrls.rawValue == "NES_Get_ServiceUrls")
    #expect(NesAuth.Operation.getClientStreamingQuality.rawValue == "NES_GetClientStreamingQuality")
    #expect(NesAuth.LaunchStatus.autoAuthorization.rawValue == "NesAutoAuthorization")
}

@Test func nesAuthConfigurationNormalizesVendorURLs() {
    let configuration = NesAuthConfiguration(serverURLString: "mes.geforcenow.com/", version: "/v4/", layoutServerURLString: "pcs.geforcenow.com/", layoutServerVersion: "/v1/")
    #expect(configuration.serverURLString == "https://mes.geforcenow.com")
    #expect(configuration.version == "v4")
    #expect(configuration.layoutServerURLString == "https://pcs.geforcenow.com")
    #expect(configuration.layoutServerVersion == "v1")
}

@Test func nesAuthBuildsSubscriptionRequest() throws {
    let configuration = NesAuthConfiguration(serverURLString: "https://mes.example", serviceName: "gfn_pc", userAgent: "agent")
    let request = try #require(NesAuthRequestFactory.request(operation: .getSubscriptions, accessToken: "access", parameters: [URLQueryItem(name: "locale", value: "en_US")], configuration: configuration, bypassCache: true, notifyFetch: true))
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
    #expect(url.absoluteString.contains("https://mes.example/v4/subscriptions?") == true)
    #expect(items["serviceName"] == "gfn_pc")
    #expect(items["locale"] == "en_US")
    #expect(request.httpMethod == "GET")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "agent")
    #expect(request.value(forHTTPHeaderField: NesAuthRequestFactory.swCacheBypassHeader) == "true")
    #expect(request.value(forHTTPHeaderField: NesAuthRequestFactory.swNotifyFetchHeader) == "true")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
}

@Test func nesAuthBuildsLayoutServiceUrlsRequest() throws {
    let configuration = NesAuthConfiguration(serverURLString: "https://mes.example", layoutServerURLString: "https://pcs.example")
    let request = try #require(NesAuthRequestFactory.request(operation: .getServiceUrls, configuration: configuration))
    #expect(request.url?.absoluteString == "https://pcs.example/v1/serviceUrls?serviceName=gfn_pc")
    #expect(request.httpMethod == "GET")
}

@Test func nesAuthBuildsMutationRequestsWithJsonContentType() throws {
    let request = try #require(NesAuthRequestFactory.request(operation: .install, configuration: NesAuthConfiguration(serverURLString: "https://mes.example")))
    #expect(request.url?.absoluteString == "https://mes.example/v4/apps/install?serviceName=gfn_pc")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
}

@Test func nesAuthServiceFetchesVendorOperations() async throws {
    let service = NesAuthService(configuration: NesAuthConfiguration(serverURLString: "https://mes.example", layoutServerURLString: "https://pcs.example"), transport: MockNesAuthTransport { request in
        #expect(request.url?.path == "/v1/serviceUrls")
        #expect(request.httpMethod == "GET")
        return ["services": ["uds": "https://uds.example"]]
    })
    let json = try await service.fetchServiceUrls()
    let services = try #require(json["services"] as? [String: String])
    #expect(services["uds"] == "https://uds.example")
}

@Test func nesAuthMapsVendorAuthorizationPolicy() {
    let policy = NesAuthorizationPolicy()
    #expect(policy.result(authType: "JWT_GFN").state == .authorized)
    #expect(policy.result(authType: "NONE", entitlementErrorCode: "NVB_R_USER_IS_NOT_ENTITLED").state == .notEntitled)
    #expect(policy.result(authType: "NONE", entitlementErrorCode: "351").launchStatus == .notEntitled)
    #expect(policy.result(authType: "NONE", entitlementErrorCode: "NVB_R_NETWORK_ERROR").launchStatus == .failed)
}
