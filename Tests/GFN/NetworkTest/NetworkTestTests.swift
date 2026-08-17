import Foundation
import Foundation
import Testing
@testable import OpenNOW

private struct MockNetworkTestTransport: NetworkTestHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: 200, httpVersion: nil, headerFields: nil) else {
            throw NetworkTestServiceError.invalidHTTPResponse
        }
        return (data, response)
    }
}

private actor SequencedNetworkTestTransport: NetworkTestHTTPTransport {
    private var statuses: [Int]
    private(set) var requestCount = 0

    init(statuses: [Int]) {
        self.statuses = statuses
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let status = statuses.isEmpty ? 200 : statuses.removeFirst()
        let json: [String: Any] = [
            "netTestSession": [
                "sessionId": "session",
                "connectionInfo": [["ip": "zone.example", "port": 443, "appLevelProtocol": 5]],
            ],
            "testResult": ["status": "COMPLETED"],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let response = HTTPURLResponse(url: request.url ?? URL(fileURLWithPath: "/"), statusCode: status, httpVersion: nil, headerFields: status == 503 ? ["Retry-After": "0"] : nil) else {
            throw NetworkTestServiceError.invalidHTTPResponse
        }
        return (data, response)
    }
}

private actor FailingNetworkTestTransport: NetworkTestHTTPTransport {
    private let code: URLError.Code
    private(set) var requestCount = 0

    init(code: URLError.Code) {
        self.code = code
    }

    func send(_: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        throw URLError(code)
    }
}

private struct DelayedNetworkTestTransport: NetworkTestHTTPTransport {
    func send(_: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await Task.sleep(for: .seconds(30))
        throw NetworkTestServiceError.invalidHTTPResponse
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
    let request = try #require(NetworkTestRequestFactory.sessionRequest(accessToken: "access", payload: NetworkTestSessionRequestPayload(appId: 123, videoProfile: NetworkTestVideoProfile(width: 1280, height: 720, frameRate: 60))))
    #expect(request.url?.absoluteString == "https://prod.cloudmatchbeta.nvidiagrid.net/v2/nettestsession")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix(NetworkTest.defaultUserAgent) == true)
    #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Chrome/") == true)
    #expect(request.value(forHTTPHeaderField: "x-nv-client-identity") == request.value(forHTTPHeaderField: "User-Agent"))
    #expect(request.value(forHTTPHeaderField: "nv-client-identity") == request.value(forHTTPHeaderField: "User-Agent"))
    #expect(request.value(forHTTPHeaderField: "x-nv-client-version") == "1.0")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let requestData = try #require(json["netTestRequestData"] as? [String: Any])
    let profile = try #require(requestData["netTestProfile"] as? [String: Any])
    #expect(requestData["clientPlatformName"] as? String == "gfn_browser_client")
    #expect(requestData["appId"] == nil)
    #expect(profile["widthInPixels"] as? Int == 1280)
    #expect(profile["heightInPixels"] as? Int == 720)
    #expect(profile["framesPerSecond"] as? Int == 60)
}

@Test func networkTestParsesVendorResultPayload() {
    let result = NetworkTestResultParser.parse([
        "networkSessionId": "session",
        "zone": ["address": "zone.example", "name": "np-sjc-01"],
        "testResult": ["downlinkBandwidth": 55_000, "maxPacketSize": 1_200, "latencyMs": 42, "jitterMs": 7, "packetLossPercent": 0.4, "status": "COMPLETED"],
    ])
    #expect(result.sessionId == "session")
    #expect(result.zoneAddress == "zone.example")
    #expect(result.downlinkBandwidth == 55_000)
    #expect(result.maxPacketSize == 1_200)
    #expect(result.latencyMilliseconds == 42)
    #expect(result.jitterMilliseconds == 7)
    #expect(result.packetLossPercent == 0.4)
    #expect(result.rawStatus == "COMPLETED")
    #expect(result.hasTestResult)
    #expect(result.isCompleted)
}

@Test func networkTestProvisioningPayloadDoesNotExposeUnprovenMeasurements() {
    let result = NetworkTestResultParser.parse([
        "requestStatus": ["statusDescription": "SUCCESS_STATUS"],
        "netTestSession": [
            "sessionId": "session",
            "connectionInfo": [["ip": "zone.example", "port": 443, "appLevelProtocol": 5]],
        ],
        "downlinkBandwidth": 90_000_000,
        "latencyMs": 12,
    ])

    #expect(result.rawStatus == "SUCCESS_STATUS")
    #expect(!result.hasTestResult)
    #expect(!result.isCompleted)
    #expect(result.downlinkBandwidth == 0)
    #expect(result.latencyMilliseconds == -1)
}

@Test func networkTestNonterminalResultDoesNotExposeMeasurements() {
    let result = NetworkTestResultParser.parse([
        "networkSessionId": "session",
        "zone": ["address": "zone.example"],
        "testResult": ["status": "RUNNING", "latencyMs": 12, "jitterMs": 2, "packetLossPercent": 0.1],
    ])

    #expect(result.hasTestResult)
    #expect(!result.isCompleted)
    #expect(result.latencyMilliseconds == -1)
    #expect(result.jitterMilliseconds == -1)
    #expect(result.packetLossPercent == -1)
}

@Test func networkTestParsesVendorNetTestSessionPayload() {
    let result = NetworkTestResultParser.parse([
        "requestStatus": ["statusCode": 1, "statusDescription": "SUCCESS_STATUS", "serverId": "np-sjc-01"],
        "netTestSession": [
            "sessionId": "session",
            "serverId": "np-sjc-01",
            "connectionInfo": [["ip": "zone.example", "port": 443, "appLevelProtocol": 5]],
            "netTestThresholds": [
                "recommendedBandwidthMBPS": 50,
                "requiredBandwidthMBPS": 25,
                "recommendedLatencyMS": 40,
                "requiredLatencyMS": 80,
                "recommendedPacketLossPct": 1.5,
                "requiredPacketLossPct": 5,
            ],
        ],
    ])
    #expect(result.sessionId == "session")
    #expect(result.zoneAddress == "zone.example")
    #expect(result.zoneName == "np-sjc-01")
    #expect(result.connectionEndpoint.scheme == "https")
    #expect(result.threshold.bandwidthRecommended == 50)
    #expect(result.threshold.packetLossRecommended == 1.5)
}

@Test func networkTestModelsVendorLifecycleAndFingerprintKeys() {
    let result = NetworkTestResult(sessionId: "session", zoneAddress: "zone.example", rawStatus: "SUCCESS", hasTestResult: true)
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
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix(NetworkTest.defaultUserAgent) == true)
        return [
            "requestStatus": ["statusCode": 1, "statusDescription": "SUCCESS_STATUS", "serverId": "np-sjc-01"],
            "netTestSession": [
                "sessionId": "session",
                "connectionInfo": [["ip": "zone.example", "port": 443, "appLevelProtocol": 5]],
                "netTestThresholds": ["recommendedBandwidthMBPS": 50],
            ],
            "testResult": ["downlinkBandwidth": 55_000, "maxPacketSize": 1_200, "status": "COMPLETED"],
        ]
    })
    let result = try await service.startSession(accessToken: "access")
    #expect(result.sessionId == "session")
    #expect(result.isCompleted)
    #expect(await service.lifecycle.state == .finished)
}

