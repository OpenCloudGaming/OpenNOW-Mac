import Foundation
import Testing
@testable import Ragnarok

@Test func ragnarokTelemetryEndpointsMatchVendorEvidence() {
    #expect(Ragnarok.systemName == "Ragnarok")
    #expect(Ragnarok.productionEventsURLString == "https://events.telemetry.data.nvidia.com/v1.1/events/json")
    #expect(Ragnarok.uatEventsURLString == "https://events.telemetry.data-uat.nvidia.com/v1.1/events/json")
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
