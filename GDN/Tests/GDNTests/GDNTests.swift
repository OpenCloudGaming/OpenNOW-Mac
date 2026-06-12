import Testing
@testable import GDN

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
