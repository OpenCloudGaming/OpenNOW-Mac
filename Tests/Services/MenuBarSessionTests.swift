import AppKit
import Foundation
import Observation
import Testing
@testable import OpenNOW

/// The menu bar surface: the windowless preference, the queue projection, the readout wording, and
/// the model that mixes the launch flow's pushed state with the stream lifecycle's notification.
///
/// One serialized suite: every test here reads or writes the same preference key, and Swift Testing
/// does not serialize two suites against each other.
@MainActor @Suite(.serialized) struct MenuBarSessionTests {
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

    private let menuBarItemKey = OPNMenuBarPreferences.showsStatusItemKey

    private func preserveMenuBarItem() -> Any? {
        UserDefaults.standard.object(forKey: menuBarItemKey)
    }

    private func restoreMenuBarItem(_ existing: Any?) {
        if let existing {
            UserDefaults.standard.set(existing, forKey: menuBarItemKey)
        } else {
            UserDefaults.standard.removeObject(forKey: menuBarItemKey)
        }
    }

    /// The model observes `NotificationCenter.default` so the tests exercise the real posting path;
    /// a main-queue delivery needs the run loop to turn.
    private func waitForQueuedDelivery() async throws {
        try await Task.sleep(for: .milliseconds(50))
    }

    @Test func unsetCloseBehaviorClosesTheWindowAndKeepsRunning() {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        UserDefaults.standard.removeObject(forKey: preferencesKey)
        #expect(OPNWindowClosePreferences.behavior == .keepRunningInDock)
        #expect(OPNWindowClosePreferences.keepsApplicationRunning)
    }

    @Test func unknownStoredCloseBehaviorFallsBackToKeepingRunning() {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        UserDefaults.standard.set("hide-everywhere", forKey: preferencesKey)
        #expect(OPNWindowClosePreferences.behavior == .keepRunningInDock)
    }

    @Test func closeBehaviorRoundTripsAndAnnouncesItself() {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        storeCloseBehavior(.quitApplication)
        let counter = AnnouncementCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: OPNWindowClosePreferences.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in counter.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        OPNWindowClosePreferences.behavior = .keepRunningInDock
        #expect(OPNWindowClosePreferences.behavior == .keepRunningInDock)
        #expect(OPNWindowClosePreferences.keepsApplicationRunning)
        #expect(counter.count == 1)

        // Writing the same value again is not a change and must not republish it.
        OPNWindowClosePreferences.behavior = .keepRunningInDock
        #expect(counter.count == 1)

        OPNWindowClosePreferences.behavior = .quitApplication
        #expect(!OPNWindowClosePreferences.keepsApplicationRunning)
        #expect(counter.count == 2)
    }

    @Test func queueEstimateProjectsWhatTheQueueHasActuallyDone() {
        var estimate = OPNMenuBarQueueEstimate()
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(estimate.remainingSeconds(for: 0) == nil)
        // Nothing measured yet: the documented fallback, projected onto the positions left.
        #expect(estimate.remainingSeconds(for: 2) == 90)

        // Two positions in sixty seconds is thirty seconds a seat, which the readout rounds to the
        // half minute it can stand behind.
        estimate.observe(position: 4, now: start)
        estimate.observe(position: 2, now: start.addingTimeInterval(60))
        #expect(estimate.remainingSeconds(for: 2) == 60)

        // A seat that moved again converges rather than jumping.
        estimate.observe(position: 1, now: start.addingTimeInterval(90))
        #expect(estimate.remainingSeconds(for: 1) == 30)

        estimate.reset()
        #expect(estimate.remainingSeconds(for: 2) == 90)
    }

