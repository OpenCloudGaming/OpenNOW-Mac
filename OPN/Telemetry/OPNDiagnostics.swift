import Foundation

/// Local support diagnostics: the bounded, redacted log file a host can send to a developer on
/// request, plus the one upload path that posts it to a public paste service.
///
/// Nothing here leaves the Mac on its own. Every line is written to stderr and appended to the
/// diagnostics file; the upload runs only after the host confirms it, from Settings or the Report an
/// Issue sheet. The clipboard fallback lives with the caller that presents that confirmation
/// (`CatalogViewModel`).
///
/// This used to be the Sentry integration's front door, and every sink below was gated on a
/// "telemetry" preference that also switched Sentry off. Sentry is gone (NEC-47): local logging is
/// now unconditional, and the only levels that stay opt-in are the high-volume debug/verbose ones a
/// developer turns on with `OPN_DEBUG_LOGS` / `OPN_VERBOSE_LOGS`.
enum OPNDiagnostics {
    static let diagnosticsLogQueue = DispatchQueue(label: "opn.diagnostics.diagnostics-log")
    static let maxDiagnosticsLogBytes = 8 * 1024 * 1024
    /// What a trim cuts back to. Below the ceiling on purpose — see `trimDiagnosticsLogIfNeeded`.
    static let trimmedDiagnosticsLogBytes = 6 * 1024 * 1024
    static let maxDiagnosticsUploadBytes = 384 * 1024

    // MARK: - Levels

    /// A developer switch for noise-free runs, not a user setting. It never gated the diagnostics
    /// file — see `logInfoMessage` — and it does not gate it now.
    static func shouldLogInfo() -> Bool {
        !environmentFlagEnabled("OPN_DISABLE_INFO_LOGS")
    }

    public static func shouldLogDebug() -> Bool {
        environmentFlagEnabled("OPN_DEBUG_LOGS") || environmentFlagEnabled("OPN_VERBOSE_LOGS")
    }

    public static func shouldLogVerbose() -> Bool {
        environmentFlagEnabled("OPN_VERBOSE_LOGS")
    }

    // MARK: - Message shaping

    public static func sanitizedLogMessage(_ message: String) -> String {
        sanitizedMessage(message)
    }

    public static func formattedLogMessage(level: String, area: String, message: String) -> String {
        let resolvedLevel = level.isEmpty ? "info" : level.lowercased()
        let resolvedArea = area.isEmpty ? "General" : area
        return "[OPN][\(resolvedLevel)][\(resolvedArea)] \(message)"
    }

    // MARK: - Local sinks

    enum Level: String {
        case debug
        case info
        case warning
        case error
        case fatal
    }

    /// Every level reaches the diagnostics file. `debug` is the only exception, and it is a
    /// developer opt-in (`OPN_DEBUG_LOGS` / `OPN_VERBOSE_LOGS`) rather than a user preference: it is
    /// the high-volume level, and a shipped build must not pay for it. The retired
    /// `OpenNOW.Telemetry.Disabled` key is not consulted here, or anywhere else — a fatal line and a
    /// telemetry event are recorded whatever that value says.
    static func recordsLocally(_ level: Level) -> Bool {
        level != .debug || shouldLogDebug()
    }

    static func log(_ level: Level, _ message: SanitizedLogMessage) {
        guard recordsLocally(level) else { return }
        writeLocally(message.value)
    }

    public static func logDebugMessage(_ message: String) {
        log(.debug, SanitizedLogMessage(message))
    }

    static func logDebugMessage(_ message: SanitizedLogMessage) {
        log(.debug, message)
    }

    public static func logInfoMessage(_ message: String) {
        log(.info, SanitizedLogMessage(message))
    }

    static func logInfoMessage(_ message: SanitizedLogMessage) {
        log(.info, message)
    }

    public static func logWarningMessage(_ message: String) {
        log(.warning, SanitizedLogMessage(message))
    }

    static func logWarningMessage(_ message: SanitizedLogMessage) {
        log(.warning, message)
    }

    public static func logErrorMessage(_ message: String) {
        log(.error, SanitizedLogMessage(message))
    }

    static func logErrorMessage(_ message: SanitizedLogMessage) {
        log(.error, message)
    }

    public static func logFatalMessage(_ message: String) {
        log(.fatal, SanitizedLogMessage(message))
    }

    static func logFatalMessage(_ message: SanitizedLogMessage) {
        log(.fatal, message)
    }

    /// A line a framework logged to stderr itself. Error-shaped lines are always kept; the rest
    /// follow the same developer-facing info switch the app's own info lines follow.
    static func captureExternalLogLine(_ line: String) {
        guard !line.isEmpty else { return }
        guard externalLogLineLooksLikeError(line) || shouldLogInfo() else { return }
        writeLocally(sanitizedMessage(line))
    }

