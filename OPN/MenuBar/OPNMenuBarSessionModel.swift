import AppKit
import Combine
import Foundation
import Observation

/// The menu bar surface's state: what the status item shows, what the menu's session controls act
/// on, and which recent games it can relaunch.
///
/// The split of authority is deliberate. Streaming comes from `StreamSessionLifecycle` — the same
/// notification the rest of the app waits on — so the surface can never show a session that is not
/// running, or miss one that is. Everything before that (queued, connecting) comes from the launch
/// flow through `OPNMenuBarSessionSource`, pushed by change rather than polled.
@MainActor
final class OPNMenuBarSessionModel: ObservableObject {
    static let shared = OPNMenuBarSessionModel()

    @Published private(set) var phase: OPNMenuBarSessionPhase = .idle
    @Published private(set) var gameTitle = ""
    @Published private(set) var estimatedRemainingSeconds: TimeInterval?
    @Published private(set) var recentGames: [OPNMenuBarRecentGame] = []
    /// The moment the active stream reported itself. Held here rather than derived from the launch
    /// flow, so a session resumed by another surface still counts from when it actually started.
    @Published private(set) var streamStartedAt: Date?
    @Published private(set) var streamElapsedText: String?
    /// A resumable session this Mac can rejoin while nothing streams locally, named so the Resume tile
    /// can say what it would resume. Kept across a source detach, like the recent games, so closing
    /// the window to the tray does not lose it.
    @Published private(set) var resumableSessionTitle: String?

    /// A status item exists while windowless mode keeps the app reachable, and while there is a
    /// session to show — never as an idle decoration.
    ///
    /// Read-only on purpose. `MenuBarExtra` wants a two-way binding, and SwiftUI's own
    /// `MenuBarExtraController` writes back through it on every scene-graph change; a `@Published`
    /// publishes on every write, even one that changes nothing, so that write-back re-invalidated
    /// the App body and re-entered the menu bar configuration until the stack ran out (live
    /// capture: `MenuBarExtraController.observeValue` → `Binding.wrappedValue.setter` →
    /// `PublishedSubject.send` → `AttributeInvalidatingSubscriber`, thousands of times a second).
    @Published private(set) var isStatusItemInserted = false

    private let notificationCenter: NotificationCenter
    /// Released from `deinit`, which is nonisolated: the tokens are assigned only on the main actor,
    /// so the unchecked annotation covers that release rather than concurrent mutation.
    private nonisolated(unsafe) var streamLifecycleObserver: NSObjectProtocol?
    private nonisolated(unsafe) var preferencesObserver: NSObjectProtocol?
    private nonisolated(unsafe) var menuBarPreferencesObserver: NSObjectProtocol?
    /// Tokens for the popover window this session follows; released in `deinit`.
    private nonisolated(unsafe) var popoverObserverTokens: [NSObjectProtocol] = []
    private weak var source: (any OPNMenuBarSessionSource)?

