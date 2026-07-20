import Foundation
import OSLog

enum MacForceNowLog {
    enum Category: String {
        case app = "App"
        case auth = "Auth"
        case cache = "Cache"
        case catalog = "Catalog"
        case launch = "Launch"
        case shortcut = "GFNShortcut"
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.interlaced-pixel.MacForceNow"

    static func debug(_ category: Category, _ message: String) {
        let sanitized = OPNSentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).debug("\(sanitized, privacy: .public)")
        OPNSentry.logDebugMessage(formattedMessage(category: category, level: "debug", message: message))
    }

    static func info(_ category: Category, _ message: String) {
        let sanitized = OPNSentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).info("\(sanitized, privacy: .public)")
        OPNSentry.logInfoMessage(formattedMessage(category: category, level: "info", message: message))
    }

    static func warning(_ category: Category, _ message: String) {
        let sanitized = OPNSentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).warning("\(sanitized, privacy: .public)")
        OPNSentry.logWarningMessage(formattedMessage(category: category, level: "warning", message: message))
    }

    static func error(_ category: Category, _ message: String) {
        let sanitized = OPNSentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).error("\(sanitized, privacy: .public)")
        OPNSentry.logErrorMessage(formattedMessage(category: category, level: "error", message: message))
    }

    static func fatal(_ category: Category, _ message: String) {
        let sanitized = OPNSentry.sanitizedLogMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).fault("\(sanitized, privacy: .public)")
        OPNSentry.logFatalMessage(formattedMessage(category: category, level: "fatal", message: message))
    }

    private static func formattedMessage(category: Category, level: String, message: String) -> String {
        OPNSentry.formattedLogMessage(level: level, area: category.rawValue, message: message)
    }
}

@MainActor
final class MacForceNowFileOpenCoordinator {
    static let shared = MacForceNowFileOpenCoordinator()

    private var pendingFileURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        pendingFileURLs.append(url)
        MacForceNowLog.info(.shortcut, "Queued opened file: \(url.path)")
        NotificationCenter.default.post(name: .openNOWDidOpenFile, object: url)
    }

    func drainPendingFileURLs() -> [URL] {
        let urls = pendingFileURLs
        pendingFileURLs.removeAll()
        if !urls.isEmpty {
            MacForceNowLog.info(.shortcut, "Draining \(urls.count) pending opened file(s)")
        }
        return urls
    }
}
