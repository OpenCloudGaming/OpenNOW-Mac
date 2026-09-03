//  Desktop integration the catalog needs: opening a URL in the user's browser, putting text on the
//  pasteboard, and stamping the app icon onto a generated shortcut file.
//
//  This exists so `ViewModel/` does not have to import AppKit. Those three calls were the only
//  reason it did, and each of them is a hard dependency on a live desktop session — untestable, and
//  in a test run genuinely undesirable, since `NSWorkspace.open` would launch a browser.
//

import AppKit
import Foundation

@MainActor
protocol SystemIntegrationServing {
    /// Opens `url` in whatever the user has registered for its scheme.
    func open(_ url: URL)

    /// Replaces the general pasteboard's contents with `text`.
    func copyToPasteboard(_ text: String)

    /// Brings Finder forward with `url` selected.
    func revealInFinder(_ url: URL)

    /// Stamps the bundled app icon onto the file at `url`, so a generated shortcut looks like the
    /// app in Finder. Silently does nothing if the icon resource is missing.
    func applyAppIcon(toFileAt url: URL)
}

struct AppKitSystemIntegration: SystemIntegrationServing {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func applyAppIcon(toFileAt url: URL) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSWorkspace.shared.setIcon(icon, forFile: url.path)
    }
}
