import AppKit
import Foundation
import Testing
@testable import OpenNOW

/// The Dock surface: the badge count, the progress fraction, how a queue wait turns into that
/// fraction, and the menu's rows.
///
/// The decisions are tested rather than the `NSDockTile` calls around them: a Dock tile exists only
/// in a running app, so `OPNDockIconController` keeps every decision pure and every AppKit call in
/// one place. One serialized suite, because the menu's actions keep the list their items index into.
@MainActor @Suite(.serialized) struct DockTileTests {
    // MARK: - Badge

    @Test func nothingPendingDrawsNoBadge() {
        #expect(OPNDockTileContent.pendingSessionCount(isQueued: false, hasResumableSession: false) == nil)
        #expect(OPNDockTileContent(pendingSessions: nil, progress: nil, isStreaming: false).badgeLabel == nil)
        #expect(OPNDockTileContent(pendingSessions: 0, progress: nil, isStreaming: false).badgeLabel == nil)
    }

    @Test func aQueuedOrResumableSessionIsCounted() {
        #expect(OPNDockTileContent.pendingSessionCount(isQueued: true, hasResumableSession: false) == 1)
        #expect(OPNDockTileContent.pendingSessionCount(isQueued: false, hasResumableSession: true) == 1)
        // A seat being acquired and a seat waiting to be rejoined are two separate things the user
        // has to act on, so they are counted rather than merged away.
        #expect(OPNDockTileContent.pendingSessionCount(isQueued: true, hasResumableSession: true) == 2)
        #expect(OPNDockTileContent(pendingSessions: 1, progress: nil, isStreaming: false).badgeLabel == "1")
    }

    @Test func aBadgeTooWideForTheTileIsCapped() {
        #expect(OPNDockTileContent(pendingSessions: 99, progress: nil, isStreaming: false).badgeLabel == "99")
        #expect(OPNDockTileContent(pendingSessions: 100, progress: nil, isStreaming: false).badgeLabel == "99+")
    }

    // MARK: - Progress

    @Test func noWaitDrawsNoProgress() {
        #expect(OPNDockTileContent.progress(queue: nil, isStarting: false, export: nil) == nil)
    }

    @Test func theQueueWinsTheTileWhenBothWaitsAreRunning() {
        #expect(OPNDockTileContent.progress(queue: 0.4, isStarting: false, export: 0.9) == .determinate(0.4))
        #expect(OPNDockTileContent.progress(queue: nil, isStarting: false, export: 0.9) == .determinate(0.9))
    }

    @Test func progressIsClampedAndQuantizedToTheDisplayedPercent() {
        #expect(OPNDockTileContent.progress(queue: 1.4, isStarting: false, export: nil) == .determinate(1))
        #expect(OPNDockTileContent.progress(queue: -0.3, isStarting: false, export: nil) == .determinate(0))
        // 0.4321 is a new value every encoder callback; the tile shows one percent at a time.
        #expect(OPNDockTileContent.progress(queue: nil, isStarting: false, export: 0.4321) == .determinate(0.43))
        #expect(OPNDockTileContent.progress(queue: nil, isStarting: false, export: 0.4349) == .determinate(0.43))
    }

    @Test func aStreamBeingStartedSweepsTheBar() {
        // No fraction to report — the session is allocated but no frame has arrived — so the bar is
        // indeterminate rather than an empty one.
        #expect(OPNDockTileContent.progress(queue: nil, isStarting: true, export: nil) == .indeterminate)
        // The queue still outranks it: the queue is the wait the user is blocked behind.
        #expect(OPNDockTileContent.progress(queue: 0.4, isStarting: true, export: nil) == .determinate(0.4))
        // Starting outranks an export: it ends in a game with nothing else to watch, and the export
        // gets its determinate bar back once the stream is ready.
        #expect(OPNDockTileContent.progress(queue: nil, isStarting: true, export: 0.9) == .indeterminate)
    }

    @Test func theStartingBadgeStaysOffTheTile() {
        // Starting is passive — nothing for the user to act on — so it draws no badge even though it
        // owns the progress bar.
        #expect(OPNDockTileContent.pendingSessionCount(isQueued: false, hasResumableSession: false) == nil)
    }

