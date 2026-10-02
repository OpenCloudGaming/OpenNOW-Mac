import Foundation
import Testing
@testable import OpenNOW

@Test func telemetryEventNamesPreserveVendorMeaningWithoutVendorTransport() {
    #expect(OPNTelemetryEventName.networkTestHTTP.rawValue == "NetworkTest_Http_Event")
    #expect(OPNTelemetryEventName.networkTestException.rawValue == "NetworkTest_Exception_Event")
    #expect(OPNTelemetryEventName.udsDialogShown.rawValue == "UDSDialogShown")
    #expect(OPNTelemetryEventName.udsEndOfSessionReport.rawValue == "UdsEndOfSessionReport")
    #expect(OPNTelemetryEventName.udsSuggestionFeedback.rawValue == "UDSSuggestionFeedback")
    #expect(OPNTelemetryEventName.gameLaunchEvent.rawValue == "Game_Launch_Event")
    #expect(OPNTelemetryEventName.networkTestHTTP.privacyLevel == .functional)
    #expect(OPNTelemetryEventName.networkTestException.privacyLevel == .technical)
    #expect(OPNTelemetryEventName.udsEndOfSessionReport.privacyLevel == .functional)
    #expect(OPNTelemetryEventName.networkTest.personalization == .userPreferred)
    #expect(OPNTelemetryEventName.loginStart.privacyLevel == .technical)
    #expect(OPNTelemetryEventName.userSession.privacyLevel == .behavioral)
}

@Test func telemetryCommonDataOmitsEmptyValues() {
    let commonData = OPNTelemetryCommonData(clientVersion: "1.2.3", deviceId: "device", locale: "en_US")

    #expect(commonData.dictionary == [
        "appId": "opennow",
        "clientVersion": "1.2.3",
        "deviceId": "device",
        "locale": "en_US",
    ])
}

@Test func telemetryEventDictionaryUsesOPNNames() {
    let event = OPNTelemetryEvent(name: .networkTest, timestamp: "2026-01-01T00:00:00Z", parameters: ["result": "success"])
    let dictionary = event.dictionary

    #expect(dictionary["name"] as? String == "NetworkTest")
    #expect(dictionary["timestamp"] as? String == "2026-01-01T00:00:00Z")
    #expect(dictionary["privacyLevel"] as? String == "Behavioral")
    #expect(dictionary["personalization"] as? String == "UserPreferred")
    #expect((dictionary["parameters"] as? [String: String])?["result"] == "success")
}

@Test func telemetryRecorderRecordsAnEventLocallyWithoutAVendorEndpoint() {
    let event = OPNTelemetryEvent(name: .routingStatus, timestamp: "2026-01-01T00:00:00Z", parameters: ["zone": "192.168.1.24"])
    let commonData = OPNTelemetryCommonData(clientVersion: GFNClientMetadata.appVersion, sessionId: "session")
    let message = OPNTelemetryRecorder.logMessage(event: event, commonData: commonData)

    #expect(message.contains("Event name=RoutingStatus"))
    #expect(message.contains("privacy=Functional"))
    #expect(message.contains("personalization=UserPreferred"))
    #expect(message.contains("clientVersion=\(GFNClientMetadata.appVersion)"))
    #expect(message.contains("sessionId=session"))
    #expect(!message.contains("192.168.1.24"))
    #expect(!message.contains(["events", "telemetry", "data", "nvidia", "com"].joined(separator: ".")))
    // The retired telemetry preference used to make this return false and drop the event.
    #expect(OPNTelemetryRecorder.record(event, commonData: commonData))
}

@Test func telemetryLogMessageDoesNotConstructVendorTelemetryRequest() {
    let event = OPNTelemetryEvent(name: .gameLaunchEvent, timestamp: "2026-01-01T00:00:00Z", parameters: ["status": "started"])
    let message = OPNTelemetryRecorder.logMessage(event: event, commonData: OPNTelemetryCommonData())

    #expect(message.contains("Game_Launch_Event"))
    #expect(!message.contains(["events", "telemetry", "data", "nvidia", "com"].joined(separator: ".")))
    #expect(!message.contains(["Ragna", "rok"].joined()))
}
