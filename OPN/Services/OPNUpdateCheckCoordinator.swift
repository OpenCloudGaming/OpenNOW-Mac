import Foundation

/// Owns the update-check request gate: whether a check may start, and what happens to a manual
/// request that arrives while one is running. The suspension and automatic-due predicates are
/// injected because `swift test` always compiles with suspension on.
@MainActor
final class OPNUpdateCheckCoordinator {
    /// `.automatic` checks stay silent when suspended or failed; `.manual` requests always surface.
    enum Kind: Equatable {
        case manual
        case automatic
    }

    enum Outcome: Equatable {
        case available(OPNGitHubRelease)
        case upToDate(version: String)
        case failed(message: String)
        case suspended
    }

    private let checkForUpdate: @MainActor (OPNUpdateChannel) async throws -> OPNGitHubRelease?
    private let currentVersion: @MainActor () -> String
    private let updateChannel: @MainActor () -> OPNUpdateChannel
    private let isSuspended: @MainActor () -> Bool
    private let shouldRunAutomaticCheck: @MainActor () -> Bool
    private let minimumVisibility: Duration
    private let sleep: @MainActor (Duration) async -> Void

    /// Fired synchronously when a request is admitted, so CHECKING… lands in the click's run loop.
    var onCheckStarted: (() -> Void)?
    var onCheckFinished: (() -> Void)?
    /// Reports a completed check's result. `kind` is the kind of the check that ran.
    var onOutcome: ((Outcome, Kind) -> Void)?
    /// Fired for every completed check, regardless of outcome: the `lastUpdateCheckDate` hook.
    var onCheckCompleted: (() -> Void)?

    private var checkTask: Task<Void, Never>?
    private var checkToken: UUID?
    private var isManualFollowUpPending = false

    init(
        minimumVisibility: Duration = .milliseconds(800),
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        checkForUpdate: @escaping @MainActor (OPNUpdateChannel) async throws -> OPNGitHubRelease?,
        currentVersion: @escaping @MainActor () -> String,
        updateChannel: @escaping @MainActor () -> OPNUpdateChannel,
        isSuspended: @escaping @MainActor () -> Bool,
        shouldRunAutomaticCheck: @escaping @MainActor () -> Bool
    ) {
        self.minimumVisibility = minimumVisibility
        self.sleep = sleep
        self.checkForUpdate = checkForUpdate
        self.currentVersion = currentVersion
        self.updateChannel = updateChannel
        self.isSuspended = isSuspended
        self.shouldRunAutomaticCheck = shouldRunAutomaticCheck
    }

    var isChecking: Bool { checkTask != nil }

    /// A suspended manual request reports why it could not run; a suspended automatic one is silent.
    /// A manual request during an in-flight check becomes one follow-up; an automatic one is dropped.
    func request(_ kind: Kind) {
        guard !isSuspended() else {
            surfaceSuspensionIfManual(kind)
            return
        }
        if kind == .automatic, !shouldRunAutomaticCheck() { return }
        guard checkTask == nil else {
            coalesceIfManual(kind)
            return
        }
        start(kind)
    }

    /// Stops an in-flight check and forgets a coalesced follow-up, for scheduling teardown.
    func cancel() {
        isManualFollowUpPending = false
        checkToken = nil
        checkTask?.cancel()
        checkTask = nil
        onCheckFinished?()
    }

    private func surfaceSuspensionIfManual(_ kind: Kind) {
        guard kind == .manual else { return }
        onOutcome?(.suspended, kind)
    }

    private func coalesceIfManual(_ kind: Kind) {
        guard kind == .manual else { return }
        isManualFollowUpPending = true
    }

    private func start(_ kind: Kind) {
        let token = UUID()
        checkToken = token
        onCheckStarted?()
        checkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = ContinuousClock.now
            let outcome = await self.runCheck()
            guard self.checkToken == token else { return }
            self.onOutcome?(outcome, kind)
            let elapsed = ContinuousClock.now - startedAt
            if elapsed < self.minimumVisibility {
                await self.sleep(self.minimumVisibility - elapsed)
            }
            guard self.checkToken == token else { return }
            self.onCheckCompleted?()
            self.finishCheck()
        }
    }

    private func finishCheck() {
        checkTask = nil
        checkToken = nil
        onCheckFinished?()
        guard isManualFollowUpPending else { return }
        isManualFollowUpPending = false
        request(.manual)
    }

    private func runCheck() async -> Outcome {
        do {
            guard let release = try await checkForUpdate(updateChannel()) else {
                return .upToDate(version: currentVersion())
            }
            return .available(release)
        } catch is CancellationError {
            return .failed(message: "The update check was interrupted.")
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }
}
