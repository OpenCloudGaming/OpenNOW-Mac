import Testing
import Foundation
@testable import OpenNOW

// The stall watchdog behind `nvst.stream.health.failed`. `available` is false until the first frame
// lands, so a running transport with no frame must still be sampled — see the delivery tests below.

/// `available` is the production flag for "a frame has been emitted at least once", so a running
/// transport that has delivered nothing is `available: false`.
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

    // A nil snapshot is the transport not being up yet, which says nothing about video.
    for _ in 0..<50 {
        #expect(monitor.observe(snapshot: nil, rendererReady: true) == nil)
    }
    #expect(monitor.zeroFrameStreak == 0)
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

    // The regression: rebuilding the monitor on a nil sample cleared the count, so a stall
    // punctuated by nil samples never reached the limit and no failure was ever reported.
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

@Test func aRunningTransportThatDeliveredNothingUsesTheFirstFrameBudget() {
    var monitor = NativeNVSTStreamHealthMonitor()

    // The production shape of a black screen: the transport is up, no frame has landed and not one
    // datagram reached the video socket. The stall budget cannot apply, because it never started.
    for _ in 0..<(monitor.firstFrameSampleLimit - 1) {
        #expect(monitor.observe(snapshot: snapshot(streamFps: 0, available: false), rendererReady: true) == nil)
    }
    #expect(monitor.zeroFrameStreak >= monitor.stalledSampleLimit)
    #expect(monitor.observe(snapshot: snapshot(streamFps: 0, available: false), rendererReady: true) == .firstFrameTimedOut)
}

@Test func aSilentVideoLegIsNotReportedAsAMissingRenderer() {
    var monitor = NativeNVSTStreamHealthMonitor()

    // A surface cannot report ready before a frame has rendered, so a not-ready renderer and a
    // silent transport are the same observation until video arrives. The delivery verdict is right.
    var failure: NativeNVSTStreamHealthFailure?
    for _ in 0..<monitor.firstFrameSampleLimit {
        failure = monitor.observe(snapshot: snapshot(streamFps: 0, available: false), rendererReady: false)
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

@Test func videoDeliveryVerdictsAreRecoveredInPlaceAndARendererFaultIsNot() {
    // The reconnect re-runs SETUP, ANNOUNCE, the punch and PLAY, so it can rebuild a media leg the
    // seat never wired up. A missing surface is local, so reconnecting cannot repair it.
    #expect(NativeNVSTStreamHealthFailure.firstFrameTimedOut.isRecoverableInPlace)
    #expect(NativeNVSTStreamHealthFailure.streamStalled.isRecoverableInPlace)
    #expect(NativeNVSTStreamHealthFailure.rendererUnavailable.isRecoverableInPlace == false)

    #expect(NativeNVSTStreamHealthFailure.firstFrameTimedOut.recoveryReason == "no-first-frame")
    #expect(NativeNVSTStreamHealthFailure.streamStalled.recoveryReason == "stall")
}
