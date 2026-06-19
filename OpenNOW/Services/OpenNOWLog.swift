import Foundation
import OSLog
import OpenNOWTelemetry

enum OpenNOWLog {
    enum Category: String {
        case app = "App"
        case auth = "Auth"
        case cache = "Cache"
        case catalog = "Catalog"
        case launch = "Launch"
        case shortcut = "GFNShortcut"
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.interlaced-pixel.OpenNOW"

    static func debug(_ category: Category, _ message: String) {
        let sanitized = sanitizedMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).debug("\(sanitized, privacy: .public)")
        OPNSentry.logDebugMessage(formattedMessage(category: category, level: "debug", message: message))
    }

    static func info(_ category: Category, _ message: String) {
        let sanitized = sanitizedMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).info("\(sanitized, privacy: .public)")
        OPNSentry.logInfoMessage(formattedMessage(category: category, level: "info", message: message))
    }

    static func warning(_ category: Category, _ message: String) {
        let sanitized = sanitizedMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).warning("\(sanitized, privacy: .public)")
        OPNSentry.logWarningMessage(formattedMessage(category: category, level: "warning", message: message))
    }

    static func error(_ category: Category, _ message: String) {
        let sanitized = sanitizedMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).error("\(sanitized, privacy: .public)")
        OPNSentry.logErrorMessage(formattedMessage(category: category, level: "error", message: message))
    }

    static func fatal(_ category: Category, _ message: String) {
        let sanitized = sanitizedMessage(message)
        Logger(subsystem: subsystem, category: category.rawValue).fault("\(sanitized, privacy: .public)")
        OPNSentry.logFatalMessage(formattedMessage(category: category, level: "fatal", message: message))
    }

    private static func formattedMessage(category: Category, level: String, message: String) -> String {
        "[OpenNOW][\(level)][\(category.rawValue)] \(message)"
    }

    private static func sanitizedMessage(_ message: String) -> String {
        var sanitized = message
        let replacements: [(String, String)] = [
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[redacted-email]"),
            (#"\b(?:\+?\d[\d .()\-]{7,}\d)\b"#, "[redacted-phone]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[redacted-ip]"),
            (#"\b[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\b"#, "[redacted-id]"),
            (#"\b[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[redacted-token]"),
            (#"(?i)(bearer|basic)\s+[^\s,;]+"#, "$1 [redacted-token]"),
            (#"(?i)((?:access|refresh|id)?_?token|authorization|password|secret|api[_-]?key|session[_-]?id)([=:]\s*|""\s*:\s*"")[^\s,;\}"""]+"#, "$1$2[redacted-secret]"),
            (#"/Users/[^/\s]+"#, "/Users/[redacted-user]")
        ]
        for replacement in replacements {
            sanitized = sanitized.replacingOccurrences(of: replacement.0, with: replacement.1, options: [.regularExpression, .caseInsensitive])
        }
        return sanitized
    }
}

@MainActor
final class OpenNOWFileOpenCoordinator {
    static let shared = OpenNOWFileOpenCoordinator()

    private var pendingFileURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        pendingFileURLs.append(url)
        OpenNOWLog.info(.shortcut, "Queued opened file: \(url.path)")
        NotificationCenter.default.post(name: .openNOWDidOpenFile, object: url)
    }

    func drainPendingFileURLs() -> [URL] {
        let urls = pendingFileURLs
        pendingFileURLs.removeAll()
        if !urls.isEmpty {
            OpenNOWLog.info(.shortcut, "Draining \(urls.count) pending opened file(s)")
        }
        return urls
    }
}
