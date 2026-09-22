import Foundation
import Observation
import Testing
@testable import OpenNOW

/// The menu bar's `starting` phase: the window between a launch and its first frame.
///
/// It is separated from the main session suite because what it pins down is a precedence rule, not
/// the launch flow's own state: the stream surface registers with `StreamSessionLifecycle` as soon as
/// it is mounted — before allocation finishes — so the launch in flight has to outrank the lifecycle
/// or the surface reads streaming for the whole launch.
@MainActor @Suite(.serialized, .streamLifecycleExclusive) struct MenuBarStartingPhaseTests {
    private let preferencesKey = OPNWindowClosePreferences.behaviorKey

    private func preserveCloseBehavior() -> Any? {
        UserDefaults.standard.object(forKey: preferencesKey)
    }

    private func restoreCloseBehavior(_ existing: Any?) {
        if let existing {
            UserDefaults.standard.set(existing, forKey: preferencesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferencesKey)
        }
    }

    /// A stored behavior every test can start from without depending on the order it ran in.
    private func storeCloseBehavior(_ behavior: OPNWindowCloseBehavior) {
        UserDefaults.standard.set(behavior.rawValue, forKey: preferencesKey)
    }

    /// The model observes `NotificationCenter.default`, so a main-queue delivery needs the run loop
    /// to turn.
    private func waitForQueuedDelivery() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func aLaunchInFlightOutranksAMountedStreamSurface() async throws {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        storeCloseBehavior(.quitApplication)
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .starting, title: "Cyberpunk 2077")
        model.attach(source: source)
        defer { model.detachSource(source) }

        // The stream surface is already mounted and reporting the session while the launch is still
        // finding a server, so the snapshot's phase has to win.
        let id = UUID()
        StreamSessionLifecycle.activate(id, quitRequestHandler: { _ in true })
        defer { StreamSessionLifecycle.deactivate(id) }
        try await waitForQueuedDelivery()

        #expect(model.phase == .starting)
        #expect(model.panelStatusText() == "Starting stream…")
        #expect(model.streamStartedAt == nil)

        // A queue position is drawn even while the lifecycle reports the session as active.
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .queued(position: 3), title: "Cyberpunk 2077")
        try await waitForQueuedDelivery()
        #expect(model.phase == .queued(position: 3))
        #expect(model.estimatedRemainingSeconds != nil)

        // With the launch quiet and the session still active, the lifecycle owns the surface again.
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "Cyberpunk 2077")
        try await waitForQueuedDelivery()
        #expect(model.phase == .streaming)
        #expect(model.streamStartedAt != nil)
    }

    @Test func theStartingPhaseReadsDistinctlyFromTheOtherPhases() {
        #expect(OPNMenuBarSessionPhase.starting.symbolName != OPNMenuBarSessionPhase.queued(position: 1).symbolName)
        #expect(OPNMenuBarSessionPhase.starting.symbolName != OPNMenuBarSessionPhase.streaming.symbolName)
        #expect(OPNMenuBarReadout.panelStatusText(for: .starting, estimatedSeconds: nil) == "Starting stream…")
        #expect(OPNMenuBarReadout.detailText(for: .starting, estimatedSeconds: nil) == "Starting…")
        #expect(OPNMenuBarReadout.spokenSummary(phase: .starting, title: "Cyberpunk 2077", estimatedSeconds: nil, startedAt: nil, now: Date()) == "Cyberpunk 2077, starting")
    }
}
