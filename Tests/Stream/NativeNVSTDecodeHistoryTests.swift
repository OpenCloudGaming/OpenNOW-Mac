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
}
