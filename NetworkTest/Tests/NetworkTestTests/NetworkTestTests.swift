import Testing
@testable import NetworkTest

@Test func networkTestNamesMatchVendorEvidence() {
    #expect(NetworkTest.systemName == "NetworkTest")
    #expect(NetworkTest.routePath == "/v2/nettestsession")
    #expect(NetworkTest.defaultUserAgent == "GFN-PC/1.0 (WebRTC) NetworkTest/0.0.51 ")
    #expect(NetworkTest.EventName.networkTest.rawValue == "NetworkTest")
    #expect(NetworkTest.EventName.analytics.rawValue == "NetworkTestAnalytics")
    #expect(NetworkTest.EventName.completed.rawValue == "NetworkTestCompleted")
    #expect(NetworkTest.EventName.httpEvent.rawValue == "NetworkTest_Http_Event")
    #expect(NetworkTest.EventName.exception.rawValue == "NetworkTest_Exception_Event")
    #expect(NetworkTest.ErrorName.sdkError.rawValue == "NetworkTestSdkError")
}

@Test func networkTestBuildsSessionRequest() throws {
    let request = try #require(NetworkTestRequestFactory.sessionRequest(accessToken: "access"))
    #expect(request.url?.absoluteString == "https://prod.cloudmatchbeta.nvidiagrid.net/v2/nettestsession")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == NetworkTest.defaultUserAgent)
}

@Test func networkTestParsesVendorResultPayload() {
    let result = NetworkTestResultParser.parse([
        "networkSessionId": "session",
        "zone": ["address": "zone.example", "name": "np-sjc-01"],
        "testResult": ["downlinkBandwidth": 55_000, "maxPacketSize": 1_200, "status": "COMPLETED"],
    ])
    #expect(result.sessionId == "session")
    #expect(result.zoneAddress == "zone.example")
    #expect(result.downlinkBandwidth == 55_000)
    #expect(result.maxPacketSize == 1_200)
    #expect(result.rawStatus == "COMPLETED")
}
