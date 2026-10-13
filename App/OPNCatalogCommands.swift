import AppKit
import SwiftUI

/// The app menu's Settings item and the Catalog menu: the two commands that drive the main window's
/// own pages from outside it.
///
/// Settings is a page of the main window rather than a scene of its own, so this cannot be a
/// `Settings` scene. Each command brings the window up — building it when the scene has never made
/// one — and asks the menu bar's session bridge for the page, which parks the request until a
/// window's surface attaches. Asking for a page while it is already open changes nothing on screen,
/// so no second window and no duplicate page is ever created.
///
/// Both chords come from `KeybindingAction`, so rebinding either one in Settings moves it here too.
struct OPNCatalogCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var keybindings = OPNKeybindingsObserver.shared

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                present(.settings)
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .opnKeyboardShortcut(keybindings.activeCombo(for: .openSettings))
        }
        CommandMenu("Catalog") {
            Button {
                present(.home)
            } label: {
                Label(KeybindingAction.openCatalog.title, systemImage: "square.grid.2x2")
            }
            .opnKeyboardShortcut(keybindings.activeCombo(for: .openCatalog))
        }
    }

    /// The window first, then the page: a page belongs to the window, and nothing outside the window
    /// can put one on screen.
    private func present(_ page: OPNMainWindowPage) {
        if OPNMainWindow.needsPresentation {
            // A window coming back from a menu-bar-only launch returns with its Dock icon, the same
            // trade the menu bar's own OpenNOW button makes.
            OPNDockIconController.showDockIcon()
            openWindow(id: "main")
        } else {
            // A window on screen, in the Dock, or hidden by the close button still has its surface
            // mounted, so it only has to be brought forward and made key.
            OPNMainWindow.present()
        }
        OPNMenuBarSessionModel.shared.requestMainPage(page)
    }
}
