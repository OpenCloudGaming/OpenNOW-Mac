//  File-level actions for the screenshot library: hand the image to the share sheet, copy it as a
//  picture and a file, and preview it with Quick Look.

import Foundation

extension ScreenshotsViewModel {
    func share(_ screenshot: StreamScreenshot) {
        guard isFileOnDisk(screenshot.imageURL) else { return }
        message = systemIntegration.share(screenshot.imageURL)
            ? "Sharing \(screenshot.imageURL.lastPathComponent)."
            : "OpenNOW could not open the share sheet for this screenshot."
    }

    func copyImage(_ screenshot: StreamScreenshot) {
        guard isFileOnDisk(screenshot.imageURL) else { return }
        guard systemIntegration.copyImageToPasteboard(screenshot.imageURL) else {
            message = "OpenNOW could not read this screenshot."
            return
        }
        copiedPathScreenshotID = screenshot.id
        message = "Copied \(screenshot.imageURL.lastPathComponent)."
    }

    /// The image Quick Look should present, or nil with an honest message when it is gone.
    func quickLookURL(for screenshot: StreamScreenshot) -> URL? {
        isFileOnDisk(screenshot.imageURL) ? screenshot.imageURL : nil
    }
}
