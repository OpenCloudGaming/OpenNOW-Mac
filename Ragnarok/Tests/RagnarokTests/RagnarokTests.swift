import Foundation
import Testing
@testable import Ragnarok

private struct MockRagnarokTransport: RagnarokHTTPTransport {
    let handler: @Sendable (URLRequest) throws -> Int

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let status = try handler(request)
        let response = HTTPURLResponse(url: request.url ?? URL(string: Ragnarok.productionEventsURLString)!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(), response)
    }
}

@Test func ragnarokTelemetryEndpointsMatchVendorEvidence() {
    #expect(Ragnarok.systemName == "Ragnarok")
    #expect(Ragnarok.productionEventsURLString == "https://events.telemetry.data.nvidia.com/v1.1/events/json")
    #expect(Ragnarok.uatEventsURLString == "https://events.telemetry.data-uat.nvidia.com/v1.1/events/json")
    #expect(Ragnarok.EventName.networkTestHTTP.gdprLevel == .functional)
    #expect(Ragnarok.EventName.networkTestException.gdprLevel == .technical)
    #expect(Ragnarok.EventName.networkTest.personalization == .userPreferred)
    #expect(Ragnarok.EventName.loginStart.gdprLevel == .technical)
    #expect(Ragnarok.EventName.userSession.gdprLevel == .behavioral)
}

@Test func ragnarokBuildsEventsRequest() throws {
    let request = try #require(RagnarokRequestFactory.eventsRequest(events: [RagnarokEvent(name: "NetworkTest", timestamp: "2026-01-01T00:00:00Z", parameters: ["result": "success"])]))
    #expect(request.url?.absoluteString == "https://events.telemetry.data.nvidia.com/v1.1/events/json")
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let events = try #require(json["events"] as? [[String: Any]])
    #expect(events.first?["name"] as? String == "NetworkTest")
}

@Test func ragnarokVendorEventMetadataIsSerialized() throws {
    let request = try #require(RagnarokRequestFactory.eventsRequest(events: [RagnarokEvent(eventName: .networkTestHTTP, timestamp: "2026-01-01T00:00:00Z", parameters: ["status": "200"])]))
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let events = try #require(json["events"] as? [[String: Any]])
    #expect(events.first?["name"] as? String == "NetworkTest_Http_Event")
    #expect(events.first?["gdprLevel"] as? String == "Functional")
    #expect(events.first?["personalization"] as? String == "UserPreferred")
}

@Test func ragnarokSerializesVendorCommonData() throws {
    let request = try #require(RagnarokRequestFactory.eventsRequest(
        events: [RagnarokEvent(eventName: .loginStart, timestamp: "2026-01-01T00:00:00Z")],
        commonData: RagnarokCommonData(clientVersion: "2.0.80.173", deviceId: "device", locale: "en_US", sessionId: "session")
    ))
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let commonData = try #require(json["commonData"] as? [String: String])
    #expect(commonData["appId"] == "gfnpc")
    #expect(commonData["clientVersion"] == "2.0.80.173")
    #expect(commonData["deviceId"] == "device")
}

@Test func ragnarokServiceSendsEvents() async throws {
    let service = RagnarokService(transport: MockRagnarokTransport { request in
        #expect(request.url?.absoluteString == Ragnarok.productionEventsURLString)
        #expect(request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let events = try #require(json["events"] as? [[String: Any]])
        #expect(events.first?["name"] as? String == "NetworkTest")
        return 202
    })
    let response = try await service.send(events: [RagnarokEvent(eventName: .networkTest)])
    #expect(response.statusCode == 202)
}
