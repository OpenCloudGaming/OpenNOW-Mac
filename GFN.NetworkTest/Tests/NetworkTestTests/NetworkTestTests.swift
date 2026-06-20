import Foundation
import Testing
@testable import NetworkTest

private struct MockNetworkTestTransport: NetworkTestHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://prod.cloudmatchbeta.nvidiagrid.net")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

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
    #expect(result.isCompleted)
}

@Test func networkTestModelsVendorLifecycleAndFingerprintKeys() {
    let result = NetworkTestResult(sessionId: "session", zoneAddress: "zone.example", rawStatus: "SUCCESS")
    let lifecycle = NetworkTestLifecycle().starting().finishing(result: result)
    #expect(lifecycle.state == .finished)
    #expect(lifecycle.result == result)
    #expect(NetworkTestLifecycle().starting().cancelling().errorName == .cancelled)
    #expect(NetworkTestLifecycle().starting().failing(errorName: .sdkError).state == .failed)

    let record = NetworkTestFingerprintRecord(fingerprint: "fp", zoneAddress: "zone.example", result: result, lastUpdatedEpochMs: 1_000)
    #expect(record.vendorKey == "fp_zone.example")
}

@Test func networkTestServiceStartsSessionAndUpdatesLifecycle() async throws {
    let service = NetworkTestService(transport: MockNetworkTestTransport { request in
        #expect(request.url?.path == "/v2/nettestsession")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == NetworkTest.defaultUserAgent)
        return [
            "networkSessionId": "session",
            "zone": ["address": "zone.example", "name": "np-sjc-01"],
            "testResult": ["downlinkBandwidth": 55_000, "maxPacketSize": 1_200, "status": "COMPLETED"],
        ]
    })
    let result = try await service.startSession(accessToken: "access")
    #expect(result.sessionId == "session")
    #expect(result.isCompleted)
    #expect(await service.lifecycle.state == .finished)
}
