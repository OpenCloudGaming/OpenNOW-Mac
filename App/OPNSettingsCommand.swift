import AppKit
import SwiftUI

/// The app menu's Settings item and the standard ⌘, that goes with it.
///
/// Settings is a page of the main window rather than a scene of its own, so this cannot be a
/// `Settings` scene: the item brings the window up — building it when the scene has never made one —
/// and asks the menu bar's session bridge for the page, which parks the request until a window's
/// surface attaches. Asking for the page while it is already open changes nothing on screen, so no
/// second window and no duplicate page is ever created.
struct OPNSettingsCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                openSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func openSettings() {
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
        OPNMenuBarSessionModel.shared.requestMainPage(.settings)
    }
}
