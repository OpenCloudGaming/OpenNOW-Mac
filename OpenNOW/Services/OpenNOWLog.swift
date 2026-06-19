import Foundation
import OSLog

enum OpenNOWLog {
    static let shortcut = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.interlaced-pixel.OpenNOW", category: "GFNShortcut")
}

@MainActor
final class OpenNOWFileOpenCoordinator {
    static let shared = OpenNOWFileOpenCoordinator()

    private var pendingFileURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        pendingFileURLs.append(url)
        OpenNOWLog.shortcut.info("Queued opened file: \(url.path, privacy: .public)")
        NotificationCenter.default.post(name: .openNOWDidOpenFile, object: url)
    }

    func drainPendingFileURLs() -> [URL] {
        let urls = pendingFileURLs
        pendingFileURLs.removeAll()
        if !urls.isEmpty {
            OpenNOWLog.shortcut.info("Draining \(urls.count, privacy: .public) pending opened file(s)")
        }
        return urls
    }
}
