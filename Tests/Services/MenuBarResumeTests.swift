import Foundation
import Observation
import Testing
@testable import OpenNOW

/// The menu bar's Resume tile: a resumable session is offered and routed to the window that owns the
/// resume, and a resume asked for with no window is parked until the snapshot can act on it.
@MainActor @Suite(.serialized) struct MenuBarResumeTests {
    @Test func aResumableSessionOffersResumeAndRoutesItToTheWindow() async throws {
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        source.snapshot = OPNMenuBarSessionSnapshot(resumableSessionTitle: "Cyberpunk 2077")

        model.attach(source: source)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.canResumeSession)

        model.resumeSession()
        #expect(source.resumeRequests == 1)

        // The per-open refresh is handed to the window that owns the active-session lookup.
        model.refreshActiveSession()
        #expect(source.refreshRequests == 1)
    }

    @Test func resumeWithNoWindowParksUntilTheSnapshotNamesOne() async throws {
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()

        model.resumeSession()
        #expect(source.resumeRequests == 0)

        // The snapshot gains the session only after the reopened window fetches it, so the parked
        // resume drains from the applied snapshot rather than from attach.
        source.snapshot = OPNMenuBarSessionSnapshot(resumableSessionTitle: "Cyberpunk 2077")
        model.attach(source: source)
        #expect(source.resumeRequests == 1)
        model.attach(source: source)
        #expect(source.resumeRequests == 1)
    }
}
