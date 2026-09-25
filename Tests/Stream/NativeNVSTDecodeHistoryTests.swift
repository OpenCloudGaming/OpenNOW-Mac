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
        preferenceDomainTestLock.lock()
        let previousMeasurements = UserDefaults.standard.object(forKey: OPNStreamPreferences.Keys.decodeMeasurements)
        defer {
            UserDefaults.standard.set(previousMeasurements, forKey: OPNStreamPreferences.Keys.decodeMeasurements)
            preferenceDomainTestLock.unlock()
        }
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
        #expect(line?.tiers.map(\.label) == ["10-bit 4:2:0", "10-bit 4:4:4"])
        #expect(line?.tiers.map(\.millisecondsText) == ["8.7 ms", "10.8 ms"])
        #expect(line?.tiers.map(\.verdictText) == ["fits ~115 fps", "fits ~92 fps"])
        #expect(line?.tiers.map(\.holdsTargetFps) == [false, false])
        let sixty = OPNStreamPreferences.decodeRecommendation(resolution: "5120x2160", codec: "H265", targetFps: 60, records: records, labels: labels)
        #expect(sixty?.tiers.map(\.verdictText) == ["holds 60 fps", "holds 60 fps"])
        #expect(OPNStreamPreferences.decodeRecommendation(resolution: "5120x2160", codec: "H265", targetFps: 120, records: [:], labels: labels) == nil)
    }

    @Test func recommendationDropsTiersWithNoLabel() {
        let records: [String: OPNStreamPreferences.DecodeMeasurement] = [
            "10bit_444": .init(decodeMilliseconds: 10.84, negotiatedFps: 120, measuredAt: Date()),
            "10bit_444-test-\(UUID().uuidString)": .init(decodeMilliseconds: 4.2, negotiatedFps: 120, measuredAt: Date()),
        ]
        let labels = ["10bit_444": "10-bit 4:4:4"]
        let line = OPNStreamPreferences.decodeRecommendation(resolution: "5120x2160", codec: "H265", targetFps: 120, records: records, labels: labels)
        #expect(line?.tiers.map(\.label) == ["10-bit 4:4:4"])
    }

    @Test func storedMeasurementsIgnoreTiersThisBuildDoesNotOffer() {
        preferenceDomainTestLock.lock()
        let previousMeasurements = UserDefaults.standard.object(forKey: OPNStreamPreferences.Keys.decodeMeasurements)
        defer {
            UserDefaults.standard.set(previousMeasurements, forKey: OPNStreamPreferences.Keys.decodeMeasurements)
            preferenceDomainTestLock.unlock()
        }
        let seeded = "10bit_444-test-\(UUID().uuidString)"
        let seededKey = OPNStreamPreferences.streamShapeKey(codec: "H264", resolution: "9000x9000", colorQuality: seeded)
        OPNStreamPreferences.recordDecodeMeasurement(key: seededKey, decodeMilliseconds: 4.2, negotiatedFps: 120, sessionSeconds: 200)
        let measurements = OPNStreamPreferences.decodeMeasurements(resolution: "9000x9000", codec: "H264")
        #expect(measurements[seeded] == nil)
    }
}
