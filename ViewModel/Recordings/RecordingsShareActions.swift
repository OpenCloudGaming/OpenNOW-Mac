//  File-level actions for the recordings library: hand the video to the share sheet, copy the file
//  itself, and preview it with Quick Look.

import Foundation

extension RecordingsViewModel {
    func share(_ recording: StreamRecording) {
        guard isFileOnDisk(recording.videoURL) else { return }
        message = systemIntegration.share(recording.videoURL)
            ? "Sharing \(recording.videoURL.lastPathComponent)."
            : "OpenNOW could not open the share sheet for this recording."
    }

    func copyFile(_ recording: StreamRecording) {
        guard isFileOnDisk(recording.videoURL) else { return }
        message = systemIntegration.copyFileURLToPasteboard(recording.videoURL)
            ? "Copied \(recording.videoURL.lastPathComponent)."
            : "OpenNOW could not copy this recording."
    }

    /// The video Quick Look should present, or nil with an honest message when it is gone.
    func quickLookURL(for recording: StreamRecording) -> URL? {
        isFileOnDisk(recording.videoURL) ? recording.videoURL : nil
    }
}
