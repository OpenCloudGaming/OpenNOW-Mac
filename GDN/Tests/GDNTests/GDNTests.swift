import Testing
@testable import GDN

@Test func gdnNamesMatchVendorEvidence() {
    #expect(GDN.systemName == "GDN")
    #expect(GDN.productName == "NVIDIAGDN")
    #expect(GDN.cloudVariablesURLString == "https://api.gdn.nvidia.com/cloudvariables/v3")
}

@Test func gdnBuildsCloudVariablesRequest() throws {
    let request = try #require(GDNRequestFactory.cloudVariablesRequest(queryItems: [.init(name: "product", value: GDN.productName)]))
    #expect(request.url?.absoluteString == "https://api.gdn.nvidia.com/cloudvariables/v3?product=NVIDIAGDN")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
}