    @Test func queueEstimateIgnoresStallsAndEmptyQueues() {
        var estimate = OPNMenuBarQueueEstimate()
        let start = Date(timeIntervalSince1970: 2_000)

        // A position that did not move, then one that moved backwards, teaches nothing: the readout
        // stays on the fallback.
        estimate.observe(position: 3, now: start)
        estimate.observe(position: 3, now: start.addingTimeInterval(30))
        estimate.observe(position: 4, now: start.addingTimeInterval(60))
        #expect(estimate.remainingSeconds(for: 3) == 150)

        estimate.observe(position: 0, now: start.addingTimeInterval(90))
        #expect(estimate.remainingSeconds(for: 0) == nil)
    }

    @Test func readoutNamesEveryPhase() {
        #expect(OPNMenuBarReadout.titleText("  ") == "OpenNOW")
        #expect(OPNMenuBarReadout.titleText(" Cyberpunk 2077 ") == "Cyberpunk 2077")

        // The popover has no title line to fall back to: no game, no name.
        #expect(OPNMenuBarReadout.panelTitleText("  ") == nil)
        #expect(OPNMenuBarReadout.panelTitleText(" Cyberpunk 2077 ") == "Cyberpunk 2077")

        #expect(OPNMenuBarReadout.detailText(for: .idle, estimatedSeconds: nil) == nil)
        #expect(OPNMenuBarReadout.detailText(for: .streaming, estimatedSeconds: nil) == nil)
        #expect(OPNMenuBarReadout.detailText(for: .connecting, estimatedSeconds: nil) == "Connecting…")
        #expect(OPNMenuBarReadout.detailText(for: .queued(position: 3), estimatedSeconds: nil) == "Queue #3")
        #expect(OPNMenuBarReadout.detailText(for: .queued(position: 3), estimatedSeconds: 120) == "Queue #3 · ~2 min")
    }

    @Test func readoutFormatsElapsedAndSpokenDurations() {
        let start = Date(timeIntervalSince1970: 5_000)
        #expect(OPNMenuBarReadout.elapsedText(since: start, now: start) == "0:00")
        #expect(OPNMenuBarReadout.elapsedText(since: start, now: start.addingTimeInterval(754)) == "12:34")
        #expect(OPNMenuBarReadout.elapsedText(since: start, now: start.addingTimeInterval(3_725)) == "1:02:05")
        // A stamp from the future never reads as a negative clock.
        #expect(OPNMenuBarReadout.elapsedText(since: start, now: start.addingTimeInterval(-30)) == "0:00")

        #expect(OPNMenuBarReadout.durationText(seconds: 45) == "~45 sec")
        #expect(OPNMenuBarReadout.durationText(seconds: 120) == "~2 min")
        #expect(OPNMenuBarReadout.spokenDuration(seconds: 90) == "1 minute 30 seconds")
        #expect(OPNMenuBarReadout.spokenDuration(seconds: 3_600) == "1 hour")
    }

