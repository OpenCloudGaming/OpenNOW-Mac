import Testing
@testable import OpenNOW

@Test func nativeNVSTGovernorReducesBitrateAndDisablesL4SUnderSustainedCongestion() {
    var governor = NativeNVSTNetworkGovernor(maximumBitrateKbps: 50_000, l4sEnabled: true)
    let congested = nativeGovernorSnapshot(latency: 130, jitter: 40, packetLoss: 1)

    #expect(governor.evaluate(congested).isEmpty)
    #expect(governor.evaluate(congested) == [.maximumBitrateKbps(40_000), .dynamicStreamingMode(.preferFrameRate), .l4sEnabled(false)])
}

@Test func nativeNVSTGovernorRecoversBitrateAfterStableSamples() {
    var governor = NativeNVSTNetworkGovernor(maximumBitrateKbps: 50_000, l4sEnabled: false)
    let congested = nativeGovernorSnapshot(latency: 130, jitter: 40, packetLoss: 1)
    let stable = nativeGovernorSnapshot(latency: 30, jitter: 2, packetLoss: 0)
    _ = governor.evaluate(congested)
    _ = governor.evaluate(congested)
    for _ in 0..<4 { #expect(governor.evaluate(stable).isEmpty) }
    #expect(governor.evaluate(stable) == [.maximumBitrateKbps(45_000)])
}

private func nativeGovernorSnapshot(latency: Double, jitter: Double, packetLoss: UInt64) -> NativeNVSTPerformanceSnapshot {
    NativeNVSTPerformanceSnapshot(available: true, gameFramesPerSecond: 60, streamFramesPerSecond: 60, latencyMilliseconds: latency, jitterMilliseconds: jitter, frameLoss: 0, totalFrameLoss: 0, packetLoss: packetLoss, totalPacketLoss: packetLoss, bitrateMegabitsPerSecond: 40, bandwidthUtilizationPercent: 70, resolution: "1920x1080", codec: "H264", serverLocation: "test")
}
