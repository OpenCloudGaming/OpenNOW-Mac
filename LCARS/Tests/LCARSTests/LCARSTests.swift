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
}

@Test func lcarsBuildsGraphQLRequest() throws {
    let configuration = LCARSConfiguration(baseURLString: "https://api.gfn.example")
    let request = try #require(LCARSRequestFactory.graphQLRequest(requestType: .panels, accessToken: "access", configuration: configuration))
    #expect(request.url?.absoluteString == "https://api.gfn.example/graphql?requestType=panels")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
}
