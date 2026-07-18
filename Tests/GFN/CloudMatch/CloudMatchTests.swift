import Foundation
import Testing
@testable import OpenNOW

private struct MockCloudMatchTransport: CloudMatchHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> [String: Any]

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let json = try handler(request)
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url ?? URL(string: "https://prod.cloudmatchbeta.nvidiagrid.net")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

@Test func cloudMatchVendorEndpointsMatchEvidence() throws {
    #expect(CloudMatch.systemName == "CloudMatch")
    #expect(CloudMatch.productionBaseURLString == "https://prod.cloudmatchbeta.nvidiagrid.net")
    #expect(CloudMatch.sessionPath == "/v2/session")
    #expect(CloudMatch.Endpoint.serviceUrls.path == "/v1/serviceUrls")
    #expect(CloudMatch.Endpoint.serverInfo.path == "/v2/serverInfo")
    #expect(CloudMatch.Endpoint.networkTestSession.path == "/v2/nettestsession")
    #expect(CloudMatch.Endpoint.subscriptions.path == "/v4/subscriptions")
    #expect(CloudMatch.Endpoint.serviceUrls.cachePolicy.maxAgeSeconds == 1_209_600)
    #expect(CloudMatch.Endpoint.subscriptions.cachePolicy.flushCacheOnResponseCodes == [404])
    #expect(CloudMatch.Endpoint.subscriptions.cachePolicy.shouldFlush(responseStatusCode: 404))
    #expect(CloudMatch.Endpoint.serviceUrls.cachePolicy.isExpired(cachedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 1_209_600)))
}

@Test func cloudMatchBuildsAuthenticatedVendorRequests() throws {
    let request = try #require(CloudMatchRequestFactory.request(endpoint: .serverInfo, accessToken: "access", queryItems: [.init(name: "locale", value: "en_US")], deviceId: "device"))
    #expect(request.url?.absoluteString == "https://prod.cloudmatchbeta.nvidiagrid.net/v2/serverInfo?locale=en_US")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "x-device-id") == "device")
    #expect(request.value(forHTTPHeaderField: "nv-client-id") == "ec7e38d4-03af-4b58-b131-cfb0495903ab")
}

@Test func cloudMatchBuildsBrowserWebRTCServerInfoRequest() throws {
    let request = try #require(CloudMatchRequestFactory.serverInfoRequest(baseURLString: "region.example.test", accessToken: "access", deviceId: "device", headers: .browserWebRTC(clientVersion: "2.0.85.135"), timeoutInterval: 4))
    #expect(request.url?.absoluteString == "https://region.example.test/v2/serverInfo")
    #expect(request.timeoutInterval == 4)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
    #expect(request.value(forHTTPHeaderField: "nv-client-type") == "BROWSER")
    #expect(request.value(forHTTPHeaderField: "nv-client-streamer") == "WEBRTC")
    #expect(request.value(forHTTPHeaderField: "nv-device-os") == "WINDOWS")
}

@Test func cloudMatchBuildsSessionRequests() throws {
    let create = try #require(CloudMatchRequestFactory.createSessionRequest(baseURLString: "https://cloudmatch.example.test/", accessToken: "access", deviceId: "device", keyboardLayout: "us", languageCode: "en_US", body: Data("{}".utf8)))
    #expect(create.url?.absoluteString == "https://cloudmatch.example.test/v2/session?keyboardLayout=us&languageCode=en_US")
    #expect(create.httpMethod == "POST")
    #expect(create.value(forHTTPHeaderField: "Origin") == nil)
    #expect(create.httpBody == Data("{}".utf8))

    let poll = try #require(CloudMatchRequestFactory.pollSessionRequest(baseURLString: "cloudmatch.example.test", sessionId: "session/with slash", accessToken: "access", deviceId: "device"))
    #expect(poll.url?.absoluteString == "https://cloudmatch.example.test/v2/session/session%2Fwith%20slash")
    #expect(poll.httpMethod == "GET")

    let stop = try #require(CloudMatchRequestFactory.stopSessionRequest(baseURLString: "https://cloudmatch.example.test", sessionId: "session", accessToken: "access", deviceId: "device"))
    #expect(stop.httpMethod == "DELETE")
    #expect(stop.value(forHTTPHeaderField: "Origin") == "https://play.geforcenow.com")
    #expect(stop.value(forHTTPHeaderField: "Referer") == "https://play.geforcenow.com/")

    let active = try #require(CloudMatchRequestFactory.activeSessionsRequest(baseURLString: "https://cloudmatch.example.test", accessToken: "access", deviceId: "device"))
    #expect(active.url?.absoluteString == "https://cloudmatch.example.test/v2/session")
    #expect(active.httpMethod == "GET")
}

