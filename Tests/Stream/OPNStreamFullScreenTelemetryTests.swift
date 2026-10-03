//  Game Mode's own state has no public API, so the full-screen telemetry records eligibility and the
//  transition landing instead. The failure event's warning level and its reason/attemptCount/
//  elapsedMs contract are pinned here through the injectable sink.
//

import Foundation
import Testing
@testable import OpenNOW

private final class RecordingStreamTelemetrySink: StreamTelemetrySink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [StreamTelemetryEvent] = []

    func capture(_ event: StreamTelemetryEvent) {
        lock.withLock { events.append(event) }
    }

    var captured: [StreamTelemetryEvent] {
        lock.withLock { events }
    }
}

private func gameModePreconditions(
    isGameModeKeyDeclared: Bool = true,
    applicationCategoryType: String = "public.app-category.games",
    isFrontmost: Bool = true,
    isAppleSilicon: Bool = true
) -> OPNStreamGameModePreconditions {
    OPNStreamGameModePreconditions(
        isGameModeKeyDeclared: isGameModeKeyDeclared,
        applicationCategoryType: applicationCategoryType,
        isFrontmost: isFrontmost,
        isAppleSilicon: isAppleSilicon
    )
}

@Suite("OPNStreamFullScreenTelemetry", .serialized)
struct OPNStreamFullScreenTelemetryTests {
    @Test("the plist key and category are read from the bundle dictionary")
    func readsEligibilityFromTheBundleDictionary() {
        let preconditions = OPNStreamGameModePreconditions.read(
            infoDictionary: [
                "LSSupportsGameMode": true,
                "LSApplicationCategoryType": "public.app-category.games",
            ],
            isFrontmost: true,
            isAppleSilicon: true
        )
        #expect(preconditions.isGameModeKeyDeclared)
        #expect(preconditions.applicationCategoryType == "public.app-category.games")
        #expect(preconditions.isFrontmost)
        #expect(preconditions.isAppleSilicon)
    }

    @Test("a missing key reads as undeclared rather than crashing")
    func missingKeyReadsAsUndeclared() {
        let preconditions = OPNStreamGameModePreconditions.read(
            infoDictionary: nil,
            isFrontmost: false,
            isAppleSilicon: false
        )
        #expect(!preconditions.isGameModeKeyDeclared)
        #expect(preconditions.applicationCategoryType.isEmpty)
        #expect(!preconditions.isFrontmost)
        #expect(!preconditions.isAppleSilicon)
    }

    @Test("eligibility attributes carry the four preconditions and never a game mode state")
    func eligibilityAttributesCarryTheFourPreconditions() {
        #expect(gameModePreconditions(isFrontmost: false).telemetryAttributes == [
            "supportsGameModeKey": "true",
            "applicationCategoryType": "public.app-category.games",
            "isFrontmost": "false",
            "isAppleSilicon": "true",
        ])
    }

    @Test("success attributes report eligibility alongside the landing")
    func successAttributesReportEligibilityAndLanding() {
        let attributes = OPNStreamFullScreenTelemetry.successAttributes(
            applicationID: "game-123",
            launchMode: "notification",
            enteredFullScreen: true,
            preconditions: gameModePreconditions()
        )
        #expect(attributes["applicationID"] == "game-123")
        #expect(attributes["launchMode"] == "notification")
        #expect(attributes["enteredFullScreen"] == "true")
        #expect(attributes["supportsGameModeKey"] == "true")
        #expect(attributes["applicationCategoryType"] == "public.app-category.games")
        #expect(attributes["isFrontmost"] == "true")
        #expect(attributes["isAppleSilicon"] == "true")
        #expect(attributes["gameMode"] == nil)
    }

    @Test("the manual toggle reports eligibility only when entering full screen")
    func toggleAttributesReportEligibilityOnlyWhenEntering() {
        let entering = OPNStreamFullScreenTelemetry.toggleAttributes(
            applicationID: "game-123",
            isEnteringFullScreen: true,
            preconditions: gameModePreconditions()
        )
        #expect(entering["fullScreen"] == "true")
        #expect(entering["supportsGameModeKey"] == "true")
        #expect(entering["isAppleSilicon"] == "true")

        let leaving = OPNStreamFullScreenTelemetry.toggleAttributes(
            applicationID: "game-123",
            isEnteringFullScreen: false,
            preconditions: gameModePreconditions()
        )
        #expect(leaving == ["applicationID": "game-123", "fullScreen": "false"])
    }

    @Test("the success event is captured at info with the landing attributes")
    func successEventIsCapturedAtInfo() {
        let sink = RecordingStreamTelemetrySink()
        OPNStreamTelemetry.configure(sink: sink)
        defer { OPNStreamTelemetry.configure(sink: nil) }

        OPNStreamFullScreenTelemetry.captureSuccess(
            applicationID: "game-123",
            launchMode: "notification",
            enteredFullScreen: true,
            preconditions: gameModePreconditions()
        )

        // The sink is process-global, so another suite emitting concurrently must not become this
        // test's subject.
        let event = sink.captured.first { $0.name == OPNStreamFullScreenTelemetry.successEventName }
        #expect(event?.name == OPNStreamFullScreenTelemetry.successEventName)
        #expect(event?.level == .info)
        #expect(event?.attributes["enteredFullScreen"] == "true")
    }

    @Test("the failure event is captured at warning with the reason and the budget")
    func failureEventIsCapturedAtWarning() {
        let sink = RecordingStreamTelemetrySink()
        OPNStreamTelemetry.configure(sink: sink)
        defer { OPNStreamTelemetry.configure(sink: nil) }

        OPNStreamFullScreenTelemetry.captureFailure(
            applicationID: "game-123",
            reason: .geometryDeferred,
            attemptCount: 200,
            elapsedMs: 10_012
        )

        let event = sink.captured.first { $0.name == OPNStreamFullScreenTelemetry.failureEventName }
        #expect(event?.name == OPNStreamFullScreenTelemetry.failureEventName)
        #expect(event?.level == .warning)
        #expect(event?.attributes["reason"] == "geometryDeferred")
        #expect(event?.attributes["attemptCount"] == "200")
        #expect(event?.attributes["elapsedMs"] == "10012")
        #expect(event?.attributes["applicationID"] == "game-123")
    }
}
