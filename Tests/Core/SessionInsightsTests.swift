import Foundation
import Testing
@testable import OpenNOW

@Suite struct SessionInsightsTests {
    private func report(reason: StreamEndReason = .userRequested,
                        success: Bool = true,
                        duration: Double = 600,
                        message: String = "Native NVST stream ended by user.",
                        metadata: [String: String] = [:]) -> StreamReport {
        StreamReport(title: "Cyberpunk 2077",
                     success: success,
                     reason: reason,
                     message: message,
                     durationSeconds: duration,
                     metadata: metadata)
    }

    private func makeInsights(_ report: StreamReport) -> SessionInsights? {
        SessionInsights(report: report,
                        fallbackResolution: "1920x1080",
                        fallbackCodec: "h265",
                        fallbackFrameRate: 60)
    }

    @Test func summarisesAMeasuredNativeSession() throws {
        let report = report(metadata: [
            StreamInsightsKey.transport: "nvst",
            StreamInsightsKey.resolution: "2560x1440",
            StreamInsightsKey.codec: "av1",
            StreamInsightsKey.frameRate: "120",
            StreamInsightsKey.latencyMs: "24",
            StreamInsightsKey.bitrateMbps: "48.5",
            StreamInsightsKey.decodeMs: "6.2",
        ])
        let insights = try #require(makeInsights(report))
        #expect(insights.transportName == "Native NVST")
        #expect(insights.streamShapeText == "2560 × 1440  ·  120 FPS  ·  AV1")
        #expect(insights.outcome == .endedNormally)
        #expect(insights.metrics.contains { $0.id == StreamInsightsKey.latencyMs && $0.value == "24 ms" })
        #expect(insights.metrics.contains { $0.id == StreamInsightsKey.bitrateMbps && $0.value == "48.5 Mbps" })
    }

    @Test func omitsMetricsTheTransportDidNotMeasure() throws {
        let report = report(metadata: [StreamInsightsKey.transport: "webrtc"])
        let insights = try #require(makeInsights(report))
        #expect(insights.metrics.isEmpty)
        #expect(insights.outcome == .endedNormally)
        #expect(insights.guidance == "No decoder errors or lost frames were recorded.")
    }

    @Test func flagsDecoderErrorsAndDroppedFramesAsWarnings() throws {
        let report = report(metadata: [
            StreamInsightsKey.transport: "nvst",
            StreamInsightsKey.decoderErrors: "3",
            StreamInsightsKey.droppedFrames: "12",
        ])
        let insights = try #require(makeInsights(report))
        #expect(insights.outcome == .endedWithWarnings)
        #expect(insights.metrics.contains { $0.id == StreamInsightsKey.decoderErrors && $0.tone == .caution })
        #expect(insights.metrics.contains { $0.id == StreamInsightsKey.droppedFrames && $0.tone == .caution })
        #expect(insights.guidance == "The decoder reported 3 frame errors.")
    }

    @Test func fallsBackToTheConfiguredProfileForTheShape() throws {
        let insights = try #require(makeInsights(report()))
        #expect(insights.streamShapeText == "1920 × 1080  ·  60 FPS  ·  H265")
    }

    @Test func refusesAPausedOrZeroLengthSession() {
        #expect(makeInsights(report(reason: .paused, metadata: [:])) == nil)
        #expect(makeInsights(report(duration: 0, metadata: [:])) == nil)
    }

    @Test func reportsAFailedSessionWithItsOwnMessage() throws {
        let report = report(reason: .failed, success: false, message: "The seat refused the title.")
        let insights = try #require(makeInsights(report))
        #expect(insights.outcome == .failed)
        #expect(insights.guidance == "The seat refused the title.")
    }

    @Test func formatsDurationAcrossMinutesAndHours() {
        #expect(SessionInsights.durationText(seconds: 45) == "45s")
        #expect(SessionInsights.durationText(seconds: 750) == "12m 30s")
        #expect(SessionInsights.durationText(seconds: 3_780) == "1h 03m")
    }

    @Test func sessionInsightsAreEnabledByDefaultAndTheChoicePersists() {
        let key = OPNSessionInsightsPreferences.isEnabledKey
        let previous = OPNAppPreferenceStorage.standard.object(forKey: key)
        defer {
            if let previous {
                OPNAppPreferenceStorage.standard.set(previous, forKey: key)
            } else {
                OPNAppPreferenceStorage.standard.removeObject(forKey: key)
            }
        }

        OPNAppPreferenceStorage.standard.removeObject(forKey: key)
        #expect(OPNSessionInsightsPreferences.isEnabled)

        OPNSessionInsightsPreferences.isEnabled = false
        #expect(!OPNSessionInsightsPreferences.isEnabled)

        OPNSessionInsightsPreferences.isEnabled = true
        #expect(OPNSessionInsightsPreferences.isEnabled)
    }
}