@Test func cloudMatchBuildsClaimAndAdUpdateRequests() throws {
    let claim = try #require(CloudMatchRequestFactory.claimSessionRequest(baseURLString: "https://cloudmatch.example.test", sessionId: "session", accessToken: "access", deviceId: "device", keyboardLayout: "us", languageCode: "en_US", body: Data("{}".utf8)))
    #expect(claim.url?.absoluteString == "https://cloudmatch.example.test/v2/session/session?keyboardLayout=us&languageCode=en_US")
    #expect(claim.httpMethod == "PUT")
    #expect(claim.value(forHTTPHeaderField: "Origin") == "https://play.geforcenow.com")

    let adUpdate = try #require(CloudMatchRequestFactory.adUpdateRequest(baseURLString: "https://cloudmatch.example.test", sessionId: "session", accessToken: "access", deviceId: "device", body: Data("{}".utf8)))
    #expect(adUpdate.url?.absoluteString == "https://cloudmatch.example.test/v2/session/session")
    #expect(adUpdate.httpMethod == "PUT")
    #expect(adUpdate.httpBody == Data("{}".utf8))
}

@Test func cloudMatchResolvesSessionBaseUrls() {
    #expect(CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: "", serverIP: "") == CloudMatch.productionBaseURLString)
    #expect(CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: "https://stream.example.test/", serverIP: "") == "https://stream.example.test")
    #expect(CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: "https://stream.example.test/", serverIP: "control.example.test") == "https://control.example.test")
    #expect(CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: "https://stream.example.test/", serverIP: "https://control.example.test/") == "https://control.example.test")
    #expect(CloudMatchRequestFactory.resolvedSessionBaseURL(streamingBaseURL: "https://stream.example.test/", serverIP: "http://control.example.test/") == "https://stream.example.test")
}

@Test func cloudMatchParsesVendorServerInfoMetadata() {
    let info = CloudMatchServerInfoParser.parse([
        "vpcId": "vpc",
        "serverType": "prod",
        "metaData": [
            ["key": "gfn-regions", "value": "np-sjc-01, np-lax-01"],
            ["key": "np-sjc-01", "value": "https://sjc.cloudmatch.example/"],
            ["key": "np-lax-01", "value": "lax.cloudmatch.example"],
            ["key": "local-region", "value": "https://sjc.cloudmatch.example/"],
        ],
    ])
    #expect(info.vpcId == "vpc")
    #expect(info.serverType == "prod")
    #expect(info.zones["sjc.cloudmatch.example"]?.name == "np-sjc-01")
    #expect(info.detectedLocalZone?.address == "sjc.cloudmatch.example")
}

