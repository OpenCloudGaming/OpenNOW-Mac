import Testing
@testable import OpenNOW

@Test func nativeNVSTGovernorLeavesCongestionAdaptationToBifrost() {
    var governor = NativeNVSTNetworkGovernor(maximumBitrateKbps: 50_000, l4sEnabled: true)
    let congested = nativeGovernorSnapshot(latency: 130, jitter: 40, packetLoss: 1)

    #expect(governor.evaluate(congested).isEmpty)
    #expect(governor.evaluate(congested).isEmpty)
}

@Test func nativeNVSTGovernorDoesNotCompeteOnCumulativeCounterChanges() {
    var governor = NativeNVSTNetworkGovernor(maximumBitrateKbps: 50_000, l4sEnabled: false)
    let cumulativeLoss = nativeGovernorSnapshot(latency: 30, jitter: 2, packetLoss: 10_000)

    for _ in 0..<10 { #expect(governor.evaluate(cumulativeLoss).isEmpty) }
}

private func nativeGovernorSnapshot(latency: Double, jitter: Double, packetLoss: UInt64) -> NativeNVSTPerformanceSnapshot {
    NativeNVSTPerformanceSnapshot(available: true, gameFramesPerSecond: 60, streamFramesPerSecond: 60, latencyMilliseconds: latency, jitterMilliseconds: jitter, frameLoss: 0, totalFrameLoss: 0, packetLoss: packetLoss, totalPacketLoss: packetLoss, bitrateMegabitsPerSecond: 40, bandwidthUtilizationPercent: 70, resolution: "1920x1080", codec: "H264", serverLocation: "test")
}
