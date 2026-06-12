import Foundation
import Testing
@testable import LCARS

@Test func lcarsRequestTypesMatchVendorCacheRoutes() {
    #expect(LCARS.systemName == "LCARS")
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

@Test func lcarsBuildsGraphQLRequest() throws {
    let configuration = LCARSConfiguration(baseURLString: "https://api.gfn.example")
    let request = try #require(LCARSRequestFactory.graphQLRequest(requestType: .panels, accessToken: "access", configuration: configuration))
    #expect(request.url?.absoluteString == "https://api.gfn.example/graphql?requestType=panels")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
}
