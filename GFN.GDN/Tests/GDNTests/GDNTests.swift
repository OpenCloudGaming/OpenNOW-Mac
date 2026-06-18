import Foundation
import Testing
@testable import GDN

private struct MockGDNTransport: GDNHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://api.gdn.nvidia.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Test func gdnNamesMatchVendorEvidence() {
    #expect(GDN.systemName == "GDN")
    #expect(GDN.productName == "NVIDIAGDN")
    #expect(GDN.serviceName == "GxTarget")
    #expect(GDN.cloudVariablesURLString == "https://api.gdn.nvidia.com/cloudvariables/v3")
    #expect(GDN.Operation.getCloudVariable.rawValue == "GxTargetGetCloudVariable")
}

@Test func gdnBuildsCloudVariablesRequest() throws {
    let queryItems = GDNRequestFactory.cloudVariablesQueryItems(locale: "en_US")
    let request = try #require(GDNRequestFactory.cloudVariablesRequest(queryItems: queryItems))
    #expect(request.url?.absoluteString.contains("https://api.gdn.nvidia.com/cloudvariables/v3?") == true)
    #expect(request.url?.absoluteString.contains("product=NVIDIAGDN") == true)
    #expect(request.url?.absoluteString.contains("locale=en_US") == true)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
}

@Test func gdnServiceFetchesCloudVariables() async throws {
    let service = GDNService(transport: MockGDNTransport { request in
        #expect(request.url?.absoluteString.contains("product=NVIDIAGDN") == true)
        #expect(request.url?.absoluteString.contains("locale=en_US") == true)
        return ["variables": [["key": "feature", "value": true]]]
    })
    let json = try await service.fetchCloudVariables(locale: "en_US")
    let variables = try #require(json["variables"] as? [[String: Any]])
    #expect(variables.first?["key"] as? String == "feature")
}
