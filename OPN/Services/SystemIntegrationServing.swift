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

    /// The location of an installed app with `identifier` as its bundle id, or nil when it is not
    /// installed. Lets a hand-off reach a specific client — such as NVIDIA's own GeForce NOW app for
    /// the feedback it alone can submit — instead of a generic URL.
    func applicationURL(forBundleIdentifier identifier: String) -> URL?

    /// Launches the app at `url` and brings it forward. Callers confirm installation first through
    /// `applicationURL(forBundleIdentifier:)`.
    func openApplication(at url: URL)

    /// Replaces the general pasteboard's contents with `text`.
    func copyToPasteboard(_ text: String)

    /// Brings Finder forward with `url` selected.
    func revealInFinder(_ url: URL)

    /// Asks the reader for a directory and returns it, or nil when they cancel. Injected like the
    /// rest of this protocol so a view model never has to import AppKit, and so a test can answer
    /// without opening a panel.
    func chooseDirectory(prompt: String, startingAt url: URL) -> URL?

    /// Stamps the bundled app icon onto the file at `url`, so a generated shortcut looks like the
    /// app in Finder. Silently does nothing if the icon resource is missing.
    func applyAppIcon(toFileAt url: URL)
}

struct AppKitSystemIntegration: SystemIntegrationServing {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func applicationURL(forBundleIdentifier identifier: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    func openApplication(at url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func chooseDirectory(prompt: String, startingAt url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.message = prompt
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = url
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    func applyAppIcon(toFileAt url: URL) {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSWorkspace.shared.setIcon(icon, forFile: url.path)
    }
}