@Test func networkTestServiceModelsProvisioningAsProvisioned() async throws {
    let service = NetworkTestService(transport: MockNetworkTestTransport { _ in
        [
            "requestStatus": ["statusDescription": "SUCCESS_STATUS"],
            "netTestSession": [
                "sessionId": "session",
                "connectionInfo": [["ip": "zone.example", "port": 443, "appLevelProtocol": 5]],
            ],
        ]
    })

    let result = try await service.startSession()
    #expect(!result.isCompleted)
    #expect(await service.lifecycle.state == .provisioned)
}

@Test func networkTestServiceRetriesTransientStatusWithRetryAfter() async throws {
    let transport = SequencedNetworkTestTransport(statuses: [503, 200])
    let service = NetworkTestService(transport: transport)

    let result = try await service.startSession()

    #expect(result.isCompleted)
    #expect(await transport.requestCount == 2)
}

@Test func networkTestServiceDoesNotRetryBadURL() async {
    let transport = FailingNetworkTestTransport(code: .badURL)
    let service = NetworkTestService(transport: transport)

    await #expect(throws: URLError.self) {
        try await service.startSession()
    }
    #expect(await transport.requestCount == 1)
}

@Test func networkTestServiceDoesNotRetryCertificateFailure() async {
    let transport = FailingNetworkTestTransport(code: .serverCertificateUntrusted)
    let service = NetworkTestService(transport: transport)

    await #expect(throws: URLError.self) {
        try await service.startSession()
    }
    #expect(await transport.requestCount == 1)
}

@Test func networkTestServiceCancelStopsActiveTransportWork() async {
    let service = NetworkTestService(transport: DelayedNetworkTestTransport())
    let task = Task { try await service.startSession() }
    try? await Task.sleep(for: .milliseconds(20))

    await service.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    #expect(await service.lifecycle.state == .cancelled)
}
