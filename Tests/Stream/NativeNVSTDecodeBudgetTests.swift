import Foundation
import Testing
@testable import OpenNOW

struct NativeNVSTDecodeBudgetTests {
    private func snapshot(decode: Double, fps: Double, format: String = "10-bit 4:4:4",
                          decodeP99: Double = -1, streamFramesPerSecond: Double = 108) -> NativeNVSTPerformanceSnapshot {
        NativeNVSTPerformanceSnapshot(
            available: true, gameFramesPerSecond: -1, streamFramesPerSecond: streamFramesPerSecond, latencyMilliseconds: 5,
            jitterMilliseconds: 0.2, frameLoss: 0, totalFrameLoss: 0, packetLoss: 0, totalPacketLoss: 0,
            decodeMilliseconds: decode, decodeP99Milliseconds: decodeP99, bitrateMegabitsPerSecond: 60, bandwidthUtilizationPercent: 0,
            resolution: "5120x2160", codec: "H265", serverLocation: "", negotiatedFramesPerSecond: fps,
            bitstreamFormat: format
        )
    }

    @Test func levelsFollowTheNegotiatedFrameInterval() {
        // Measured 2026-09-04: 4:2:0 at 7.7 ms fits a 120 fps frame, 4:4:4 at 10.0 ms does not.
        #expect(NativeNVSTDecodeBudget.level(decodeMilliseconds: 7.7, framesPerSecond: 120) == .tight)
        #expect(NativeNVSTDecodeBudget.level(decodeMilliseconds: 6.0, framesPerSecond: 120) == .comfortable)
        #expect(NativeNVSTDecodeBudget.level(decodeMilliseconds: 10.0, framesPerSecond: 120) == .over)
        // The same 10 ms is comfortable at 60.
        #expect(NativeNVSTDecodeBudget.level(decodeMilliseconds: 10.0, framesPerSecond: 60) == .comfortable)
        #expect(NativeNVSTDecodeBudget.level(decodeMilliseconds: -1, framesPerSecond: 120) == .unknown)
        #expect(NativeNVSTDecodeBudget.level(decodeMilliseconds: 5, framesPerSecond: -1) == .unknown)
    }

    @Test func warningNamesTheFormatAndTheNumbers() {
        let warning = NativeNVSTDecodeBudget.warning(for: snapshot(decode: 10.02, fps: 120))
        #expect(warning?.contains("10-bit 4:4:4") == true)
        #expect(warning?.contains("60 Mbps") == true)
        #expect(warning?.contains("10.0 ms") == true)
        #expect(warning?.contains("8.3 ms") == true)
        #expect(warning?.contains("4:2:0") == true)
        // 4:2:0 already: the format is not the lever, so it is not offered as one.
        let fourTwoZero = NativeNVSTDecodeBudget.warning(for: snapshot(decode: 9.4, fps: 120, format: "10-bit 4:2:0"))
        #expect(fourTwoZero?.contains("bitrate cap") == true)
        #expect(fourTwoZero?.contains("or 4:2:0") == false)
        #expect(NativeNVSTDecodeBudget.warning(for: snapshot(decode: 7.7, fps: 120)) == nil)
    }

    // A mean under budget with a bad tail is exactly the choppiness-on-motion case: the mean says
    // fine, the p99 says otherwise, and it's the p99 that must win the classification.
    @Test func p99OverridesAComfortableMeanWhenTailIsBad() {
        #expect(NativeNVSTDecodeBudget.level(for: snapshot(decode: 6.0, fps: 120, decodeP99: 20.0)) == .over)
        #expect(NativeNVSTDecodeBudget.representativeDecodeMilliseconds(for: snapshot(decode: 6.0, fps: 120, decodeP99: 20.0)) == 20.0)
    }

    // Before enough frames exist for a p99 (-1, the documented "unavailable" sentinel), the mean
    // is the whole reading — same behaviour as before p99 existed.
    @Test func meanIsTheFallbackWhenP99IsUnavailable() {
        #expect(NativeNVSTDecodeBudget.level(for: snapshot(decode: 10.0, fps: 120, decodeP99: -1)) == .over)
        #expect(NativeNVSTDecodeBudget.representativeDecodeMilliseconds(for: snapshot(decode: 10.0, fps: 120, decodeP99: -1)) == 10.0)
    }

    // Classification stays keyed to the negotiated rate — the seat may already have throttled
    // delivery down to match a slow decoder, and judging against that throttled rate would call
    // the throttle "comfortable". The delivered rate still appears, but only as context.
    @Test func warningNamesTheDeliveredRateWithoutChangingTheVerdict() {
        let warning = NativeNVSTDecodeBudget.warning(for: snapshot(decode: 10.02, fps: 120, streamFramesPerSecond: 85))
        #expect(warning?.contains("Delivering ~85 fps now.") == true)
        #expect(NativeNVSTDecodeBudget.level(for: snapshot(decode: 10.02, fps: 120, streamFramesPerSecond: 85)) == .over)
    }
}