    @Test func theIndeterminateSweepTurnsAroundAtTheEnds() {
        // Leading edge only: the segment never leaves the well.
        #expect(OPNDockTileProgressView.indeterminatePosition(phase: 0, isReduceMotionEnabled: false) == 0)
        #expect(OPNDockTileProgressView.indeterminatePosition(phase: 1, isReduceMotionEnabled: false) == 1)
        // Past the end it comes back rather than wrapping to the start.
        #expect(OPNDockTileProgressView.indeterminatePosition(phase: 1.5, isReduceMotionEnabled: false) == 0.5)
        #expect(OPNDockTileProgressView.indeterminatePosition(phase: 2, isReduceMotionEnabled: false) == 0)
    }

    @Test func reduceMotionParksTheSweep() {
        #expect(OPNDockTileProgressView.indeterminatePosition(phase: 0.4, isReduceMotionEnabled: true) == 0.5)
        #expect(OPNDockTileProgressView.indeterminatePosition(phase: 1.9, isReduceMotionEnabled: true) == 0.5)
    }

    // MARK: - Queue wait

    @Test func aWaitStartsEmptyAndEndsWithTheSeat() {
        var progress = OPNDockQueueProgress()
        #expect(progress.observe(position: 5) == 0)
        // Nothing is queued any more, so the wait is over and the tile has nothing to draw.
        #expect(progress.observe(position: 0) == nil)
        #expect(progress.entryPosition == nil)
    }

    @Test func theFractionTracksClearedPositions() {
        var progress = OPNDockQueueProgress()
        #expect(progress.observe(position: 5) == 0)
        #expect(progress.observe(position: 3) == 0.5)
        #expect(progress.observe(position: 1) == 1)
    }

    @Test func aQueueThatGrowsHoldsTheBar() {
        var progress = OPNDockQueueProgress()
        #expect(progress.observe(position: 4) == 0)
        // Re-queued behind more waiting players: that is not progress, and a bar that ran backwards
        // would read as the wait being cancelled.
        #expect(progress.observe(position: 7) == 0)
        // Two of the three positions are still ahead of this wait.
        #expect(progress.observe(position: 2) == 2.0 / 3.0)
    }

    @Test func aWaitThatStartsAtTheFrontHasNothingToMeasure() {
        var progress = OPNDockQueueProgress()
        // Position 1 is the last step: there is no earlier position for the wait to have started from,
        // so it stays empty rather than inventing movement.
        #expect(progress.observe(position: 1) == 0)
        #expect(progress.observe(position: 0) == nil)
    }

    @Test func aNewWaitStartsFromItsOwnEntryPosition() {
        var progress = OPNDockQueueProgress()
        #expect(progress.observe(position: 8) == 0)
        #expect(progress.observe(position: 1) == 1)
        progress.reset()
        // The next wait is measured from where it starts, not from the wait before it.
        #expect(progress.observe(position: 3) == 0)
        #expect(progress.observe(position: 2) == 0.5)
    }

    // MARK: - The window requests the menu makes

    @Test func aPageAskedForWithoutAWindowWaitsForOne() {
        let model = OPNMenuBarSessionModel()
        model.requestMainPage(.recordings)

        // Nothing to show it: the request has to survive until a window can act on it, the way a
        // launch asked for from outside the window does.
        let source = StubMenuBarSource()
        model.attach(source: source)
        defer { model.detachSource(source) }

        #expect(source.shownPages == [.recordings])
    }

    @Test func aPageAskedForWithAWindowIsShownAtOnce() {
        let model = OPNMenuBarSessionModel()
        let source = StubMenuBarSource()
        model.attach(source: source)
        defer { model.detachSource(source) }

        model.requestMainPage(.home)

        #expect(source.shownPages == [.home])
    }

    @Test func aWindowOpeningForAParkedRequestLandsOnThePageBeforeItLaunches() {
        let model = OPNMenuBarSessionModel()
        model.requestLaunch(OPNMenuBarGame(title: "Parked", appId: "parked"))
        model.requestMainPage(.home)

        let source = StubMenuBarSource()
        model.attach(source: source)
        defer { model.detachSource(source) }

        #expect(source.shownPages == [.home])
        #expect(source.launchedGames.map(\.title) == ["Parked"])
        // The page first: a window opened to answer a request arrives where the request asked, and a
        // launch handed over beside it switches pages anyway.
        #expect(source.calls == ["page:home", "launch:Parked"])
    }

