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

    /// Puts `imageURL`'s PNG data and its file URL on the general pasteboard. False when the image
    /// could not be read.
    func copyImageToPasteboard(_ imageURL: URL) -> Bool

    /// Puts `fileURL` on the general pasteboard as a file reference, so Finder pastes the file
    /// rather than its path. False when the file is no longer on disk.
    func copyFileURLToPasteboard(_ fileURL: URL) -> Bool

    /// Hands `url` to the system share sheet, anchored on the key window. False when there is no
    /// window to anchor it to.
    func share(_ url: URL) -> Bool

    /// Brings Finder forward with `url` selected.
    func revealInFinder(_ url: URL)

    /// Asks the reader for a directory and returns it, or nil when they cancel. Injected like the
    /// rest of this protocol, so a test can answer without opening a panel.
    func chooseDirectory(prompt: String, startingAt url: URL) -> URL?

    /// Stamps the bundled app icon onto the file at `url`, so a generated shortcut looks like the
    /// app in Finder. Silently does nothing if the icon resource is missing.
    func applyAppIcon(toFileAt url: URL)
}

/// Holds the share picker for the life of the sheet it presents. It must be created on the main
/// actor and shown from an `NSView`, so it cannot be a stored property of the value-type service.
@MainActor
private enum SharingPickerRetention {
    static var picker: NSSharingServicePicker?
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

    func copyImageToPasteboard(_ imageURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: imageURL) else { return false }
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        item.setString(imageURL.absoluteString, forType: .fileURL)
        write([item])
        return true
    }

    func copyFileURLToPasteboard(_ fileURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        let item = NSPasteboardItem()
        item.setString(fileURL.absoluteString, forType: .fileURL)
        write([item])
        return true
    }

    func share(_ url: URL) -> Bool {
        guard let anchor = NSApp.keyWindow?.contentView
            ?? NSApp.mainWindow?.contentView
            ?? NSApp.windows.first?.contentView else { return false }
        let picker = NSSharingServicePicker(items: [url])
        // The picker is not retained by the menu it presents, so it has to outlive this call.
        SharingPickerRetention.picker = picker
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        return true
    }

    private func write(_ objects: [NSPasteboardWriting]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
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
