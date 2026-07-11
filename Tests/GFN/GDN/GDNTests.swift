import Foundation
import Foundation
import Testing
@testable import OpenNOW

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
    #expect(GDN.Operation.getFeatureRollout.rawValue == "GetFeatureRollout")
    #expect(GDN.Operation.getCloudVariable.rawValue == "GetCloudVariable")
    #expect(GDN.ExperienceUseCase.getGuestFlowClientConfig.rawValue == "GxTargetGetGuestFlowClientConfig")
}

@Test func gdnBuildsCloudVariablesRequest() throws {
    let queryItems = GDNRequestFactory.cloudVariablesQueryItems(locale: "en_US")
    let request = try #require(GDNRequestFactory.cloudVariablesRequest(queryItems: queryItems))
    #expect(request.url?.absoluteString.contains("https://api.gdn.nvidia.com/cloudvariables/v3?") == true)
    #expect(request.url?.absoluteString.contains("product=NVIDIAGDN") == true)
    #expect(request.url?.absoluteString.contains("locale=en_US") == true)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
}

@Test func gdnBuildsVendorCloudVariableRequest() throws {
    let context = GDNClientContext(
        clientId: "client",
        clientVersion: "2.0.80.173",
        userId: "user",
        idpId: "idp",
        deviceId: "device",
        clientVariant: "NVIDIA-CLASSIC",
        clientType: "NATIVE",
        deviceOS: "MACOS",
        deviceOSVersion: "14",
        deviceType: "DESKTOP",
        deviceModel: "Mac",
        deviceMake: "Apple",
        browserType: "CHROME",
        source: .mallClient
    )
    let request = try #require(GDNRequestFactory.cloudVariableRequest(name: "feature", context: context, additionalItems: [URLQueryItem(name: "locale", value: "en_US")]))
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } })
    #expect(components.path == "/cloudvariables/v3")
    #expect(items["product"] == "NVIDIAGDN")
    #expect(items["name"] == "feature")
    #expect(items["clientId"] == "client")
    #expect(items["clientVer"] == "2.0.80.173")
    #expect(items["deviceId"] == "device")
    #expect(items["source"] == "MallClient")
    #expect(items["locale"] == "en_US")
}

@Test func gdnParsesVendorCloudVariablePayload() {
    let variable = GDNCloudVariableParser.parse([
        "variables": [[
            "name": "other",
            "value": false,
        ], [
            "name": "feature",
            "variation": "enabled",
            "value": ["enabled": true],
            "activity": ["bucket": 7],
            "metadata": ["owner": "gdn"],
            "state": "Active",
        ]],
    ], requestedName: "feature")
    #expect(variable.name == "feature")
    #expect(variable.variation == "enabled")
    #expect(variable.value == .object(["enabled": .bool(true)]))
    #expect(variable.activity["bucket"] == .number(7))
    #expect(variable.metadata["owner"] == .string("gdn"))
    #expect(variable.state == .active)
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

@Test func gdnServiceFetchesSingleCloudVariable() async throws {
    let service = GDNService(transport: MockGDNTransport { request in
        #expect(request.url?.absoluteString.contains("product=NVIDIAGDN") == true)
        #expect(request.url?.absoluteString.contains("name=feature") == true)
        #expect(request.url?.absoluteString.contains("clientId=client") == true)
        return ["cloudVariable": ["name": "feature", "variation": "on", "value": true, "state": "Active"]]
    })
    let variable = try await service.fetchCloudVariable(name: "feature", context: GDNClientContext(clientId: "client", clientVersion: "version", deviceId: "device"))
    #expect(variable.name == "feature")
    #expect(variable.variation == "on")
    #expect(variable.value == .bool(true))
    #expect(variable.state == .active)
}

@Test func gdnServiceRejectsMissingVendorContext() async {
    let service = GDNService(transport: MockGDNTransport { _ in [:] })
    await #expect(throws: GDNServiceError.missingClientContext) {
        _ = try await service.fetchCloudVariable(name: "feature", context: GDNClientContext())
    }
}
