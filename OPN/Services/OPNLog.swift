import Foundation
import OSLog

enum OPNLog {
    /// Log text plus whether it has already been through the redaction pass. Scrubbing is
    /// idempotent, so a second pass is only ever wasted work — and on the stream transport's
    /// counter dump that waste is measured in milliseconds on the actor carrying input.
    struct Message: ExpressibleByStringInterpolation {
        let text: String
        let isRedacted: Bool

        init(_ text: String, isRedacted: Bool = false) {
            self.text = text
            self.isRedacted = isRedacted
        }

        init(stringLiteral value: String) {
            self.init(value)
        }

        init(stringInterpolation: DefaultStringInterpolation) {
            self.init(String(describing: stringInterpolation))
        }

        var redacted: String {
            isRedacted ? text : OPNDiagnostics.sanitizedLogMessage(text)
        }
    }

    enum Category: String {
        case app = "App"
        case auth = "Auth"
        case cache = "Cache"
        case catalog = "Catalog"
        case launch = "Launch"
        case memory = "Memory"
        case shortcut = "GFNShortcut"
        case stream = "Stream"
        case controller = "Controller"
        case sync = "Sync"
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.interlaced-pixel.OpenNOW"

    static func debug(_ category: Category, _ message: Message) {
        // The level check comes first here, unlike the other levels: debug is off by default, and
        // redacting a line nothing will read cost 40 µs a call — on the HID report path, that is per
        // controller report, on the thread carrying input.
        guard OPNDiagnostics.shouldLogDebug() else { return }
        // Scrubbed once, then framed: the frame is a fixed prefix, so scrubbing before or after it
        // gives the same text, and both sinks used to pay for the scrub separately.
        let sanitized = message.redacted
        logger(for: category).debug("\(sanitized, privacy: .public)")
        OPNDiagnostics.logDebugMessage(OPNDiagnostics.SanitizedLogMessage(alreadySanitized: formattedMessage(category: category, level: "debug", message: sanitized)))
    }

    static func info(_ category: Category, _ message: Message) {
        // Scrubbed once, then framed: the frame is a fixed prefix, so scrubbing before or after it
        // gives the same text, and both sinks used to pay for the scrub separately.
        let sanitized = message.redacted
        logger(for: category).info("\(sanitized, privacy: .public)")
        OPNDiagnostics.logInfoMessage(OPNDiagnostics.SanitizedLogMessage(alreadySanitized: formattedMessage(category: category, level: "info", message: sanitized)))
    }

    static func warning(_ category: Category, _ message: Message) {
        // Scrubbed once, then framed: the frame is a fixed prefix, so scrubbing before or after it
        // gives the same text, and both sinks used to pay for the scrub separately.
        let sanitized = message.redacted
        logger(for: category).warning("\(sanitized, privacy: .public)")
        OPNDiagnostics.logWarningMessage(OPNDiagnostics.SanitizedLogMessage(alreadySanitized: formattedMessage(category: category, level: "warning", message: sanitized)))
    }

    static func error(_ category: Category, _ message: Message) {
        // Scrubbed once, then framed: the frame is a fixed prefix, so scrubbing before or after it
        // gives the same text, and both sinks used to pay for the scrub separately.
        let sanitized = message.redacted
        logger(for: category).error("\(sanitized, privacy: .public)")
        OPNDiagnostics.logErrorMessage(OPNDiagnostics.SanitizedLogMessage(alreadySanitized: formattedMessage(category: category, level: "error", message: sanitized)))
    }

    static func fatal(_ category: Category, _ message: Message) {
        // Scrubbed once, then framed: the frame is a fixed prefix, so scrubbing before or after it
        // gives the same text, and both sinks used to pay for the scrub separately.
        let sanitized = message.redacted
        logger(for: category).fault("\(sanitized, privacy: .public)")
        OPNDiagnostics.logFatalMessage(OPNDiagnostics.SanitizedLogMessage(alreadySanitized: formattedMessage(category: category, level: "fatal", message: sanitized)))
    }

    static func debug(_ category: Category, _ message: String) {
        debug(category, Message(message))
    }

    static func info(_ category: Category, _ message: String) {
        info(category, Message(message))
    }

    static func warning(_ category: Category, _ message: String) {
        warning(category, Message(message))
    }

    static func error(_ category: Category, _ message: String) {
        error(category, Message(message))
    }

    static func fatal(_ category: Category, _ message: String) {
        fatal(category, Message(message))
    }

    private static func formattedMessage(category: Category, level: String, message: String) -> String {
        OPNDiagnostics.formattedLogMessage(level: level, area: category.rawValue, message: message)
    }

    /// One `Logger` per category rather than one per call. `Logger(subsystem:category:)` is cheap
    /// but not free, and the stream transport writes several long lines every two seconds.
    private static func logger(for category: Category) -> Logger {
        loggersLock.withLock {
            if let existing = loggers[category] { return existing }
            let created = Logger(subsystem: subsystem, category: category.rawValue)
            loggers[category] = created
            return created
        }
    }

    private nonisolated(unsafe) static var loggers: [Category: Logger] = [:]
    private static let loggersLock = NSLock()
}

@MainActor
final class OPNFileOpenCoordinator {
    static let shared = OPNFileOpenCoordinator()

    private var pendingFileURLs: [URL] = []

    private init() {}

    func enqueue(_ url: URL) {
        pendingFileURLs.append(url)
        OPNLog.info(.shortcut, "Queued opened file: \(url.path)")
        NotificationCenter.default.post(name: .opnDidOpenFile, object: url)
    }

    func drainPendingFileURLs() -> [URL] {
        let urls = pendingFileURLs
        pendingFileURLs.removeAll()
        if !urls.isEmpty {
            OPNLog.info(.shortcut, "Draining \(urls.count) pending opened file(s)")
        }
        return urls
    }
}