    @Test func spokenSummaryReadsAsASentence() {
        let start = Date(timeIntervalSince1970: 9_000)
        #expect(OPNMenuBarReadout.spokenSummary(phase: .idle, title: "", estimatedSeconds: nil, startedAt: nil, now: start) == "OpenNOW, no session")
        #expect(OPNMenuBarReadout.spokenSummary(phase: .connecting, title: "Manor Lords", estimatedSeconds: nil, startedAt: nil, now: start) == "Manor Lords, connecting")
        #expect(
            OPNMenuBarReadout.spokenSummary(phase: .queued(position: 4), title: "Manor Lords", estimatedSeconds: 60, startedAt: nil, now: start)
                == "Manor Lords, in queue at position 4, about 1 minute to go"
        )
        #expect(
            OPNMenuBarReadout.spokenSummary(phase: .streaming, title: "Manor Lords", estimatedSeconds: nil, startedAt: start, now: start.addingTimeInterval(125))
                == "Manor Lords, streaming, 2 minutes 5 seconds elapsed"
        )
    }

    @Test func unsetMenuBarItemShowsTheItem() {
        let existing = preserveMenuBarItem()
        defer { restoreMenuBarItem(existing) }

        UserDefaults.standard.removeObject(forKey: menuBarItemKey)
        #expect(OPNMenuBarPreferences.showsStatusItem)
    }

    @Test func menuBarItemOptOutRoundTripsAndAnnouncesItself() {
        let existing = preserveMenuBarItem()
        defer { restoreMenuBarItem(existing) }

        OPNMenuBarPreferences.showsStatusItem = true
        let counter = AnnouncementCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: OPNMenuBarPreferences.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in counter.count += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        OPNMenuBarPreferences.showsStatusItem = false
        #expect(!OPNMenuBarPreferences.showsStatusItem)
        #expect(counter.count == 1)

        // Writing the same value again is not a change and must not republish it.
        OPNMenuBarPreferences.showsStatusItem = false
        #expect(counter.count == 1)
    }

    @Test func optedOutMenuBarItemHidesTheItemEvenInASession() async throws {
        let closeExisting = preserveCloseBehavior()
        let menuBarExisting = preserveMenuBarItem()
        defer {
            restoreCloseBehavior(closeExisting)
            restoreMenuBarItem(menuBarExisting)
        }

        storeCloseBehavior(.quitApplication)
        OPNMenuBarPreferences.showsStatusItem = false
        let model = OPNMenuBarSessionModel()
        #expect(!model.isStatusItemInserted)

        // A session is the case the opt-out has to survive: it is the one the item would otherwise
        // appear for.
        let id = UUID()
        StreamSessionLifecycle.activate(id, quitRequestHandler: { _ in true })
        defer { StreamSessionLifecycle.deactivate(id) }
        try await waitForQueuedDelivery()
        #expect(model.phase == .streaming)
        #expect(!model.isStatusItemInserted)

        // Turning it back on brings the item to the running session without a relaunch.
        OPNMenuBarPreferences.showsStatusItem = true
        try await waitForQueuedDelivery()
        #expect(model.isStatusItemInserted)
    }

    @Test func menuBarOnlyChoiceIsUnavailableWhileTheMenuBarItemIsOff() {
        let closeExisting = preserveCloseBehavior()
        let menuBarExisting = preserveMenuBarItem()
        defer {
            restoreCloseBehavior(closeExisting)
            restoreMenuBarItem(menuBarExisting)
        }

        // Menu-bar-only mode withdraws the app from the Dock, so the menu bar item is the only way
        // back to it; the combination that has neither is not offered.
        storeCloseBehavior(.menuBarOnly)
        OPNMenuBarPreferences.showsStatusItem = false
        #expect(OPNWindowClosePreferences.behavior == .keepRunningInDock)
        #expect(OPNWindowClosePreferences.keepsApplicationRunning)

        // The stored choice is only withheld, not rewritten: turning the item back on restores it.
        OPNMenuBarPreferences.showsStatusItem = true
        #expect(OPNWindowClosePreferences.behavior == .menuBarOnly)

        // Keeping the Dock icon needs nothing, so it stands with the menu bar item off.
        storeCloseBehavior(.keepRunningInDock)
        OPNMenuBarPreferences.showsStatusItem = false
        #expect(OPNWindowClosePreferences.behavior == .keepRunningInDock)
    }

    @Test func lastWindowCloseFollowsTheCloseBehavior() {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        let delegate = OPNAppDelegate()
        for behavior in OPNWindowCloseBehavior.allCases {
            storeCloseBehavior(behavior)
            #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared) == !behavior.keepsApplicationRunning)
        }
    }

    @Test func statusItemExistsOnlyForAKeepRunningChoiceOrASession() async throws {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        storeCloseBehavior(.quitApplication)
        let model = OPNMenuBarSessionModel()
        #expect(!model.isStatusItemInserted)

        // Either keep-running choice is enough on its own: with no window there would otherwise be
        // no way back to the app.
        for behavior in OPNWindowCloseBehavior.allCases where behavior.keepsApplicationRunning {
            OPNWindowClosePreferences.behavior = behavior
            try await waitForQueuedDelivery()
            #expect(model.isStatusItemInserted)
        }

        OPNWindowClosePreferences.behavior = .quitApplication
        try await waitForQueuedDelivery()
        #expect(!model.isStatusItemInserted)
    }

    @Test func guardWaitsForTheWindowsOwnerBeforeClaimingIt() {
        // The delegate slot is never taken while SwiftUI is still setting the window up: doing that
        // leaves the window created but never presented, which reads as a launch with no window at
        // all (live-verified freeze). A window with no delegate and nothing on screen is still being
        // set up, so the guard leaves it alone.
        let unclaimed = makeMainWindow()
        OPNMainWindowCloseGuard.install(on: unclaimed)
        #expect(unclaimed.delegate == nil)

        // Once the owner has claimed the window, the guard takes the slot in front of it.
        let claimed = makeMainWindow()
        let owner = RecordingWindowDelegate()
        claimed.delegate = owner
        OPNMainWindowCloseGuard.install(on: claimed)
        defer { OPNMainWindowCloseGuard.uninstall() }
        #expect(claimed.delegate is OPNMainWindowCloseDelegateProxy)
    }

    @Test func guardAnswersTheCloseButtonForEachChoice() {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        let window = makeMainWindow()
        let owner = RecordingWindowDelegate()
        window.delegate = owner
        defer { withExtendedLifetime(owner) {} }
        OPNMainWindowCloseGuard.install(on: window)
        defer { OPNMainWindowCloseGuard.uninstall() }
        var quitRequests = 0
        OPNMainWindowCloseGuard.terminateApplication = { quitRequests += 1 }
        defer { OPNMainWindowCloseGuard.terminateApplication = { NSApp.terminate(nil) } }
        let proxy = window.delegate as? OPNMainWindowCloseDelegateProxy
        #expect(proxy != nil)

        // The quit choice closes the window and asks the app to go with it; each keep-running choice
        // closes the window and leaves the app running (the application delegate refuses the quit).
        OPNWindowClosePreferences.behavior = .quitApplication
        #expect(proxy?.windowShouldClose(window) == true)
        #expect(quitRequests == 1)

        OPNWindowClosePreferences.behavior = .keepRunningInDock
        #expect(proxy?.windowShouldClose(window) == true)
        #expect(quitRequests == 1)

        OPNWindowClosePreferences.behavior = .menuBarOnly
        #expect(proxy?.windowShouldClose(window) == true)
        #expect(quitRequests == 1)
    }

    @Test func guardLeavesEveryOtherWindowAlone() {
        let guestWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        guestWindow.identifier = NSUserInterfaceItemIdentifier("remote-coop-guest")
        let original = RecordingWindowDelegate()
        guestWindow.delegate = original

        OPNMainWindowCloseGuard.install(on: guestWindow)

        #expect(guestWindow.delegate === original)
    }

    @Test func guardForwardsTheDelegateItDisplaced() {
        let window = makeMainWindow()
        let displaced = RecordingWindowDelegate()
        window.delegate = displaced
        OPNMainWindowCloseGuard.install(on: window)
        defer { OPNMainWindowCloseGuard.uninstall() }

        // A delegate message the guard does not answer is forwarded, so the window keeps behaving
        // the way SwiftUI set it up to.
        window.delegate?.windowWillClose?(Notification(name: NSWindow.willCloseNotification, object: window))
        #expect(displaced.closedCount == 1)
    }

    @Test func aDelegateVetoOutranksTheClosePreference() {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        let window = makeMainWindow()
        let owner = VetoingWindowDelegate()
        window.delegate = owner
        defer { withExtendedLifetime(owner) {} }
        OPNMainWindowCloseGuard.install(on: window)
        defer { OPNMainWindowCloseGuard.uninstall() }
        OPNWindowClosePreferences.behavior = .quitApplication

        let proxy = window.delegate as? OPNMainWindowCloseDelegateProxy
        #expect(proxy?.windowShouldClose(window) == false)
    }

    @Test func observedLaunchStateMovesThePhase() async throws {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        storeCloseBehavior(.quitApplication)
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        model.attach(source: source)
        defer { model.detachSource(source) }

        source.snapshot = OPNMenuBarSessionSnapshot(phase: .connecting, title: "Cyberpunk 2077")
        try await waitForQueuedDelivery()
        #expect(model.phase == .connecting)
        #expect(model.gameTitle == "Cyberpunk 2077")
        #expect(model.isStatusItemInserted)

        source.snapshot = OPNMenuBarSessionSnapshot(phase: .queued(position: 2), title: "Cyberpunk 2077")
        try await waitForQueuedDelivery()
        #expect(model.phase == .queued(position: 2))
        #expect(model.estimatedRemainingSeconds == 90)
        #expect(model.panelStatusText() == "Queue #2 · ~2 min")

        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "")
        try await waitForQueuedDelivery()
        #expect(model.phase == .idle)
        #expect(model.estimatedRemainingSeconds == nil)
        #expect(!model.isStatusItemInserted)
    }

    @Test func lifecycleNotificationOwnsTheStreamingPhase() async throws {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        storeCloseBehavior(.quitApplication)
        let model = OPNMenuBarSessionModel()
        let id = UUID()
        StreamSessionLifecycle.activate(id, quitRequestHandler: { _ in true })
        defer { StreamSessionLifecycle.deactivate(id) }

        try await waitForQueuedDelivery()
        #expect(model.phase == .streaming)
        #expect(model.streamStartedAt != nil)
        #expect(model.streamElapsedText == "0:00")
        #expect(model.isStatusItemInserted)

        StreamSessionLifecycle.deactivate(id)
        try await waitForQueuedDelivery()
        #expect(model.phase == .idle)
        #expect(model.streamStartedAt == nil)
        #expect(model.streamElapsedText == nil)
        #expect(!model.isStatusItemInserted)
    }

    @Test func controlsRouteThroughTheStreamLifecycle() {
        let model = OPNMenuBarSessionModel()
        let recorder = StreamCommandRecorder()
        let id = UUID()

        // With no session there is nothing behind the command; the lifecycle reports that rather
        // than the surface keeping a second copy of the state.
        model.pauseSession()
        model.endSession()
        #expect(recorder.commands.isEmpty)
        #expect(!model.hasActiveStream)

        StreamSessionLifecycle.activate(
            id,
            quitRequestHandler: { _ in true },
            commandHandler: { recorder.record($0) }
        )
        defer { StreamSessionLifecycle.deactivate(id) }

        model.pauseSession()
        model.endSession()
        #expect(recorder.commands == [.pauseSession, .endSession])
        #expect(model.hasActiveStream)
    }

    @Test func primeRecentGamesSeedsOnlyWithoutASource() {
        let model = OPNMenuBarSessionModel()
        let seeded = OPNMenuBarRecentGame(title: "Manor Lords", appId: "app-1")
        model.primeRecentGames([seeded])
        #expect(model.recentGames == [seeded])

        // A source owns the list once attached, and its rows carry artwork the seeder cannot resolve,
        // so a later seed must not overwrite them.
        let source = StubMenuBarSource()
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", recentGames: [])
        model.attach(source: source)
        model.primeRecentGames([OPNMenuBarRecentGame(title: "Hades", appId: "app-2")])
        #expect(model.recentGames.isEmpty)
    }

    @Test func detachKeepsThePlayHistoryForTheWindowlessSurface() async throws {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        storeCloseBehavior(.keepRunningInDock)
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        let game = OPNMenuBarRecentGame(title: "Manor Lords", appId: "app-1")
        source.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", recentGames: [game])

        model.attach(source: source)
        try await waitForQueuedDelivery()
        #expect(model.recentGames == [game])

        // Closing the window to the tray detaches the source; the play history must survive so the
        // windowless menu still offers the games.
        model.detachSource(source)
        #expect(model.recentGames == [game])
        #expect(model.phase == .idle)
        #expect(model.canLaunchRecentGames)
    }

    @Test func quickLaunchWaitsForAWindowAndThenRuns() async throws {
        let existing = preserveCloseBehavior()
        defer { restoreCloseBehavior(existing) }

        storeCloseBehavior(.quitApplication)
        let model = OPNMenuBarSessionModel()
        let online = StubMenuBarSource()
        let offline = StubMenuBarSource()
        let game = OPNMenuBarRecentGame(title: "Manor Lords", appId: "app-1")

        online.snapshot = OPNMenuBarSessionSnapshot(phase: .idle, title: "", recentGames: [game])
        model.attach(source: online)
        try await waitForQueuedDelivery()
        defer { model.detachSource(online) }
        #expect(model.canLaunchRecentGames)

        // With a window to perform it, a launch arrives immediately.
        model.requestLaunch(game)
        #expect(online.launchedGames.map(\.title) == ["Manor Lords"])

        // A window that is not the attached one cannot take the surface away from the one that is.
        model.detachSource(offline)
        #expect(model.canLaunchRecentGames)

        // A window that goes away first parks the launch instead of dropping it, and the play history
        // it had already handed over stays on the menu for the windowless surface…
        model.detachSource(online)
        model.requestLaunch(OPNMenuBarRecentGame(title: "Cyberpunk 2077", appId: "app-2"))
        #expect(online.launchedGames.count == 1)
        #expect(model.canLaunchRecentGames)

        // …and the next window to attach acts on it, exactly once.
        model.attach(source: offline)
        #expect(offline.launchedGames.map(\.title) == ["Cyberpunk 2077"])
        model.attach(source: offline)
        #expect(offline.launchedGames.count == 1)

        offline.snapshot = OPNMenuBarSessionSnapshot(phase: .connecting, title: "Manor Lords", recentGames: [game])
        try await waitForQueuedDelivery()
        #expect(!model.canLaunchRecentGames)
    }
}

