//  Formats how long the current stream has been connected, for the HUD's SESSION panel.
//

import Foundation

enum StreamSessionElapsedTime {
    /// `M:SS` under an hour, `H:MM:SS` above it, and `--` until the session reports a start. A
    /// backwards clock reads as zero rather than a negative time.
    static func text(since startedAt: Date?, at now: Date) -> String {
        guard let startedAt else { return "--" }
        let elapsedSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let hours = elapsedSeconds / 3600
        let minutes = (elapsedSeconds % 3600) / 60
        let seconds = elapsedSeconds % 60
        guard hours > 0 else { return String(format: "%d:%02d", minutes, seconds) }
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
}