    private var snapshotPhase: OPNMenuBarSessionPhase = .idle
    private var queueEstimate = OPNMenuBarQueueEstimate()
    private var trackingGeneration = 0
    private var pendingLaunch: OPNMenuBarRecentGame?
    /// A page asked for while no window can show it, drained when the next source attaches.
    private var pendingMainPage: OPNMainWindowPage?
    /// A Resume asked for while no window can perform it, drained when the next source attaches.
    private var isResumePending = false
    private var elapsedClockTask: Task<Void, Never>?

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        streamLifecycleObserver = notificationCenter.addObserver(
            forName: StreamSessionLifecycle.activeStreamDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resolvePhase()
            }
        }
        preferencesObserver = notificationCenter.addObserver(
            forName: OPNWindowClosePreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatusItemInsertion()
            }
        }
        menuBarPreferencesObserver = notificationCenter.addObserver(
            forName: OPNMenuBarPreferences.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshStatusItemInsertion()
            }
        }
        refreshStatusItemInsertion()
        OPNLog.info(.app, "Menu bar surface ready; \(OPNWindowClosePreferences.behavior.rawValue) closes the main window")
    }

    deinit {
        elapsedClockTask?.cancel()
        for token in popoverObserverTokens { notificationCenter.removeObserver(token) }
        if let streamLifecycleObserver { notificationCenter.removeObserver(streamLifecycleObserver) }
        if let preferencesObserver { notificationCenter.removeObserver(preferencesObserver) }
        if let menuBarPreferencesObserver { notificationCenter.removeObserver(menuBarPreferencesObserver) }
    }

    // MARK: - Session state

    var hasActiveStream: Bool {
        StreamSessionLifecycle.hasActiveStream
    }

    var canLaunchRecentGames: Bool {
        phase == .idle && !recentGames.isEmpty
    }

    func panelStatusText() -> String {
        OPNMenuBarReadout.panelStatusText(for: phase, estimatedSeconds: estimatedRemainingSeconds)
    }

    func accessibilityLabel(now: Date = Date()) -> String {
        OPNMenuBarReadout.spokenSummary(
            phase: phase,
            title: gameTitle,
            estimatedSeconds: estimatedRemainingSeconds,
            startedAt: streamStartedAt,
            now: now
        )
    }

    func attach(source: any OPNMenuBarSessionSource) {
        self.source = source
        trackSource()
        // The page first: a window built to answer a request opens where the request asked, and a
        // launch handed over beside it switches pages anyway.
        drainPendingMainPage()
        drainPendingLaunch()
    }

    /// Seeds the play history from persistence, for a launch that never built a window to push it.
    /// Skipped once a source owns the surface, because that source's list carries the artwork the
    /// seeder cannot resolve without the catalog.
    func primeRecentGames(_ games: [OPNMenuBarRecentGame]) {
        guard source == nil, recentGames.isEmpty, !games.isEmpty else { return }
        recentGames = games
    }

    /// Identity-checked: a window replacing another (an account switch, a window reopened) detaches
    /// after the replacement attaches often enough that a blind detach would leave the surface
    /// following nothing.
    ///
    /// The recent games are deliberately kept: they describe play history rather than the session, so
    /// closing the window to the tray must not empty the menu. The next source to attach overwrites
    /// them with its own account's list.
    func detachSource(_ source: any OPNMenuBarSessionSource) {
        guard self.source === source else { return }
        self.source = nil
        snapshotPhase = .idle
        gameTitle = ""
        resolvePhase()
    }

    // MARK: - Commands

    /// Every control routes through `StreamSessionLifecycle`, exactly as the in-app shortcuts do, so
    /// a session state cannot drift between the two surfaces.
    func send(_ command: StreamCommand) {
        _ = StreamSessionLifecycle.sendCommand(command)
    }

    func pauseSession() {
        OPNLog.info(.app, "Menu bar requested a pause of the active session")
        send(.pauseSession)
    }

    func endSession() {
        OPNLog.info(.app, "Menu bar requested the end of the active session")
        send(.endSession)
    }

    /// Whether the Resume tile has something to resume: a cloud seat detected while nothing streams.
    var canResumeSession: Bool {
        resumableSessionTitle != nil
    }

    /// Resuming asks the window that owns the launch flow, because the resume has to reach the vendor.
    /// With no window it is parked until one attaches, exactly like a recent-game launch.
    func resumeSession() {
        guard let source else {
            OPNLog.info(.app, "Menu bar parked a resume until a window exists")
            isResumePending = true
            return
        }
        source.resumeSession()
    }

    /// Opening the menu re-checks for a session started elsewhere; it is a no-op with no window, since
    /// the retained title is the best information available until a source attaches again.
    func refreshActiveSession() {
        source?.refreshActiveSession()
    }

    /// Follows the popover's window so each open re-checks for a resumable session. `MenuBarExtra`
    /// offers no per-open callback, and the popover window is reused rather than recreated, so the
    /// window itself is the signal. Called with the window the panel is hosted in.
    func observePopoverWindow(_ window: NSWindow?) {
        for token in popoverObserverTokens { notificationCenter.removeObserver(token) }
        popoverObserverTokens.removeAll()
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            let token = notificationCenter.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, window.occlusionState.contains(.visible) else { return }
                    self.refreshActiveSession()
                }
            }
            popoverObserverTokens.append(token)
        }
    }

    func quitApplication() {
        OPNLog.info(.app, "Menu bar requested application termination")
        NSApp.terminate(nil)
    }

    // MARK: - Quick launch

    /// A launch asked for while no window can perform it is parked until one can: the menu opens
    /// the main window, and the catalog acts on the request as it attaches.
    func requestLaunch(_ game: OPNMenuBarRecentGame) {
        guard let source else {
            OPNLog.info(.app, "Menu bar parked a launch of \(game.title) until a window exists")
            pendingLaunch = game
            return
        }
        source.launchRecentGame(game)
    }

    private func drainPendingLaunch() {
        guard let game = pendingLaunch, let source else { return }
        pendingLaunch = nil
        source.launchRecentGame(game)
    }

    // MARK: - Pages

    /// A page asked for from outside the window, parked until a window can show it — the same way a
    /// launch asked for from the Dock or the menu bar is.
    func requestMainPage(_ page: OPNMainWindowPage) {
        guard let source else {
            OPNLog.info(.app, "A surface parked a request for the \(page) page until a window exists")
            pendingMainPage = page
            return
        }
        source.showMainPage(page)
    }

    private func drainPendingMainPage() {
        guard let page = pendingMainPage, let source else { return }
        pendingMainPage = nil
        source.showMainPage(page)
    }

    /// Drained from `apply` rather than from `attach`: a window reopening from a parked resume has not
    /// fetched the active session yet, so the resume only becomes actionable once the snapshot names
    /// one.
    private func drainPendingResumeIfReady() {
        guard isResumePending, resumableSessionTitle != nil, let source else { return }
        isResumePending = false
        source.resumeSession()
    }

    // MARK: - State resolution

    private func trackSource() {
        guard let source else { return }
        trackingGeneration += 1
        let generation = trackingGeneration
        withObservationTracking {
            apply(source.menuBarSnapshot)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.trackingGeneration == generation else { return }
                self.trackSource()
            }
        }
    }

    private func apply(_ snapshot: OPNMenuBarSessionSnapshot) {
        snapshotPhase = snapshot.phase
        gameTitle = snapshot.title
        recentGames = snapshot.recentGames
        resumableSessionTitle = snapshot.resumableSessionTitle
        resolvePhase()
        drainPendingResumeIfReady()
    }

    private func resolvePhase(now: Date = Date()) {
        // A launch in flight outranks the lifecycle's active flag. The stream surface registers with
        // `StreamSessionLifecycle` as soon as it is mounted — which is before allocation finishes and
        // before the first frame — so the lifecycle reports a session while the launch is still
        // finding a server and while it sits in a queue. A queue position and the starting phase are
        // therefore drawn from the snapshot first, and only a quiet snapshot lets a live stream claim
        // the surface.
        switch snapshotPhase {
        case let .queued(position):
            stopElapsedClock()
            queueEstimate.observe(position: position, now: now)
            estimatedRemainingSeconds = queueEstimate.remainingSeconds(for: position)
            setPhase(.queued(position: position))
            return
        case .starting:
            stopElapsedClock()
            queueEstimate.reset()
            estimatedRemainingSeconds = nil
            setPhase(.starting)
            return
        case .idle, .connecting, .streaming:
            break
        }
        if hasActiveStream {
            startElapsedClock(at: now)
            queueEstimate.reset()
            estimatedRemainingSeconds = nil
            setPhase(.streaming)
            return
        }
        stopElapsedClock()
        queueEstimate.reset()
        estimatedRemainingSeconds = nil
        // A source never claims `starting` or `streaming` — those come from the launch in flight or
        // the lifecycle above — so a snapshot that somehow did has nothing behind it and reads as
        // idle. `connecting` is the launch flow's own pre-overlay state and stands on its own.
        setPhase(snapshotPhase == .connecting ? .connecting : .idle)
    }

    private func startElapsedClock(at start: Date) {
        guard streamStartedAt == nil else { return }
        streamStartedAt = start
        updateElapsedText(now: start)
        elapsedClockTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.updateElapsedText(now: Date())
            }
        }
    }

    private func updateElapsedText(now: Date) {
        guard let streamStartedAt else { return }
        let elapsedText = OPNMenuBarReadout.elapsedText(since: streamStartedAt, now: now)
        guard streamElapsedText != elapsedText else { return }
        streamElapsedText = elapsedText
    }

    private func stopElapsedClock() {
        guard streamStartedAt != nil else { return }
        elapsedClockTask?.cancel()
        elapsedClockTask = nil
        streamStartedAt = nil
        streamElapsedText = nil
    }

    private func setPhase(_ newPhase: OPNMenuBarSessionPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        refreshStatusItemInsertion()
    }

    private func refreshStatusItemInsertion() {
        let isInserted = OPNMenuBarPreferences.showsStatusItem
            && (OPNWindowClosePreferences.keepsApplicationRunning || phase != .idle)
        guard isStatusItemInserted != isInserted else { return }
        isStatusItemInserted = isInserted
        OPNLog.info(.app, "Menu bar status item \(isInserted ? "shown" : "hidden") phase=\(phase)")
    }
}