/// What the catalog hands the surface: the launch flow's phase, and the games the menu can relaunch.
@MainActor @Suite(.serialized) struct MenuBarCatalogSnapshotTests {
    @Test func snapshotDescribesTheLaunchFlow() {
        let model = makeCatalogViewModelForTesting()
        #expect(model.menuBarSnapshot.phase == .idle)
        #expect(model.menuBarSnapshot.title.isEmpty)

        model.launchFlowTitle = "Cyberpunk 2077"
        model.launchFlowState = .checkingSession
        #expect(model.menuBarSnapshot.phase == .connecting)
        #expect(model.menuBarSnapshot.title == "Cyberpunk 2077")

        model.launchFlowState = .idle
        model.activeStreamConfiguration = StreamLaunchConfiguration(
            title: "Cyberpunk 2077",
            applicationID: "1093630001",
            accessToken: "t",
            accountLinked: true,
            selectedStore: "steam"
        )
        model.isActiveStreamLaunchOverlayVisible = true
        // Allocated but no frame yet: the launch is starting, not queued and not streaming.
        #expect(model.menuBarSnapshot.phase == .starting)

        model.activeStreamProgress = StreamProgress(
            title: "Cyberpunk 2077",
            message: "Queue position: 4",
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: StreamLaunchStep.allocateCloudSession.rawValue,
            isReady: false,
            queuePosition: 4
        )
        #expect(model.menuBarSnapshot.phase == .queued(position: 4))

        // The overlay lingers for a beat after the stream reports ready; from there the surface
        // yields to the lifecycle rather than holding `starting` past the first frame.
        model.activeStreamProgress = StreamProgress(
            title: "Cyberpunk 2077",
            message: "",
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: StreamLaunchStep.connected.rawValue,
            isReady: true
        )
        #expect(model.menuBarSnapshot.phase == .idle)

        // A running stream belongs to the lifecycle, not to this snapshot: claiming a phase here
        // would let a teardown that has not reached the view model keep a dead session on screen.
        model.isActiveStreamLaunchOverlayVisible = false
        #expect(model.menuBarSnapshot.phase == .idle)
        #expect(model.menuBarSnapshot.title == "Cyberpunk 2077")
    }

