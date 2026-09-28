import AppKit

/// The Dock icon's menu: what is streaming right now, the games the user can get straight back into,
/// and the two things only the window can do.
///
/// Built fresh every time the Dock asks for it, which is on each right-click. That is also what keeps
/// it in step with the menu bar: the games come from `OPNMenuBarSessionModel`, the same surface the
/// popover's Continue Playing rows read, so the two lists cannot disagree about which three games
/// are last.
///
/// The streaming block is the Dock's answer to a question the tile cannot ask: a stream is running,
/// and the user wants to stop it without finding the window. Its controls go through
/// `StreamSessionLifecycle` by way of `OPNMenuBarSessionModel`, exactly as the popover's tiles and the
/// in-app shortcuts do, so the two surfaces cannot send different commands for the same session.
@MainActor
enum OPNDockMenu {
    static let continuePlayingHeader = "Continue Playing"
    static let emptyListPlaceholder = "No recent games yet"
    static let newSessionTitle = "New Session"
    static let openRecordingsTitle = "Open Recordings"
    /// The block's header. Named rather than the phase itself, so a queued or starting session reads
    /// as what it is instead of claiming a stream that is not running.
    static let nowStreamingHeader = "Now Streaming"
    static let pauseStreamTitle = "Pause Stream"
    static let endStreamTitle = "End Stream"
    /// How many games the block lists, which is also the number of recent ones the play history keeps
    /// for a windowless surface.
    static let recentGameLimit = 3

    /// The stream the menu can stop, reduced to what the block draws and re-checked against when an
    /// item is chosen. A value rather than the session model, for the same reason
    /// `OPNDockTileContent` is a value: a Dock menu only exists inside a running app, so the decision
    /// is kept pure and testable here and the command still goes through the model.
    struct Streaming: Equatable, Sendable {
        /// The game to name. Empty falls back to the app's own name rather than a blank row, which is
        /// what `OPNMenuBarReadout.titleText` already does for the status item.
        let gameTitle: String

        var displayTitle: String { OPNMenuBarReadout.titleText(gameTitle) }

        /// The stream a surface can stop, or nil when nothing is streaming. Only `.streaming`
        /// qualifies: a session being queued or started is not a stream to pause or end, and its tile
        /// already carries the wait.
        static func active(phase: OPNMenuBarSessionPhase, gameTitle: String) -> Streaming? {
            guard phase == .streaming else { return nil }
            return Streaming(gameTitle: gameTitle)
        }
    }

    /// Whether a game row can start a session. Idle only, the same gate the popover's rows use:
    /// the catalog refuses a launch while a session is running and answers with a resume-or-end
    /// prompt, which is the last thing a right-click on a running stream should be able to trigger.
    ///
    /// Every non-idle phase is covered, not just `.streaming` — `.connecting` is the launch flow's own
    /// pre-overlay state, and a launch asked for during it is refused the same way.
    static func canLaunchGames(phase: OPNMenuBarSessionPhase) -> Bool {
        phase == .idle
    }

    /// The whole menu, from the session's own state. `phase` and `gameTitle` are passed in rather than
    /// read from the shared model, so every decision below stays a pure function of its arguments and
    /// the menu a test builds needs no running session behind it.
    static func make(recentGames: [OPNMenuBarGame], phase: OPNMenuBarSessionPhase, gameTitle: String) -> NSMenu {
        let menu = NSMenu()
        for group in groups(recentGames: recentGames, phase: phase, gameTitle: gameTitle) {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            for item in group { menu.addItem(item) }
        }
        return menu
    }

