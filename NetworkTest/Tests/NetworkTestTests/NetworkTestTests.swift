import Testing
@testable import NetworkTest

@Test func networkTestNamesMatchVendorEvidence() {
    #expect(NetworkTest.systemName == "NetworkTest")
    #expect(NetworkTest.routePath == "/v2/nettestsession")
    #expect(NetworkTest.EventName.analytics.rawValue == "NetworkTestAnalytics")
    #expect(NetworkTest.EventName.completed.rawValue == "NetworkTestCompleted")
    #expect(NetworkTest.EventName.httpEvent.rawValue == "NetworkTest_Http_Event")
    #expect(NetworkTest.EventName.exception.rawValue == "NetworkTest_Exception_Event")
}

@Test func networkTestBuildsSessionRequest() throws {
    let request = try #require(NetworkTestRequestFactory.sessionRequest(accessToken: "access"))
    #expect(request.url?.absoluteString == "https://prod.cloudmatchbeta.nvidiagrid.net/v2/nettestsession")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
}