    @Test func onlyAWindowTheSceneNeverBuiltHasToBeBroughtUp() {
        // The close button hides the window rather than tearing the scene down, so a hidden or
        // minimized window still has its surface mounted and a menu bar source attached — a launch
        // handed to it lands. Only a window that has never been built leaves a surface nothing to act
        // on it.
        let hidden = mainWindow()
        hidden.setIsVisible(false)
        #expect(!OPNMainWindow.needsPresentation(for: hidden))
        let showing = mainWindow()
        showing.setIsVisible(true)
        #expect(!OPNMainWindow.needsPresentation(for: showing))
        #expect(OPNMainWindow.needsPresentation(for: nil))
    }

    private func mainWindow() -> NSWindow {
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

    // MARK: - Menu

    private func game(_ title: String, appId: String = "") -> OPNMenuBarGame {
        OPNMenuBarGame(title: title, appId: appId)
    }

    /// The menu's rows without its rules, so where a row sits does not depend on where the separators
    /// happen to be drawn.
    private func rows(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.filter { !$0.isSeparatorItem }
    }

    @Test func theMenuListsTheThreeMostRecentGamesThenTheTwoWindowActions() {
        let menu = OPNDockMenu.make(
            recentGames: [game("A", appId: "1"), game("B", appId: "2"), game("C", appId: "3")],
            phase: .idle,
            gameTitle: ""
        )

        #expect(rows(menu).map(\.title) == [
            OPNDockMenu.continuePlayingHeader,
            "A", "B", "C",
            OPNDockMenu.newSessionTitle,
            OPNDockMenu.openRecordingsTitle,
        ])
        // The games and the two window actions are a group, not one list.
        #expect(menu.items.firstIndex(where: \.isSeparatorItem) == 4)
        #expect(rows(menu)[0].isEnabled == false)
        // The header is a label, not an action: only the games and the two window items do anything.
        #expect(rows(menu)[0].action == nil)
        #expect(rows(menu)[1].action == #selector(OPNDockMenuActions.launchRecentGame(_:)))
        #expect(rows(menu)[4].action == #selector(OPNDockMenuActions.startNewSession(_:)))
        #expect(rows(menu)[5].action == #selector(OPNDockMenuActions.openRecordings(_:)))
        // The games all point at the one target that outlives the menu.
        #expect(rows(menu)[1].target === OPNDockMenuActions.shared)
    }

    @Test func theMenuNeverListsMoreThanThreeGames() {
        let games = (1...5).map { game("Game \($0)", appId: "\($0)") }
        let menu = OPNDockMenu.make(recentGames: games, phase: .idle, gameTitle: "")
        #expect(rows(menu).map(\.title).filter { $0.hasPrefix("Game ") } == ["Game 1", "Game 2", "Game 3"])
    }

    @Test func anEmptyHistorySaysSoInsteadOfShowingNothing() {
        let menu = OPNDockMenu.make(recentGames: [], phase: .idle, gameTitle: "")
        #expect(rows(menu).map(\.title) == [
            OPNDockMenu.continuePlayingHeader,
            OPNDockMenu.emptyListPlaceholder,
            OPNDockMenu.newSessionTitle,
            OPNDockMenu.openRecordingsTitle,
        ])
        #expect(rows(menu)[1].isEnabled == false)
    }

    @Test func anItemNamesTheGameItsMenuListed() {
        let listed = [game("A", appId: "1"), game("B", appId: "2")]
        let menu = OPNDockMenu.make(recentGames: listed, phase: .idle, gameTitle: "")
        let actions = OPNDockMenuActions.shared

        // An item carries its index in the list the menu was built from; that index has to survive
        // the trip back to the action, or a click would start the wrong game.
        #expect(rows(menu)[1].tag == 0)
        #expect(rows(menu)[2].tag == 1)
        #expect(actions.listedGame(at: rows(menu)[1].tag) == listed[0])
        #expect(actions.listedGame(at: rows(menu)[2].tag) == listed[1])
        #expect(actions.listedGame(at: 7) == nil)
    }

    // MARK: - Games hidden while a session runs

    @Test func aGameRowCannotStartASessionOverARunningOne() {
        // The catalog refuses a launch while a session runs and answers with a resume-or-end prompt,
        // which is the last thing a right-click on a running stream should trigger.
        #expect(OPNDockMenu.canLaunchGames(phase: .idle))
        #expect(!OPNDockMenu.canLaunchGames(phase: .streaming))
        // Every non-idle phase, not just `.streaming`: `.connecting` is the launch flow's own
        // pre-overlay state and a launch asked for during it is refused the same way.
        #expect(!OPNDockMenu.canLaunchGames(phase: .connecting))
        #expect(!OPNDockMenu.canLaunchGames(phase: .queued(position: 1)))
        #expect(!OPNDockMenu.canLaunchGames(phase: .starting))
    }

    @Test func theGamesAreGoneWhileAStreamIsRunning() {
        let menu = OPNDockMenu.make(
            recentGames: [game("A", appId: "1"), game("B", appId: "2")],
            phase: .streaming,
            gameTitle: "Portal"
        )

        #expect(rows(menu).map(\.title) == [
            OPNDockMenu.nowStreamingHeader,
            "Portal",
            OPNDockMenu.pauseStreamTitle,
            OPNDockMenu.endStreamTitle,
            OPNDockMenu.newSessionTitle,
            OPNDockMenu.openRecordingsTitle,
        ])
    }

    @Test func aSessionThatIsOnlyStartingHidesTheGamesWithoutClaimingToStream() {
        // Starting is a wait, so the streaming block is absent — but the games are still unlaunchable,
        // which is why they go rather than staying on offer.
        let menu = OPNDockMenu.make(recentGames: [game("A", appId: "1")], phase: .starting, gameTitle: "Portal")
        #expect(rows(menu).map(\.title) == [
            OPNDockMenu.newSessionTitle,
            OPNDockMenu.openRecordingsTitle,
        ])
    }

    @Test func aHiddenGamesBlockLeavesNoSeparatorBehind() {
        // A menu with the games removed is two groups, so exactly one separator: a separator stranded at
        // the top or doubled up between blocks is the kind of thing that reaches review as a broken menu.
        let streaming = OPNDockMenu.make(recentGames: [game("A", appId: "1")], phase: .streaming, gameTitle: "Portal")
        #expect(streaming.items.map(\.isSeparatorItem) == [false, false, false, false, true, false, false])

        let starting = OPNDockMenu.make(recentGames: [game("A", appId: "1")], phase: .starting, gameTitle: "Portal")
        #expect(starting.items.map(\.isSeparatorItem) == [false, false])

        let idle = OPNDockMenu.make(recentGames: [game("A", appId: "1")], phase: .idle, gameTitle: "")
        #expect(idle.items.map(\.isSeparatorItem) == [false, false, true, false, false])
    }

    @Test func aHiddenGamesBlockDoesNotLeaveTheEarlierOneLaunchable() {
        let listed = [game("A", appId: "1"), game("B", appId: "2")]
        let actions = OPNDockMenuActions.shared

        // A menu built while idle keeps its indices…
        let idle = OPNDockMenu.make(recentGames: listed, phase: .idle, gameTitle: "")
        #expect(actions.listedGame(at: rows(idle)[1].tag) == listed[0])

        // …and a later right-click during a stream clears them, so a click handed over by a menu that
        // is already closed cannot start a game the session is no longer offering.
        _ = OPNDockMenu.make(recentGames: listed, phase: .streaming, gameTitle: "Portal")
        #expect(actions.listedGame(at: 0) == nil)
        #expect(actions.listedGame(at: 1) == nil)
    }

    // MARK: - Streaming block

    @Test func onlyARunningStreamOffersTheControlsToStopIt() {
        // Queued and starting are waits, not streams: there is nothing to pause or end yet, and the
        // tile already carries them.
        #expect(OPNDockMenu.Streaming.active(phase: .streaming, gameTitle: "Portal") == OPNDockMenu.Streaming(gameTitle: "Portal"))
        #expect(OPNDockMenu.Streaming.active(phase: .queued(position: 2), gameTitle: "Portal") == nil)
        #expect(OPNDockMenu.Streaming.active(phase: .starting, gameTitle: "Portal") == nil)
        #expect(OPNDockMenu.Streaming.active(phase: .connecting, gameTitle: "Portal") == nil)
        #expect(OPNDockMenu.Streaming.active(phase: .idle, gameTitle: "Portal") == nil)
    }

    @Test func aStreamWithNoGameNamedFallsBackToTheAppName() {
        // The status item cannot render an empty label, so the menu's row cannot either.
        #expect(OPNDockMenu.Streaming(gameTitle: "  ").displayTitle == "OpenNOW")
        #expect(OPNDockMenu.Streaming(gameTitle: "Portal").displayTitle == "Portal")
    }

    @Test func theMenuNamesTheStreamAndOffersToPauseOrEndIt() {
        let menu = OPNDockMenu.make(
            recentGames: [game("A", appId: "1")],
            phase: .streaming,
            gameTitle: "Portal"
        )

        #expect(rows(menu).map(\.title) == [
            OPNDockMenu.nowStreamingHeader,
            "Portal",
            OPNDockMenu.pauseStreamTitle,
            OPNDockMenu.endStreamTitle,
            OPNDockMenu.newSessionTitle,
            OPNDockMenu.openRecordingsTitle,
        ])
        // The header and the game name are labels; the two controls act on the session.
        #expect(rows(menu)[0].isEnabled == false)
        #expect(rows(menu)[1].isEnabled == false)
        #expect(rows(menu)[2].action == #selector(OPNDockMenuActions.pauseStream(_:)))
        #expect(rows(menu)[3].action == #selector(OPNDockMenuActions.endStream(_:)))
        // The controls stop the stream, they do not bring the stream window forward.
        #expect(rows(menu)[2].target === OPNDockMenuActions.shared)
        #expect(rows(menu)[3].target === OPNDockMenuActions.shared)
    }

    @Test func theStreamingBlockSitsAboveWhatIsLeftOfTheMenu() {
        let menu = OPNDockMenu.make(
            recentGames: [game("A", appId: "1")],
            phase: .streaming,
            gameTitle: "Portal"
        )

        // Two groups, because the games are gone while a stream runs: the block first, then the two
        // window actions. The stream block is separated from what follows it, so a user reading the list
        // cannot mistake the items under it for things the menu would stop.
        #expect(menu.items.map(\.isSeparatorItem) == [false, false, false, false, true, false, false])
    }

    // MARK: - Streaming tile

    /// The marker is one flag, so a stream cannot be half-drawn: `OPNDockIconController` writes it or
    /// does not, and the write is skipped only when the content is unchanged.
    @Test func aRunningStreamMarksTheTile() {
        let content = OPNDockTileContent(pendingSessions: nil, progress: nil, isStreaming: true)
        #expect(content.isStreaming)
    }

    @Test func aStreamIsNotDrawnTheSameWayASessionThatIsMerelyWaiting() {
        // The marker is a claim that frames are arriving, so a wait must not borrow it. A queued or
        // starting session owns the bar and the badge instead.
        let waiting = OPNDockTileContent(pendingSessions: 1, progress: .indeterminate, isStreaming: false)
        #expect(!waiting.isStreaming)
        #expect(waiting.progress == .indeterminate)
    }

    @Test func theLiveBadgeSitsInTheTopTrailingCornerAtEveryDockSize() {
        // The badge is an overlay on the icon, so it has to stay inside the tile and clear of the
        // leading edge at whatever size the Dock asks for. A degenerate tile draws nothing.
        for size in [CGFloat(16), 32, 64, 128, 256] {
            let bounds = NSRect(x: 0, y: 0, width: size, height: size)
            let badge = OPNDockTileProgressView.liveBadgeRect(in: bounds)
            #expect(badge.width > 0, "\(size)pt tile has no room for a badge")
            #expect(badge.minX > bounds.minX, "\(size)pt badge reaches the leading edge")
            #expect(badge.maxX < bounds.maxX, "\(size)pt badge touches the trailing edge")
            #expect(badge.maxY < bounds.maxY, "\(size)pt badge touches the top edge")
            // The badge belongs in the trailing half, not floating in the middle of the artwork.
            #expect(badge.midX > bounds.midX, "\(size)pt badge is not in the trailing half")
            #expect(badge.midY > bounds.midY, "\(size)pt badge is not in the upper half")
        }
        #expect(OPNDockTileProgressView.liveBadgeRect(in: .zero).isEmpty)
    }

    @Test func theLiveBadgeClearsTheProgressBar() {
        // A stream that is also exporting shows both, so the two must not overlap: the badge is in the
        // corner, the bar along the bottom.
        let bounds = NSRect(x: 0, y: 0, width: 128, height: 128)
        let badge = OPNDockTileProgressView.liveBadgeRect(in: bounds)
        let track = OPNDockTileProgressView.trackRect(in: bounds)
        #expect(!badge.intersects(track), "the live badge overlaps the progress bar")
    }

    @Test func theLiveBadgeNamesASymbolThatExists() {
        // The badge is drawn from a symbol name, so a typo would silently draw nothing at runtime.
        #expect(NSImage(systemSymbolName: OPNDockTileProgressView.liveBadgeSymbolName, accessibilityDescription: nil) != nil)
    }

}