    /// The menu's rows grouped by separator, so the separators cannot drift out of step with the
    /// blocks as they come and go. A group that is not shown is not merely emptied — it is absent, and
    /// its separator with it.
    private static func groups(recentGames: [OPNMenuBarGame], phase: OPNMenuBarSessionPhase, gameTitle: String) -> [[NSMenuItem]] {
        let showsGames = canLaunchGames(phase: phase)
        // Recorded on every build, not only when the block is drawn, so the list the actions resolve
        // against always matches what the current menu shows: nothing, when the games are hidden.
        OPNDockMenuActions.shared.recordListedGames(showsGames ? Array(recentGames.prefix(recentGameLimit)) : [])

        var groups: [[NSMenuItem]] = []
        if let streaming = Streaming.active(phase: phase, gameTitle: gameTitle) {
            groups.append(streamingGroup(streaming))
        }
        if showsGames {
            groups.append(recentGamesGroup(recentGames))
        }
        groups.append([
            actionItem(newSessionTitle, action: #selector(OPNDockMenuActions.startNewSession(_:))),
            actionItem(openRecordingsTitle, action: #selector(OPNDockMenuActions.openRecordings(_:))),
        ])
        return groups
    }

    private static func streamingGroup(_ streaming: Streaming) -> [NSMenuItem] {
        [
            disabledItem(nowStreamingHeader),
            disabledItem(streaming.displayTitle),
            actionItem(pauseStreamTitle, action: #selector(OPNDockMenuActions.pauseStream(_:))),
            actionItem(endStreamTitle, action: #selector(OPNDockMenuActions.endStream(_:))),
        ]
    }

    private static func recentGamesGroup(_ recentGames: [OPNMenuBarGame]) -> [NSMenuItem] {
        let listed = Array(recentGames.prefix(recentGameLimit))
        var items = [disabledItem(continuePlayingHeader)]
        if listed.isEmpty {
            items.append(disabledItem(emptyListPlaceholder))
            return items
        }
        for (index, game) in listed.enumerated() {
            items.append(gameItem(game, at: index))
        }
        return items
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func gameItem(_ game: OPNMenuBarGame, at index: Int) -> NSMenuItem {
        let item = NSMenuItem(title: game.title, action: #selector(OPNDockMenuActions.launchRecentGame(_:)), keyEquivalent: "")
        item.target = OPNDockMenuActions.shared
        item.tag = index
        return item
    }

    private static func actionItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = OPNDockMenuActions.shared
        return item
    }
}

/// What the Dock menu's items do.
///
/// One instance for the life of the app, because the Dock hands a selection back to the item's
/// target: a target that had gone away, or one built per menu, would silently do nothing.
@MainActor
final class OPNDockMenuActions: NSObject {
    static let shared = OPNDockMenuActions()

    /// The games the menu currently lists, in the order it lists them. An item carries its index in
    /// that list, so this is what turns a selection back into a game.
    private var listedGames: [OPNMenuBarGame] = []

    private override init() {
        super.init()
    }

    func recordListedGames(_ games: [OPNMenuBarGame]) {
        listedGames = games
    }

    /// The game an item names, by the index it carries. Nil for an index this list no longer holds,
    /// which a menu built by an earlier right-click can still hand over.
    func listedGame(at index: Int) -> OPNMenuBarGame? {
        listedGames.indices.contains(index) ? listedGames[index] : nil
    }

    @objc func launchRecentGame(_ sender: NSMenuItem) {
        // Re-checked rather than trusted from the menu: a session can start between the menu being
        // built and the item being chosen, and the catalog would answer a launch over a running
        // session with a resume-or-end prompt.
        guard OPNDockMenu.canLaunchGames(phase: OPNMenuBarSessionModel.shared.phase) else {
            OPNLog.info(.app, "Dock menu declined a launch: a session is already running")
            return
        }
        guard let game = listedGame(at: sender.tag) else {
            OPNLog.warning(.app, "Dock menu launched a game its menu no longer lists")
            return
        }
        OPNLog.info(.launch, "Dock menu launching recent game \(game.title)")
        // A launch, not a request to see the window: it comes up behind whatever the user is doing,
        // exactly as it does when the menu bar offers the same game.
        OPNDockIconController.showDockIcon()
        OPNMainWindow.present(activating: false)
        OPNMenuBarSessionModel.shared.requestLaunch(game)
    }

    /// Starting a session needs a game to start it with, and only the window can ask which one, so
    /// this brings the window up where that choice is made rather than guessing a game here.
    @objc func startNewSession(_ sender: NSMenuItem) {
        OPNLog.info(.app, "Dock menu opening the window to start a session")
        presentMainWindow()
        OPNMenuBarSessionModel.shared.requestMainPage(.home)
    }

    @objc func openRecordings(_ sender: NSMenuItem) {
        OPNLog.info(.app, "Dock menu opening recordings")
        presentMainWindow()
        OPNMenuBarSessionModel.shared.requestMainPage(.recordings)
    }

    /// The session is already running and the stream window is the only thing showing it, so neither
    /// command brings the window forward: the user asked to stop the stream, not to go to it. The
    /// phase is re-read rather than assumed, because the stream can end between the menu being built
    /// and the item being chosen.
    @objc func pauseStream(_ sender: NSMenuItem) {
        let session = OPNMenuBarSessionModel.shared
        guard session.phase == .streaming else {
            OPNLog.info(.app, "Dock menu declined a pause: phase is \(session.phase)")
            return
        }
        OPNLog.info(.app, "Dock menu requested a pause of the active session")
        session.pauseSession()
    }

    @objc func endStream(_ sender: NSMenuItem) {
        let session = OPNMenuBarSessionModel.shared
        guard session.phase == .streaming else {
            OPNLog.info(.app, "Dock menu declined an end: phase is \(session.phase)")
            return
        }
        OPNLog.info(.app, "Dock menu requested the end of the active session")
        session.endSession()
    }

    /// AppKit is asking, so there is no `openWindow` action at hand: the window is brought up
    /// directly, and the request is handed to the surface bridge, which parks it until the window can
    /// act on it — the same route a request from the menu bar takes.
    ///
    /// These two are requests to *see* the window, so the app comes forward with it.
    private func presentMainWindow() {
        OPNDockIconController.showDockIcon()
        OPNMainWindow.present()
    }
}