    /// The diagnostics buffer is not a telemetry channel: nothing leaves this Mac until a host
    /// presses "Generate Diagnostics" themselves. Gating it behind a background-reporting flag meant
    /// that button was silently empty for any host who had turned reporting off, which defeats the
    /// one thing it was for. Every level writes for every run, whatever the retired preference said.
    private static func writeLocally(_ sanitized: String) {
        fputs("\(sanitized)\n", stderr)
        appendDiagnosticsLogLine(sanitized)
    }

    // MARK: - Support upload

    /// Reads and scrubs the whole diagnostics log — up to `maxDiagnosticsLogBytes` of it, through a
    /// dozen regular expressions. Callers must not be on the main actor: this is seconds of work on
    /// a full file, and the button that triggers it is in the settings UI.
    public static func diagnosticsLogForUpload() async -> String {
        await withCheckedContinuation { continuation in
            diagnosticsLogQueue.async {
                let log = diagnosticsLogText()
                continuation.resume(returning: sanitizedUploadLog(log.isEmpty ? "No OpenNOW diagnostics log lines recorded for this run." : log))
            }
        }
    }

    public static func uploadDiagnosticsLog(_ logText: String) async throws -> URL {
        guard let url = URL(string: "https://paste.c-net.org/") else { throw OPNDiagnosticsUploadError.invalidServiceURL }
        return try await uploadDiagnosticsLog(logText, session: .shared, uploadURL: url)
    }

    static func uploadDiagnosticsLog(_ logText: String, session: URLSession, uploadURL: URL) async throws -> URL {
        guard uploadURL.scheme == "https" else { throw OPNDiagnosticsUploadError.invalidServiceURL }
        let data = try diagnosticsUploadData(logText)
        var request = URLRequest(url: uploadURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let networkStart = OPNNetworkLog.start(request, operation: "diagnostics.upload")
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
            OPNNetworkLog.finish(operation: "diagnostics.upload", startedAt: networkStart, data: responseData, response: response, error: nil)
        } catch {
            OPNNetworkLog.finish(operation: "diagnostics.upload", startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw OPNDiagnosticsUploadError.invalidResponse }
        switch http.statusCode {
        // 206 first: it is a success code, but a partial upload is not a usable paste.
        case 206:
            throw OPNDiagnosticsUploadError.partialUpload
        // Any other 2xx is a success. Accepting only 201 reported a completed upload as
        // "Diagnostics upload failed with HTTP 200" — the paste service answers 200, and the body
        // still carries the URL, so the log was uploaded and then thrown away.
        case 200...299:
            return try diagnosticsPasteURL(from: responseData)
        case 413:
            throw OPNDiagnosticsUploadError.logTooLarge
        case 429:
            throw OPNDiagnosticsUploadError.rateLimited
        case 500...599:
            throw OPNDiagnosticsUploadError.serviceUnavailable(http.statusCode)
        default:
            throw OPNDiagnosticsUploadError.httpStatus(http.statusCode)
        }
    }

    /// Starts a fresh log for this run.
    ///
    /// Deliberately asynchronous. This is the first statement of `OPNApp.init()`, and a `.sync` here
    /// put a directory create and an atomic truncate on the launch path before anything else ran.
    /// Nothing is lost by queueing it: `diagnosticsLogQueue` is serial, so the clear still lands
    /// before the first append submitted after it, and that append reopens the handle the clear
    /// closed. The one reader, `diagnosticsLogForUpload`, goes through the same queue.
    public static func clearDiagnosticsLogForNewRun() {
        clearDiagnosticsLogForNewRun(at: diagnosticsLogURL())
    }

    /// The clear itself, submitted to the log queue rather than run on the caller. The URL is a
    /// parameter so a test can point it at a temporary file and observe the ordering the launch path
    /// relies on.
    static func clearDiagnosticsLogForNewRun(at url: URL) {
        diagnosticsLogQueue.async {
            clearDiagnosticsLog(at: url)
            closeDiagnosticsLogHandle()
        }
    }
}

public enum OPNDiagnosticsUploadError: LocalizedError {
    case emptyLog
    case invalidServiceURL
    case invalidResponse
    case partialUpload
    case logTooLarge
    case rateLimited
    case serviceUnavailable(Int)
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyLog: return "Diagnostics log is empty."
        case .invalidServiceURL: return "Diagnostics upload service URL is invalid."
        case .invalidResponse: return "Diagnostics upload service returned an invalid response."
        case .partialUpload: return "Diagnostics upload service would only save a partial log. Try again after reopening the app to start a smaller current-run log."
        case .logTooLarge: return "Diagnostics log is too large for the upload service. Try again after reopening the app to start a smaller current-run log."
        case .rateLimited: return "Diagnostics upload service is rate limited. Try again later."
        case .serviceUnavailable(let status): return "Diagnostics upload service is temporarily unavailable (HTTP \(status)). Try again later."
        case .httpStatus(let status): return "Diagnostics upload failed with HTTP \(status)."
        }
    }
}
