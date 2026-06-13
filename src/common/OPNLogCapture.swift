import AppKit
import Foundation

@objc(OPNLogCapture)
final class OPNLogCapture: NSObject {
    private static let queue = DispatchQueue(label: "io.opencg.opennow.log-capture")
    nonisolated(unsafe) private static var events: [String] = []
    nonisolated(unsafe) private static var logFilePath: String?

    @objc static func start() {
        queue.sync {
            _ = capturePathLocked()
        }
    }

    @objc(appendEvent:)
    static func appendEvent(_ message: String) {
        guard !message.isEmpty else { return }
        let line = "\(Date()) \(redactedLogLine(message))"
        queue.sync {
            events.append(line)
            if events.count > 200 { events.removeFirst(events.count - 200) }
            appendLineToFileLocked(line)
        }
    }

    @objc(copyCapturedLogToClipboard:)
    static func copyCapturedLogToClipboard(_ reason: String) {
        if !reason.isEmpty { appendEvent("[Clipboard] Copying diagnostics to clipboard: \(reason)") }

        let log = queue.sync { events.joined(separator: "\n") }
        let clipboardText = log.isEmpty
            ? (reason.isEmpty ? "OpenNOW diagnostics copy requested, but no in-memory events were available." : reason)
            : log

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardText, forType: .string)
        NSLog("[LogCapture] Copied diagnostics to clipboard (\(clipboardText.count) chars)")
    }

    @objc static func capturedLogPath() -> String {
        queue.sync { capturePathLocked() ?? "" }
    }

    private static func capturePathLocked() -> String? {
        if let logFilePath { return logFilePath }
        let fileManager = FileManager.default
        let directory: URL
        if let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            directory = applicationSupport.appendingPathComponent("OpenNOW", isDirectory: true)
        } else {
            directory = fileManager.temporaryDirectory.appendingPathComponent("OpenNOW", isDirectory: true)
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("OpenNOW-Diagnostics.log", isDirectory: false)
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            logFilePath = url.path
            return url.path
        } catch {
            NSLog("[LogCapture] Failed to prepare diagnostics log: \(error.localizedDescription)")
            return nil
        }
    }

    private static func appendLineToFileLocked(_ line: String) {
        guard let path = capturePathLocked(), let data = (line + "\n").data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("[LogCapture] Failed to append diagnostics log: \(error.localizedDescription)")
        }
    }

    private static func redactedLogLine(_ line: String) -> String {
        var redacted = line
        redacted = replacingMatches(in: redacted, pattern: #"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, replacement: "[redacted-email]")
        redacted = replacingMatches(in: redacted, pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, replacement: "[redacted-ip]")
        redacted = replacingMatches(in: redacted, pattern: #"\b[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\b"#, replacement: "[redacted-id]")
        redacted = replacingMatches(in: redacted, pattern: #"\b[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, replacement: "[redacted-token]")
        redacted = replacingMatches(in: redacted, pattern: #"(bearer|basic|gfnjwt)\s+[^\s,;]+"#, replacement: "$1 [redacted-token]")
        redacted = replacingMatches(in: redacted, pattern: #"((?:access|refresh|id|client)?_?token|authorization|password|secret|api[_-]?key|session[_-]?id|credential|ice[_-]?pwd)([=:]\s*|"\s*:\s*")[^\s,;\}"]+"#, replacement: "$1$2[redacted-secret]")
        redacted = replacingMatches(in: redacted, pattern: #"/Users/[^/\s]+"#, replacement: "/Users/[redacted-user]")
        return redacted
    }

    private static func replacingMatches(in value: String, pattern: String, replacement: String) -> String {
        guard !value.isEmpty, let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        return expression.stringByReplacingMatches(in: value, options: [], range: NSRange(location: 0, length: (value as NSString).length), withTemplate: replacement)
    }
}
