//  The file-level actions the screenshot library gained on top of Reveal in Finder: hand the image
//  to the system share sheet, copy it as a picture and a file, and preview it with Quick Look.
//
//  Beside `ScreenshotsViewModel` rather than inside it for the same reason as the recordings pair:
//  one concern, and a type already at its length budget.
//

import Foundation

extension ScreenshotsViewModel {
    func share(_ screenshot: StreamScreenshot) {
        guard fileIsOnDisk(screenshot.imageURL) else { return }
        message = systemIntegration.share(screenshot.imageURL)
            ? "Sharing \(screenshot.imageURL.lastPathComponent)."
            : "OpenNOW could not open the share sheet for this screenshot."
    }

    func copyImage(_ screenshot: StreamScreenshot) {
        guard fileIsOnDisk(screenshot.imageURL) else { return }
        guard systemIntegration.copyImageToPasteboard(screenshot.imageURL) else {
            message = "OpenNOW could not read this screenshot."
            return
        }
        copiedPathScreenshotID = screenshot.id
        message = "Copied \(screenshot.imageURL.lastPathComponent)."
    }

    /// The image Quick Look should present, or nil with an honest message when it is gone.
    func quickLookURL(for screenshot: StreamScreenshot) -> URL? {
        fileIsOnDisk(screenshot.imageURL) ? screenshot.imageURL : nil
    }

    /// The library is a directory scan read once, so any of these actions can find the file already
    /// moved or deleted after the page loaded.
    private func fileIsOnDisk(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "\(url.lastPathComponent) is no longer on disk."
            return false
        }
        return true
    }
}
