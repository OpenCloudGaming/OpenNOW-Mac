//  The file-level actions the recordings library gained on top of Reveal in Finder: hand the video
//  to the system share sheet, copy the file itself, and preview it with Quick Look.
//
//  Beside `RecordingsViewModel` rather than inside it because the library page is at its type-length
//  budget, and because this is one concern: getting a recording out of OpenNOW.
//

import Foundation

extension RecordingsViewModel {
    func share(_ recording: StreamRecording) {
        guard fileIsOnDisk(recording.videoURL) else { return }
        message = systemIntegration.share(recording.videoURL)
            ? "Sharing \(recording.videoURL.lastPathComponent)."
            : "OpenNOW could not open the share sheet for this recording."
    }

    func copyFile(_ recording: StreamRecording) {
        guard fileIsOnDisk(recording.videoURL) else { return }
        message = systemIntegration.copyFileURLToPasteboard(recording.videoURL)
            ? "Copied \(recording.videoURL.lastPathComponent)."
            : "OpenNOW could not copy this recording."
    }

    /// The video Quick Look should present, or nil with an honest message when it is gone.
    func quickLookURL(for recording: StreamRecording) -> URL? {
        fileIsOnDisk(recording.videoURL) ? recording.videoURL : nil
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