    @Test func snapshotCollapsesTheVendorAndLocalIdentitiesToOneRowPerGame() {
        let model = makeCatalogViewModelForTesting()
        let game = OPNCatalogGameObject()
        game.id = "53a6c9f5-524c-4309-9d54-dda5a6cb10b9"
        game.title = "Aniimo"
        game.launchAppId = "108118999"
        model.catalogGames = [game]

        var recent = CatalogRecentlyPlayed.empty
        // A locally-finished session recorded the numeric launch app id…
        recent.record(title: "Aniimo", appId: "108118999", store: "STEAM", playedAt: Date(timeIntervalSince1970: 200))
        // …and the vendor history reported the same game under its catalog identity.
        recent.record(title: "Aniimo", appId: "53a6c9f5-524c-4309-9d54-dda5a6cb10b9", store: "", playedAt: Date(timeIntervalSince1970: 100))
        model.recentlyPlayed = recent

        let rows = model.menuBarSnapshot.recentGames
        #expect(rows.map(\.title) == ["Aniimo"])
        #expect(rows.first?.appId == "53a6c9f5-524c-4309-9d54-dda5a6cb10b9")
        // The row keeps the newer of the two timestamps, so the subtitle says when it was last played.
        #expect(rows.first?.lastPlayedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func persistedRowsCollapseTheTwoNamespacesByTitle() {
        let identifier = "menu-bar-persisted-test"
        let key = "OpenNOW.Catalog.RecentlyPlayed.\(identifier)"
        let existing = UserDefaults.standard.object(forKey: key)
        defer {
            if let existing {
                UserDefaults.standard.set(existing, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        var recent = CatalogRecentlyPlayed.empty
        recent.record(title: "Aniimo", appId: "108118999", store: "STEAM", playedAt: Date(timeIntervalSince1970: 200), artworkURL: "https://cdn.example/aniimo.png")
        recent.record(title: "Aniimo", appId: "53a6c9f5-524c-4309-9d54-dda5a6cb10b9", store: "", playedAt: Date(timeIntervalSince1970: 100))
        recent.record(title: "Warcraft® III: Reforged", appId: "100508511", store: "BATTLENET", playedAt: Date(timeIntervalSince1970: 150))
        recent.save(accountIdentifier: identifier)

        let rows = CatalogViewModel.persistedMenuBarRecentGames(accountIdentifier: identifier)
        #expect(rows.map(\.title) == ["Aniimo", "Warcraft® III: Reforged"])
        #expect(rows.first?.artworkURL == "https://cdn.example/aniimo.png")
        // The windowless path carries the timestamp too, so its rows get the same subtitle.
        #expect(rows.first?.lastPlayedAt == Date(timeIntervalSince1970: 200))
    }

    @Test func snapshotOffersTheThreeMostRecentGames() {
        let model = makeCatalogViewModelForTesting()
        var recent = CatalogRecentlyPlayed.empty
        for (index, title) in ["Manor Lords", "Cyberpunk 2077", "Hades", "Elden Ring"].enumerated() {
            recent.record(title: title, appId: "app-\(index)", store: "steam", playedAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        model.recentlyPlayed = recent

        #expect(model.menuBarSnapshot.recentGames.map(\.title) == ["Elden Ring", "Hades", "Cyberpunk 2077"])
        #expect(model.menuBarSnapshot.recentGames.first?.appId == "app-3")
    }
}

extension MenuBarSessionTests {
    @Test func resolvedBehaviorShowsTheFallbackForAWithheldChoice() {
        let menuBarExisting = preserveMenuBarItem()
        defer { restoreMenuBarItem(menuBarExisting) }

        // The settings row resolves the stored raw value rather than reading it directly, so a
        // menu-bar-only choice the item switch has withheld shows as the Dock fallback.
        OPNMenuBarPreferences.showsStatusItem = false
        #expect(OPNWindowClosePreferences.resolvedBehavior(storedRawValue: OPNWindowCloseBehavior.menuBarOnly.rawValue) == .keepRunningInDock)
        OPNMenuBarPreferences.showsStatusItem = true
        #expect(OPNWindowClosePreferences.resolvedBehavior(storedRawValue: OPNWindowCloseBehavior.menuBarOnly.rawValue) == .menuBarOnly)
        #expect(OPNWindowClosePreferences.resolvedBehavior(storedRawValue: nil) == .keepRunningInDock)
        #expect(OPNWindowClosePreferences.resolvedBehavior(storedRawValue: "minimize-to-dock") == .keepRunningInDock)
    }

    @Test func dockIconHidesOnlyForTheMenuBarOnlyChoiceWithNoWindowOnScreen() {
        // Only menu-bar-only, only with the item that replaces the Dock icon, and only while nothing
        // is on screen to keep a Dock presence for.
        #expect(OPNDockIconController.shouldHideDockIcon(behavior: .menuBarOnly, showsStatusItem: true, hasVisibleAppWindow: false))
        #expect(!OPNDockIconController.shouldHideDockIcon(behavior: .menuBarOnly, showsStatusItem: true, hasVisibleAppWindow: true))
        #expect(!OPNDockIconController.shouldHideDockIcon(behavior: .menuBarOnly, showsStatusItem: false, hasVisibleAppWindow: false))
        #expect(!OPNDockIconController.shouldHideDockIcon(behavior: .keepRunningInDock, showsStatusItem: true, hasVisibleAppWindow: false))
        #expect(!OPNDockIconController.shouldHideDockIcon(behavior: .quitApplication, showsStatusItem: true, hasVisibleAppWindow: false))
    }

    private func makeMainWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.identifier = NSUserInterfaceItemIdentifier(OPNMainWindow.identifier)
        window.isReleasedWhenClosed = false
        return window
    }
}

/// A delegate that records a message it is not required to answer, standing in for SwiftUI's own.
@MainActor private final class RecordingWindowDelegate: NSObject, NSWindowDelegate {
    private(set) var closedCount = 0

    func windowWillClose(_ notification: Notification) {
        closedCount += 1
    }
}

@MainActor private final class VetoingWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }
}

/// A stand-in launch flow: the surface follows whatever it publishes, and hands launches back to it.
@MainActor @Observable final class StubMenuBarSource: OPNMenuBarSessionSource {
    var snapshot = OPNMenuBarSessionSnapshot()
    private(set) var launchedGames: [OPNMenuBarRecentGame] = []
    private(set) var shownPages: [OPNMainWindowPage] = []
    /// Every request in the order it arrived, for the one thing the separate lists cannot show: which
    /// of two parked requests a window acts on first.
    private(set) var calls: [String] = []
    private(set) var resumeRequests = 0
    private(set) var refreshRequests = 0

    var menuBarSnapshot: OPNMenuBarSessionSnapshot { snapshot }

    func launchRecentGame(_ game: OPNMenuBarRecentGame) {
        launchedGames.append(game)
        calls.append("launch:\(game.title)")
    }

    func resumeSession() {
        resumeRequests += 1
    }

    func refreshActiveSession() {
        refreshRequests += 1
    }

    func showMainPage(_ page: OPNMainWindowPage) {
        shownPages.append(page)
        calls.append("page:\(page)")
    }
}

private final class AnnouncementCounter: @unchecked Sendable {
    var count = 0
}

@MainActor private final class StreamCommandRecorder {
    private(set) var commands: [StreamCommand] = []

    func record(_ command: StreamCommand) {
        commands.append(command)
    }
}
