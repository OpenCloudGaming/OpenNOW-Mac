import Foundation
import Testing
@testable import Common

@Test func cloudVariablesRequestIncludesRequiredGDNQueryItems() throws {
    let request = try #require(OPNStreamPreferences.cloudVariablesRequest(token: "token", locale: "en_US"))
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })

    #expect(components.scheme == "https")
    #expect(components.host == "api.gdn.nvidia.com")
    #expect(components.path == "/cloudvariables/v3")
    #expect(queryItems["product"] == "NVIDIAGDN")
    #expect(queryItems["locale"] == "en_US")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT token")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
}