@Test func cloudMatchParsesLocalRegionNameAndAdvertisedDefaultOrder() {
    let localInfo = CloudMatchServerInfoParser.parse([
        "metaData": [
            ["key": "local-region", "value": "Texas (USA)"],
            ["key": "gfn-regions", "value": "Germany,Texas (USA)"],
            ["key": "Germany", "value": "https://eu-germany.cloudmatchbeta.nvidiagrid.net"],
            ["key": "Texas (USA)", "value": "https://us-texas.cloudmatchbeta.nvidiagrid.net"],
        ],
    ])
    #expect(localInfo.detectedLocalZone?.name == "Texas (USA)")
    #expect(localInfo.defaultZone?.name == "Texas (USA)")

    let fallbackInfo = CloudMatchServerInfoParser.parse([
        "metaData": [
            ["key": "gfn-regions", "value": "Germany,Texas (USA)"],
            ["key": "Germany", "value": "https://eu-germany.cloudmatchbeta.nvidiagrid.net"],
            ["key": "Texas (USA)", "value": "https://us-texas.cloudmatchbeta.nvidiagrid.net"],
        ],
    ])
    #expect(fallbackInfo.defaultZone?.name == "Germany")
}

@Test func cloudMatchClearsUnavailableRouteOverrides() {
    let available = CloudMatchZone(name: "np-sjc-01", address: "sjc.cloudmatch.example")
    let unavailable = CloudMatchRouteOverride(zone: CloudMatchZone(name: "np-removed", address: "removed.example"))
    let internalOverride = CloudMatchRouteOverride(zone: CloudMatchZone(name: "internal", address: "internal.example"), isInternal: true)
    let serverInfo = CloudMatchServerInfo(zones: [available.address: available], defaultZone: available)
    #expect(CloudMatchRoutingPolicy.decision(serverInfo: serverInfo, override: nil) == .useDefault(available))
    #expect(CloudMatchRoutingPolicy.decision(serverInfo: serverInfo, override: CloudMatchRouteOverride(zone: available)) == .useOverride(CloudMatchRouteOverride(zone: available)))
    #expect(CloudMatchRoutingPolicy.decision(serverInfo: serverInfo, override: unavailable) == .clearUnavailableOverride(unavailable))
    #expect(CloudMatchRoutingPolicy.decision(serverInfo: serverInfo, override: internalOverride) == .useOverride(internalOverride))
}

@Test func cloudMatchParsesRequestStatuses() throws {
    let success = ["requestStatus": ["statusCode": 1, "statusDescription": "SUCCESS", "requestId": "request", "serverId": "server"]]
    #expect(CloudMatchResponseParser.requestSucceeded(success))
    #expect(CloudMatchResponseParser.requestStatus(from: success).requestId == "request")

    let limit = ["requestStatus": ["statusCode": 11, "statusDescription": "NVB_R_SESSION_LIMIT_REACHED"]]
    #expect(CloudMatchResponseParser.isSessionLimitExceededResponse(limit))

    let notPausedData = try JSONSerialization.data(withJSONObject: ["requestStatus": ["statusCode": 34, "statusDescription": "SESSION_NOT_PAUSED"]])
    #expect(CloudMatchResponseParser.isSessionNotPausedResponse(notPausedData))

    let staleData = try JSONSerialization.data(withJSONObject: [
        "requestStatus": ["statusCode": 4, "statusDescription": "INTERNAL_ERROR_STATUS 8A8C0000"],
        "session": ["sessionRequestData": ["appId": 0]],
    ])
    #expect(CloudMatchResponseParser.staleActiveSessionClaimMessage(staleData) == "This GeForce NOW session is no longer resumable. End it and launch again.")
}

@Test func cloudMatchActiveSessionParserPreservesControlAndSignalingHosts() {
    let descriptor = CloudMatchActiveSessionParser.descriptor(from: [
        "sessionId": "session-1",
        "status": 2,
        "gpuType": "L40",
        "sessionRequestData": ["appId": 123],
        "sessionControlInfo": ["ip": "control.example.test"],
        "connectionInfo": [[
            "usage": 14,
            "ip": "signaling.example.test",
            "port": 443,
            "resourcePath": "/nvst/",
        ]],
    ], streamingBaseURL: "https://cloudmatch.example.test/")

    #expect(descriptor?.sessionId == "session-1")
    #expect(descriptor?.appId == 123)
    #expect(descriptor?.resumeServer == "control.example.test")
    #expect(descriptor?.signalingURL == "wss://signaling.example.test:443/nvst/")
}

