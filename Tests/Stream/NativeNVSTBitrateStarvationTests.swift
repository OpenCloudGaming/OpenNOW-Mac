import Foundation
import Testing
@testable import OpenNOW

/// The HUD's "inbound bitrate is low" warning used to fire on any second under 5 Mbps, which on
/// NVST is every menu and every pause: the seat skips unchanged frames. These pin the rule that
/// replaced it.
struct NativeNVSTBitrateStarvationTests {
    private func snapshot(bitrate: Double, streamFps: Double, negotiatedFps: Double = 120, available: Bool = true,
                          lossPercent: Double = 0, jitter: Double = 1) -> NativeNVSTPerformanceSnapshot {
        NativeNVSTPerformanceSnapshot(
            available: available,
            gameFramesPerSecond: -1,
            streamFramesPerSecond: streamFps,
            latencyMilliseconds: 5,
            jitterMilliseconds: jitter,
            frameLoss: 0,
            totalFrameLoss: 0,
            packetLoss: 0,
            totalPacketLoss: 0,
            packetLossPercent: lossPercent,
            bitrateMegabitsPerSecond: bitrate,
            bandwidthUtilizationPercent: 0,
            resolution: "5120x2160",
            codec: "H265",
            serverLocation: "",
            negotiatedFramesPerSecond: negotiatedFps
        )
    }

    @Test func quietSceneAtFullFrameRateIsNotStarved() {
        // 0.4 Mbps on a static menu, frames still arriving at the negotiated rate.
        #expect(!NativeNVSTBitrateStarvationTracker.looksStarved(snapshot(bitrate: 0.4, streamFps: 119)))
    }

    /// Measured live 2026-09-04: a static Steam screen at 1.0 Mbps, 40 stream fps, game at 116,
    /// zero loss. Quiet, not starved.
    @Test func staticSceneWithLowFrameRateButNoLossIsNotStarved() {
        #expect(!NativeNVSTBitrateStarvationTracker.looksStarved(snapshot(bitrate: 1.0, streamFps: 40)))
    }

    @Test func lowBitrateCollapsingFrameRateAndLossLooksStarved() {
        #expect(NativeNVSTBitrateStarvationTracker.looksStarved(snapshot(bitrate: 2, streamFps: 40, lossPercent: 0.5)))
        #expect(NativeNVSTBitrateStarvationTracker.looksStarved(snapshot(bitrate: 2, streamFps: 40, jitter: 25)))
    }

    @Test func healthyBitrateIsNeverStarvedWhateverTheFrameRate() {
        #expect(!NativeNVSTBitrateStarvationTracker.looksStarved(snapshot(bitrate: 30, streamFps: 40)))
    }

    @Test func unknownNegotiatedRateOrUnavailableStatsNeverWarn() {
        #expect(!NativeNVSTBitrateStarvationTracker.looksStarved(snapshot(bitrate: 1, streamFps: 10, negotiatedFps: -1)))
        #expect(!NativeNVSTBitrateStarvationTracker.looksStarved(snapshot(bitrate: 1, streamFps: 10, available: false)))
    }

    @Test func warningNeedsTheShapeToPersist() {
        var tracker = NativeNVSTBitrateStarvationTracker()
        let start = Date()
        let starvedSample = snapshot(bitrate: 1, streamFps: 30, lossPercent: 1)
        let healthySample = snapshot(bitrate: 1, streamFps: 118)
        var verdicts: [Bool] = []
        verdicts.append(tracker.update(starvedSample, now: start))
        verdicts.append(tracker.update(starvedSample, now: start.addingTimeInterval(5)))
        verdicts.append(tracker.update(starvedSample, now: start.addingTimeInterval(10)))
        // One healthy sample clears it and restarts the clock.
        verdicts.append(tracker.update(healthySample, now: start.addingTimeInterval(11)))
        verdicts.append(tracker.update(starvedSample, now: start.addingTimeInterval(12)))
        verdicts.append(tracker.update(starvedSample, now: start.addingTimeInterval(21)))
        verdicts.append(tracker.update(starvedSample, now: start.addingTimeInterval(22)))
        #expect(verdicts == [false, false, true, false, false, false, true])
    }
}
