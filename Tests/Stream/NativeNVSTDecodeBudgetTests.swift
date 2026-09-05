import Foundation
import Testing
@testable import OpenNOW

struct NativeNVSTDecodeBudgetTests {
    private func snapshot(decode: Double, fps: Double, format: String = "10-bit 4:4:4") -> NativeNVSTPerformanceSnapshot {
        NativeNVSTPerformanceSnapshot(
            available: true, gameFramesPerSecond: -1, streamFramesPerSecond: 108, latencyMilliseconds: 5,
            jitterMilliseconds: 0.2, frameLoss: 0, totalFrameLoss: 0, packetLoss: 0, totalPacketLoss: 0,
            decodeMilliseconds: decode, bitrateMegabitsPerSecond: 60, bandwidthUtilizationPercent: 0,
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
}
