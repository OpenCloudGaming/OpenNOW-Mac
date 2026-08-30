import Testing
import Foundation
@testable import OpenNOW

// The stall watchdog behind `nvst.stream.health.failed`. These pin the behaviour that made
// resetting the monitor on a nil snapshot a bug: its state has to survive gaps in the sample
// stream, because `performanceSnapshot()` returns nil whenever there is no active session — which
// is exactly what happens during a `.singleAttempt` recovery, when a stall is most likely.

private func snapshot(streamFps: Double, available: Bool = true) -> NativeNVSTPerformanceSnapshot {
    NativeNVSTPerformanceSnapshot(
        available: available,
        gameFramesPerSecond: streamFps,
        streamFramesPerSecond: streamFps,
        latencyMilliseconds: 20,
        jitterMilliseconds: 2,
        frameLoss: 0,
        totalFrameLoss: 0,
        packetLoss: 0,
        totalPacketLoss: 0,
        bitrateMegabitsPerSecond: 40,
        bandwidthUtilizationPercent: 50,
        resolution: "1920x1080",
        codec: "h264",
        serverLocation: "test"
    )
}

@Test func nilSnapshotsAreIgnoredRatherThanTreatedAsAStall() {
    var monitor = NativeNVSTStreamHealthMonitor()

    for _ in 0..<50 {
        #expect(monitor.observe(snapshot: nil, rendererReady: true) == nil)
    }
}

@Test func unavailableSnapshotsAreIgnoredToo() {
    var monitor = NativeNVSTStreamHealthMonitor()

    for _ in 0..<50 {
        #expect(monitor.observe(snapshot: snapshot(streamFps: 0, available: false), rendererReady: true) == nil)
    }
}

@Test func aStallTripsAfterTheStalledLimitOnceFramesHaveBeenSeen() {
    var monitor = NativeNVSTStreamHealthMonitor()
    #expect(monitor.observe(snapshot: snapshot(streamFps: 60), rendererReady: true) == nil)

    // One short of the limit: still healthy.
    for _ in 0..<(monitor.stalledSampleLimit - 1) {
        #expect(monitor.observe(snapshot: snapshot(streamFps: 0), rendererReady: true) == nil)
    }

    #expect(monitor.observe(snapshot: snapshot(streamFps: 0), rendererReady: true) == .streamStalled)
}

@Test func aStallStillTripsWhenNilSamplesInterleaveWithTheZeroFrameSamples() {
    var monitor = NativeNVSTStreamHealthMonitor()
    _ = monitor.observe(snapshot: snapshot(streamFps: 60), rendererReady: true)

    // This is the regression: a session reset mid-stall used to rebuild the monitor, clearing
    // `zeroFrameSamples`, so a stall punctuated by nil samples never reached the limit and the
    // stream hung with no failure ever reported.
    var failure: NativeNVSTStreamHealthFailure?
    for index in 0..<(monitor.stalledSampleLimit * 2) {
        if index % 3 == 1 {
            #expect(monitor.observe(snapshot: nil, rendererReady: true) == nil)
            continue
        }
        if let result = monitor.observe(snapshot: snapshot(streamFps: 0), rendererReady: true) {
            failure = result
            break
        }
    }

    #expect(failure == .streamStalled)
}

@Test func aStreamThatNeverDeliveredAFrameUsesTheLongerFirstFrameBudget() {
    var monitor = NativeNVSTStreamHealthMonitor()

    // Past the stall limit, but no frame has ever arrived, so the first-frame budget applies.
    for _ in 0..<monitor.stalledSampleLimit {
        #expect(monitor.observe(snapshot: snapshot(streamFps: 0), rendererReady: true) == nil)
    }

    var failure: NativeNVSTStreamHealthFailure?
    for _ in 0..<(monitor.firstFrameSampleLimit - monitor.stalledSampleLimit) {
        failure = monitor.observe(snapshot: snapshot(streamFps: 0), rendererReady: true)
    }

    #expect(failure == .firstFrameTimedOut)
}

@Test func aRecoveredFrameClearsTheStallCount() {
    var monitor = NativeNVSTStreamHealthMonitor()
    _ = monitor.observe(snapshot: snapshot(streamFps: 60), rendererReady: true)

    for _ in 0..<(monitor.stalledSampleLimit - 1) {
        _ = monitor.observe(snapshot: snapshot(streamFps: 0), rendererReady: true)
    }
    #expect(monitor.observe(snapshot: snapshot(streamFps: 60), rendererReady: true) == nil)

    // The count restarted, so one more zero sample is nowhere near the limit.
    #expect(monitor.observe(snapshot: snapshot(streamFps: 0), rendererReady: true) == nil)
}

@Test func aMissingRendererTripsOnItsOwnLimit() {
    var monitor = NativeNVSTStreamHealthMonitor()

    for _ in 0..<(monitor.rendererSampleLimit - 1) {
        #expect(monitor.observe(snapshot: snapshot(streamFps: 60), rendererReady: false) == nil)
    }

    #expect(monitor.observe(snapshot: snapshot(streamFps: 60), rendererReady: false) == .rendererUnavailable)
}
