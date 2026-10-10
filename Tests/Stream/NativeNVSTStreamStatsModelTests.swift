import Combine
import Foundation
import Observation
import Testing
@testable import OpenNOW

/// The stats split's whole point is an observation boundary: the one-second tick must invalidate
/// only the panels that draw a reading, never the host model the whole stream surface observes.
/// These are the two halves of that contract.
@MainActor
struct NativeNVSTStreamStatsModelTests {
    private static func sample() -> NativeNVSTPerformanceSnapshot {
        NativeNVSTPerformanceSnapshot(available: true,
                                      gameFramesPerSecond: 60,
                                      streamFramesPerSecond: 60,
                                      latencyMilliseconds: 5,
                                      jitterMilliseconds: 1,
                                      frameLoss: 0,
                                      totalFrameLoss: 0,
                                      packetLoss: 0,
                                      totalPacketLoss: 0,
                                      bitrateMegabitsPerSecond: 40,
                                      bandwidthUtilizationPercent: 70,
                                      resolution: "1920x1080",
                                      codec: "H264",
                                      serverLocation: "test")
    }

    /// A stats tick used to fire the host model's `objectWillChange`, which re-evaluated the whole
    /// stream surface - the 563-line stats overlay among it - once a second. It must not any more.
    @Test func aStatsTickDoesNotPublishOnTheHostModel() {
        let (_, model) = makeHUDSurface()
        var hostPublished = false
        let subscription = model.objectWillChange.sink { hostPublished = true }

        model.stats.latestNativeStats = Self.sample()
        model.stats.latestRenderDiagnostics = OPNVideoRenderDiagnosticsSnapshot()
        model.stats.nativeBitrateStarved = true
        model.stats.nativeRigName = "GeForce RTX 5080"
        model.stats.nativeRigRawName = "5080h / B40"

        #expect(!hostPublished)
        withExtendedLifetime(subscription) {}
    }

    /// The other half: the object the stats panels read still notifies them, so the tick is drawn.
    @Test func aStatsTickNotifiesItsOwnReaders() {
        let stats = NativeNVSTStreamStatsModel()
        let notified = Flag()
        withObservationTracking {
            _ = stats.latestNativeStats
        } onChange: {
            notified.value = true
        }
        stats.latestNativeStats = Self.sample()
        #expect(notified.value)
    }

    /// Teardown and reconnect both start from blank, and every reading has to go with them - a rig
    /// name or a starvation verdict surviving into the next session would be about the last one.
    @Test func resetClearsEveryReading() {
        let stats = NativeNVSTStreamStatsModel()
        stats.latestNativeStats = Self.sample()
        stats.latestRenderDiagnostics = OPNVideoRenderDiagnosticsSnapshot()
        stats.nativeBitrateStarved = true
        stats.nativeRigName = "GeForce RTX 5080"
        stats.nativeRigRawName = "5080h / B40"

        stats.reset()

        #expect(stats.latestNativeStats == nil)
        #expect(stats.latestRenderDiagnostics == nil)
        #expect(!stats.nativeBitrateStarved)
        #expect(stats.nativeRigName.isEmpty)
        #expect(stats.nativeRigRawName.isEmpty)
    }

    /// The HUD disables its microphone rows while a change is in flight, and that has to stay
    /// observable now that the `Task` itself is not published.
    @Test func anInFlightMicrophoneChangeIsPublishedAsABoolean() {
        let (_, model) = makeHUDSurface()
        #expect(!model.isMicrophoneUpdateInFlight)

        let task = Task {}
        model.microphoneUpdateTask = task
        #expect(model.isMicrophoneUpdateInFlight)

        model.microphoneUpdateTask = nil
        #expect(!model.isMicrophoneUpdateInFlight)
        task.cancel()
    }

    /// `@Sendable` because `withObservationTracking`'s change handler is; the change it reports is
    /// made synchronously on this actor.
    private final class Flag: @unchecked Sendable {
        var value = false
    }
}
