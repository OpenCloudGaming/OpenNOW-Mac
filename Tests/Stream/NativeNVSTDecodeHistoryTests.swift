import Foundation
import Testing
@testable import OpenNOW

struct NativeNVSTDecodeHistoryTests {
    @Test func staleFramesAreOnlyThoseBehindAQueuedKeyframe() {
        // No keyframe queued: keep decoding, late but moving.
        #expect(!NvstVideoPipeline.dropsStaleFrame(frameIndex: 100, latestSubmittedKeyframeIndex: nil))
        // A newer keyframe is queued: this frame would be replaced before anyone saw it.
        #expect(NvstVideoPipeline.dropsStaleFrame(frameIndex: 100, latestSubmittedKeyframeIndex: 140))
        // The keyframe queued is older than this frame: decode it.
        #expect(!NvstVideoPipeline.dropsStaleFrame(frameIndex: 141, latestSubmittedKeyframeIndex: 140))
    }

    @Test func decodeAdviceComesFromTheRecordAndSkipsShortSessions() {
        let colour = "10bit_444-test-\(UUID().uuidString)"
        let key = OPNStreamPreferences.streamShapeKey(codec: "H265", resolution: "5120x2160", colorQuality: colour)
        // Too short: the start-up burst would dominate the mean.
        OPNStreamPreferences.recordDecodeMeasurement(key: key, decodeMilliseconds: 11.75, negotiatedFps: 120, sessionSeconds: 5)
        #expect(OPNStreamPreferences.decodeAdvice(codec: "H265", resolution: "5120x2160", colorQualityLabel: "10-bit 4:4:4", colorQuality: colour, fps: 120).hasPrefix("Not measured"))
        // Long enough: 11.75 ms fits 85 fps, not 120.
        OPNStreamPreferences.recordDecodeMeasurement(key: key, decodeMilliseconds: 11.75, negotiatedFps: 120, sessionSeconds: 200)
        let advice = OPNStreamPreferences.decodeAdvice(codec: "H265", resolution: "5120x2160", colorQualityLabel: "10-bit 4:4:4", colorQuality: colour, fps: 120)
        #expect(advice.contains("11.8 ms"))
        #expect(advice.contains("fits about 85 fps, not 120"))
        let sixty = OPNStreamPreferences.decodeAdvice(codec: "H265", resolution: "5120x2160", colorQualityLabel: "10-bit 4:4:4", colorQuality: colour, fps: 60)
        #expect(sixty.contains("holds 60 fps"))
    }

    @Test func recommendationOrdersTiersByCostAndSaysWhatEachFits() {
        let records: [String: OPNStreamPreferences.DecodeMeasurement] = [
            "10bit_444": .init(decodeMilliseconds: 10.84, negotiatedFps: 120, measuredAt: Date()),
            "10bit_420": .init(decodeMilliseconds: 8.65, negotiatedFps: 120, measuredAt: Date()),
        ]
        let labels = ["10bit_444": "10-bit 4:4:4", "10bit_420": "10-bit 4:2:0"]
        let line = OPNStreamPreferences.decodeRecommendation(resolution: "5120x2160", codec: "H265", targetFps: 120, records: records, labels: labels)
        #expect(line == "Measured here at 5120x2160 H265: 10-bit 4:2:0 8.7 ms (fits ~115) · 10-bit 4:4:4 10.8 ms (fits ~92)")
        let sixty = OPNStreamPreferences.decodeRecommendation(resolution: "5120x2160", codec: "H265", targetFps: 60, records: records, labels: labels)
        #expect(sixty?.contains("10-bit 4:4:4 10.8 ms (holds 60)") == true)
        #expect(OPNStreamPreferences.decodeRecommendation(resolution: "5120x2160", codec: "H265", targetFps: 120, records: [:], labels: labels) == nil)
    }
}