@Test func cloudMatchActiveSessionParserKeepsZeroAppIdSessionForTermination() {
    let descriptor = CloudMatchActiveSessionParser.descriptor(from: [
        "sessionId": "session-1",
        "status": 2,
        "sessionRequestData": ["appId": 0],
        "sessionControlInfo": ["ip": "control.example.test"],
    ], streamingBaseURL: "https://cloudmatch.example.test/")

    #expect(descriptor?.sessionId == "session-1")
    #expect(descriptor?.appId == 0)
    #expect(descriptor?.resumeServer == "control.example.test")
}

@Test func cloudMatchActiveSessionParserExtractsSignalingHostFromResourcePath() {
    let descriptor = CloudMatchActiveSessionParser.descriptor(from: [
        "sessionId": "session-1",
        "status": 6,
        "sessionRequestData": ["appId": 123],
        "connectionInfo": [[
            "usage": 14,
            "ip": "",
            "resourcePath": "rtsps://resource.example.test:443/nvst/",
        ]],
    ], streamingBaseURL: "https://cloudmatch.example.test/")

    #expect(descriptor?.resumeServer == "resource.example.test")
    #expect(descriptor?.state.canContinuePolling == true)
}

@Test func cloudMatchSessionStatesMatchVendorBackendValues() {
    #expect(CloudMatchSessionState(rawValue: 1) == .initializing)
    #expect(CloudMatchSessionState(rawValue: 2) == .readyForConnection)
    #expect(CloudMatchSessionState(rawValue: 3) == .streaming)
    #expect(CloudMatchSessionState(rawValue: 4) == .pausedUnintentional)
    #expect(CloudMatchSessionState(rawValue: 5) == .pausedIntentional)
    #expect(CloudMatchSessionState(rawValue: 6) == .resuming)
    #expect(CloudMatchSessionState(rawValue: 7) == .finished)
    #expect(CloudMatchSessionState.pausedUnintentional.canContinuePolling)
    #expect(CloudMatchSessionState.pausedIntentional.canContinuePolling)
    #expect(CloudMatchSessionState.resuming.canContinuePolling)
    #expect(!CloudMatchSessionState.finished.isVendorResumable)
}

@Test func cloudMatchActiveSessionParserRejectsTerminalOrUnusableSessions() {
    #expect(CloudMatchActiveSessionParser.descriptor(from: ["sessionId": "session", "status": 7, "sessionControlInfo": ["ip": "control.example.test"]], streamingBaseURL: "https://cloudmatch.example.test/") == nil)
    #expect(CloudMatchActiveSessionParser.descriptor(from: ["status": 2, "sessionControlInfo": ["ip": "control.example.test"]], streamingBaseURL: "https://cloudmatch.example.test/") == nil)
    #expect(CloudMatchActiveSessionParser.descriptor(from: ["sessionId": "session", "status": 2], streamingBaseURL: "https://cloudmatch.example.test/") == nil)
}

@Test func cloudMatchServiceFetchesServerInfoAndSubscriptions() async throws {
    let service = CloudMatchService(transport: MockCloudMatchTransport { request in
        if request.url?.path == "/v2/serverInfo" {
            return [
                "vpcId": "vpc",
                "serverType": "prod",
                "metadata": [
                    ["key": "gfn-regions", "value": "np-sjc-01"],
                    ["key": "np-sjc-01", "value": "sjc.cloudmatch.example"],
                ],
            ]
        }
        #expect(request.url?.path == "/v4/subscriptions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "GFNJWT access")
        return ["subscriptions": [["id": "sub"]]]
    })
    let serverInfo = try await service.fetchServerInfo()
    #expect(serverInfo.zones["sjc.cloudmatch.example"]?.name == "np-sjc-01")
    let subscriptions = try await service.fetchSubscriptions(accessToken: "access")
    let items = try #require(subscriptions["subscriptions"] as? [[String: Any]])
    #expect(items.first?["id"] as? String == "sub")
}
