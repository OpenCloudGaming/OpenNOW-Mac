import Combine
import Foundation
import Observation
import Testing
@testable import OpenNOW

/// The stats split's point is an observation boundary: the one-second tick invalidates the panels
/// that draw a reading, never the host model the whole stream surface observes.
@MainActor
struct NativeNVSTStreamStatsModelTests {
    private static func makePerformanceSnapshot() -> NativeNVSTPerformanceSnapshot {
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

    /// A stats tick used to re-evaluate the whole stream surface once a second. The host write is
    /// the positive control: a sink that was never wired up would pass this just as well.
    @Test func aStatsTickDoesNotInvalidateTheHostModel() {
        let (_, model) = makeHUDSurface()
        var hostPublished = false
        let subscription = model.objectWillChange.sink { hostPublished = true }

        model.unifiedHUDVisible.toggle()
        #expect(hostPublished, "the sink is not observing the host model at all")

        hostPublished = false
        model.stats.latestNativeStats = Self.makePerformanceSnapshot()
        model.stats.latestRenderDiagnostics = OPNVideoRenderDiagnosticsSnapshot()
        model.stats.isNativeBitrateStarved = true
        model.stats.nativeRigName = "GeForce RTX 5080"
        model.stats.nativeRigRawName = "5080h / B40"

        #expect(!hostPublished)
        withExtendedLifetime(subscription) {}
    }

    /// The other half of the boundary: the object the stats panels read still notifies them.
    @Test func aStatsTickStillNotifiesItsOwnReaders() {
        let stats = NativeNVSTStreamStatsModel()
        let changeRecorder = ObservationChangeRecorder()
        withObservationTracking {
            _ = stats.latestNativeStats
        } onChange: {
            changeRecorder.hasRecordedChange = true
        }
        stats.latestNativeStats = Self.makePerformanceSnapshot()
        #expect(changeRecorder.hasRecordedChange)
    }

    /// A rig name or a starvation verdict surviving teardown would describe the previous session.
    @Test func resettingASessionClearsEveryReading() {
        let stats = NativeNVSTStreamStatsModel()
        stats.latestNativeStats = Self.makePerformanceSnapshot()
        stats.latestRenderDiagnostics = OPNVideoRenderDiagnosticsSnapshot()
        stats.isNativeBitrateStarved = true
        stats.nativeRigName = "GeForce RTX 5080"
        stats.nativeRigRawName = "5080h / B40"

        stats.reset()

        #expect(stats.latestNativeStats == nil)
        #expect(stats.latestRenderDiagnostics == nil)
        #expect(!stats.isNativeBitrateStarved)
        #expect(stats.nativeRigName.isEmpty)
        #expect(stats.nativeRigRawName.isEmpty)
    }

    /// The microphone rows disable themselves off this Bool now that the `Task` is not published.
    @Test func anInFlightMicrophoneChangeStaysObservable() {
        let (_, model) = makeHUDSurface()
        #expect(!model.isMicrophoneUpdateInFlight)

        let updateTask = Task {}
        model.microphoneUpdateTask = updateTask
        #expect(model.isMicrophoneUpdateInFlight)

        model.microphoneUpdateTask = nil
        #expect(!model.isMicrophoneUpdateInFlight)
        updateTask.cancel()
    }

    /// `@Sendable` because `withObservationTracking`'s change handler is; the recorded change is
    /// made synchronously on this actor.
    private final class ObservationChangeRecorder: @unchecked Sendable {
        var hasRecordedChange = false
    }
}
