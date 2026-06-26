import Foundation
import Testing
@testable import Common

@Test func cloudVariablesRequestIncludesRequiredGXTQueryItems() throws {
    let request = try #require(OPNStreamPreferences.cloudVariablesRequest(token: "token", locale: "en_US"))
    let url = try #require(request.url)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
        item.value.map { (item.name, $0) }
    })

    #expect(components.scheme == "https")
    #expect(components.host == "gx-target-experiments-frontend-api.gx.nvidia.com")
    #expect(components.path == "/cloudvariables/v3")
    #expect(queryItems["cvName"]?.contains("webRtcNetworkTestV2") == true)
    #expect(queryItems["clientVer"] == "2.0.85.135")
    #expect(queryItems["clientType"] == "Browser")
    #expect(queryItems["browserType"] == "Chrome")
    #expect(queryItems["deviceOS"] == "MacOS")
    #expect(queryItems["deviceMake"] == "APPLE")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*")
}
