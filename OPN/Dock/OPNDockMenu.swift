import AppKit

/// The Dock icon's menu: the games the user can get straight back into, and the two things only the
/// window can do.
///
/// Built fresh every time the Dock asks for it, which is on each right-click. That is also what keeps
/// it in step with the menu bar: the games come from `OPNMenuBarSessionModel`, the same surface the
/// popover's Continue Playing rows read, so the two lists cannot disagree about which three games
/// are last.
@MainActor
enum OPNDockMenu {
    static let continuePlayingHeader = "Continue Playing"
    static let emptyListPlaceholder = "No recent games yet"
    static let newSessionTitle = "New Session"
    static let openRecordingsTitle = "Open Recordings"

    static func make(recentGames: [OPNMenuBarRecentGame]) -> NSMenu {
        let listed = Array(recentGames.prefix(3))
        OPNDockMenuActions.shared.recordListedGames(listed)

        let menu = NSMenu()
        menu.addItem(disabledItem(continuePlayingHeader))
        if listed.isEmpty {
            menu.addItem(disabledItem(emptyListPlaceholder))
        } else {
            for (index, game) in listed.enumerated() {
                menu.addItem(gameItem(game, at: index))
            }
        }
        menu.addItem(.separator())
        menu.addItem(actionItem(newSessionTitle, action: #selector(OPNDockMenuActions.startNewSession(_:))))
        menu.addItem(actionItem(openRecordingsTitle, action: #selector(OPNDockMenuActions.openRecordings(_:))))
        return menu
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func gameItem(_ game: OPNMenuBarRecentGame, at index: Int) -> NSMenuItem {
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
    private var listedGames: [OPNMenuBarRecentGame] = []

    private override init() {
        super.init()
    }

    func recordListedGames(_ games: [OPNMenuBarRecentGame]) {
        listedGames = games
    }

    /// The game an item names, by the index it carries. Nil for an index this list no longer holds,
    /// which a menu built by an earlier right-click can still hand over.
    func listedGame(at index: Int) -> OPNMenuBarRecentGame? {
        listedGames.indices.contains(index) ? listedGames[index] : nil
    }

    @objc func launchRecentGame(_ sender: NSMenuItem) {
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
