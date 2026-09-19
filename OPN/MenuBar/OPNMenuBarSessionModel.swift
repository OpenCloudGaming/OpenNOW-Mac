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
    private weak var source: (any OPNMenuBarSessionSource)?

    private var snapshotPhase: OPNMenuBarSessionPhase = .idle
    private var queueEstimate = OPNMenuBarQueueEstimate()
    private var trackingGeneration = 0
    private var pendingLaunch: OPNMenuBarRecentGame?

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

    func statusDetailText() -> String? {
        OPNMenuBarReadout.detailText(for: phase, estimatedSeconds: estimatedRemainingSeconds)
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
        drainPendingLaunch()
    }

    /// Identity-checked: a window replacing another (an account switch, a window reopened) detaches
    /// after the replacement attaches often enough that a blind detach would leave the surface
    /// following nothing.
    func detachSource(_ source: any OPNMenuBarSessionSource) {
        guard self.source === source else { return }
        self.source = nil
        snapshotPhase = .idle
        gameTitle = ""
        recentGames = []
        resolvePhase()
    }

    // MARK: - Commands

    /// Every control routes through `StreamSessionLifecycle`, exactly as the in-app shortcuts do, so
    /// a microphone or recording state cannot drift between the two surfaces.
    func send(_ command: StreamCommand) {
        _ = StreamSessionLifecycle.sendCommand(command)
    }

    func toggleMicrophone() {
        OPNLog.info(.app, "Menu bar toggled the stream microphone")
        send(.toggleMicrophone)
    }

    func toggleRecording() {
        OPNLog.info(.app, "Menu bar toggled stream recording")
        send(.toggleRecording)
    }

    func endSession() {
        OPNLog.info(.app, "Menu bar requested the end of the active session")
        send(.endSession)
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
        resolvePhase()
    }

    private func resolvePhase(now: Date = Date()) {
        if hasActiveStream {
            if streamStartedAt == nil { streamStartedAt = now }
            queueEstimate.reset()
            estimatedRemainingSeconds = nil
            setPhase(.streaming)
            return
        }
        streamStartedAt = nil
        switch snapshotPhase {
        case let .queued(position):
            queueEstimate.observe(position: position, now: now)
            estimatedRemainingSeconds = queueEstimate.remainingSeconds(for: position)
        case .idle, .connecting, .streaming:
            queueEstimate.reset()
            estimatedRemainingSeconds = nil
        }
        // A source never claims `streaming` — that comes from the lifecycle above — so a snapshot
        // that somehow did would describe a session this surface cannot reach, and reads as idle.
        setPhase(snapshotPhase == .streaming ? .idle : snapshotPhase)
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
