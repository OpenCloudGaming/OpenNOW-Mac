import Foundation
import Testing
@testable import OpenNOW

/// The gate the reported bug fell through: a manual check request must never disappear without a
/// visible outcome, and an automatic one must stay quiet when checks are suspended. The delegate
/// cannot be exercised directly because the test build compiles with `DEBUG`, where suspension is
/// permanently `true`; the coordinator takes both decisions as injected values.
@Suite(.serialized) @MainActor
struct UpdateCheckCoordinatorTests {
    @Test func aManualRequestWhileSuspendedSurfacesTheSuspension() {
        let recorder = UpdateCheckRecorder()
        let coordinator = makeCoordinator(suspended: true, check: { _ in
            Issue.record("A suspended check must not reach GitHub")
            return nil
        })
        recorder.attach(to: coordinator)

        coordinator.request(.manual)

        #expect(recorder.started == 0)
        #expect(recorder.records == [Recorded(outcome: .suspended, kind: .manual)])
    }

    @Test func anAutomaticRequestWhileSuspendedStaysSilent() {
        let recorder = UpdateCheckRecorder()
        let coordinator = makeCoordinator(suspended: true, check: { _ in
            Issue.record("A suspended check must not reach GitHub")
            return nil
        })
        recorder.attach(to: coordinator)

        coordinator.request(.automatic)

        #expect(recorder.started == 0)
        #expect(recorder.records.isEmpty)
    }

    @Test func anAutomaticRequestThatIsNotDueStaysSilent() {
        let recorder = UpdateCheckRecorder()
        let coordinator = makeCoordinator(automaticDue: false)
        recorder.attach(to: coordinator)

        coordinator.request(.automatic)

        #expect(recorder.started == 0)
        #expect(recorder.records.isEmpty)
    }

    @Test func aManualRequestDuringAnInFlightCheckIsCoalescedIntoOneFollowUp() async {
        let gate = UpdateCheckGate()
        var callCount = 0
        let recorder = UpdateCheckRecorder()
        let coordinator = makeCoordinator(check: { _ in
            callCount += 1
            if callCount == 1 { await gate.wait() }
            return nil
        })
        recorder.attach(to: coordinator)

        coordinator.request(.automatic)
        coordinator.request(.manual)
        gate.open()

        await waitFor { recorder.records.count == 2 }
        #expect(callCount == 2)
        // The in-flight automatic check still reports; the manual request runs a surfaced follow-up.
        #expect(recorder.records == [
            Recorded(outcome: .upToDate(version: "1.0.0"), kind: .automatic),
            Recorded(outcome: .upToDate(version: "1.0.0"), kind: .manual),
        ])
    }

    @Test func anAutomaticRequestDuringAnInFlightCheckIsNotQueued() async {
        var callCount = 0
        let recorder = UpdateCheckRecorder()
        let coordinator = makeCoordinator(check: { _ in
            callCount += 1
            return nil
        })
        recorder.attach(to: coordinator)

        coordinator.request(.automatic)
        coordinator.request(.automatic)

        await waitFor { !coordinator.isChecking && !recorder.records.isEmpty }
        #expect(callCount == 1)
        #expect(recorder.records.count == 1)
    }

    @Test func aManualRequestReportsTheInstallableRelease() async {
        let recorder = UpdateCheckRecorder()
        let release = makeRelease(version: "2.0.0")
        let coordinator = makeCoordinator(check: { _ in release })
        recorder.attach(to: coordinator)

        coordinator.request(.manual)

        await waitFor { !recorder.records.isEmpty }
        #expect(recorder.records == [Recorded(outcome: .available(release), kind: .manual)])
    }

    @Test func aManualRequestReportsAFailure() async {
        struct Failed: Error {}
        let recorder = UpdateCheckRecorder()
        let coordinator = makeCoordinator(check: { _ in throw Failed() })
        recorder.attach(to: coordinator)

        coordinator.request(.manual)

        await waitFor { !recorder.records.isEmpty }
        guard case .failed = recorder.records.first?.outcome else {
            Issue.record("Expected a surfaced failure, got \(String(describing: recorder.records))")
            return
        }
    }
}

private struct Recorded: Equatable {
    let outcome: OPNUpdateCheckCoordinator.Outcome
    let kind: OPNUpdateCheckCoordinator.Kind
}

@MainActor
private final class UpdateCheckRecorder {
    private(set) var records: [Recorded] = []
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var completed = 0

    func attach(to coordinator: OPNUpdateCheckCoordinator) {
        coordinator.onCheckStarted = { [weak self] in self?.started += 1 }
        coordinator.onCheckFinished = { [weak self] in self?.finished += 1 }
        coordinator.onCheckCompleted = { [weak self] in self?.completed += 1 }
        coordinator.onOutcome = { [weak self] outcome, kind in
            self?.records.append(Recorded(outcome: outcome, kind: kind))
        }
    }
}

/// Holds the first check open so a second request can land while it is in flight.
@MainActor
private final class UpdateCheckGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private func makeCoordinator(
    suspended: Bool = false,
    automaticDue: Bool = true,
    check: @escaping @MainActor (OPNUpdateChannel) async throws -> OPNGitHubRelease? = { _ in nil }
) -> OPNUpdateCheckCoordinator {
    OPNUpdateCheckCoordinator(
        minimumVisibility: .zero,
        sleep: { _ in },
        checkForUpdate: check,
        currentVersion: { "1.0.0" },
        updateChannel: { .stable },
        isSuspended: { suspended },
        shouldRunAutomaticCheck: { automaticDue }
    )
}

private func makeRelease(version: String) -> OPNGitHubRelease {
    OPNGitHubRelease(
        summary: OPNReleaseSummary(
            version: version,
            tagName: "v\(version)",
            releaseNotes: "Notes for \(version)",
            releaseURL: "https://example.invalid/v\(version)",
            publishedAt: nil,
            isPrerelease: false
        ),
        assetName: "OpenNOW-\(version)-macOS.zip",
        assetDownloadURL: "https://example.invalid/OpenNOW-\(version)-macOS.zip",
        assetByteCount: 1024
    )
}

@MainActor
private func waitFor(timeout: Duration = .seconds(4), _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "Timed out waiting for the coordinator to settle")
}
