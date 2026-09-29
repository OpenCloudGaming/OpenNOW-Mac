import Foundation

/// Owns the update-check request gate: whether a check may start, and what happens to a manual
/// request that arrives while one is already running.
///
/// Split out of `OPNAppDelegate` for two reasons. The gate is the surface that was silently
/// dropping manual checks, and it cannot be exercised through the delegate: the test build compiles
/// with `DEBUG`, where `OPNUpdatePreferences.updateChecksAreSuspendedForDebugging` is always `true`,
/// so both sides of the suspension branch are unreachable from a test unless they are injected.
/// Injecting them is also what makes "manual while in flight" controllable without a network.
@MainActor
final class OPNUpdateCheckCoordinator {
    /// Why a check was asked for. `.automatic` checks stay silent on suspension and on failure;
    /// `.manual` requests are always surfaced one way or another.
    enum Kind: Equatable {
        case manual
        case automatic
    }

    /// The terminal state of a check that actually started, plus the one state for a request that
    /// never started because checks are suspended.
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

    /// Fired synchronously the moment a request is admitted, before the GitHub round-trip starts, so
    /// the button can show CHECKING… in the same run loop as the click that caused it.
    var onCheckStarted: (() -> Void)?
    var onCheckFinished: (() -> Void)?
    /// A check that completed and produced a result. `kind` is the kind of the check that ran.
    var onOutcome: ((Outcome, Kind) -> Void)?
    /// A check that ran to completion, regardless of outcome — the `lastUpdateCheckDate` hook.
    var onCheckCompleted: (() -> Void)?

    private var checkTask: Task<Void, Never>?
    private var currentToken: UUID?
    private var pendingManualCheck = false

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

    /// Admission and coalescing for one update-check request.
    ///
    /// - Suspended: a manual request reports `.suspended` so the user sees why nothing ran; an
    ///   automatic request returns without a trace, by design.
    /// - In flight: a manual request is remembered and runs once the current check finishes, so it
    ///   is coalesced rather than dropped. An automatic request is discarded; the running check
    ///   already covers it.
    func request(_ kind: Kind) {
        if isSuspended() {
            guard kind == .manual else { return }
            onOutcome?(.suspended, kind)
            return
        }
        if kind == .automatic, !shouldRunAutomaticCheck() { return }
        guard checkTask == nil else {
            if kind == .manual { pendingManualCheck = true }
            return
        }
        start(kind)
    }

    /// Stops an in-flight check and forgets any coalesced follow-up. Used at termination and when
    /// automatic scheduling is torn down.
    func cancel() {
        pendingManualCheck = false
        currentToken = nil
        checkTask?.cancel()
        checkTask = nil
        onCheckFinished?()
    }

    private func start(_ kind: Kind) {
        let token = UUID()
        currentToken = token
        onCheckStarted?()
        checkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let startedAt = ContinuousClock.now
            let outcome = await self.runCheck()
            guard self.currentToken == token else { return }
            self.onOutcome?(outcome, kind)
            // A cached or very fast check would flash the CHECKING state imperceptibly, so hold it
            // long enough to read and stamp the result so the UI can report when that last happened.
            let elapsed = ContinuousClock.now - startedAt
            if elapsed < self.minimumVisibility {
                await self.sleep(self.minimumVisibility - elapsed)
            }
            guard self.currentToken == token else { return }
            self.onCheckCompleted?()
            self.checkTask = nil
            self.currentToken = nil
            self.onCheckFinished?()
            if self.pendingManualCheck {
                self.pendingManualCheck = false
                self.request(.manual)
            }
        }
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
