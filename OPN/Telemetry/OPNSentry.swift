import Foundation
@preconcurrency import Sentry

public final class OPNSentryTransaction {
    private let span: Span?
    private var finished = false
    private var success: Bool?

    init(name _: String, operation _: String, makeCurrent _: Bool, span: Span?) {
        self.span = span
    }

    deinit {
        finish()
    }

    public func setTag(_ key: String, value: String) {
        guard OPNSentry.isTelemetryEnabled(), !key.isEmpty else { return }
        span?.setTag(value: value, key: key)
    }

    public func setData(_ key: String, value: String) {
        guard OPNSentry.isTelemetryEnabled(), !key.isEmpty else { return }
        span?.setData(value: value, key: key)
    }

    public func setStatus(_ success: Bool) {
        guard OPNSentry.isTelemetryEnabled() else { return }
        self.success = success
    }

    public func addTraceHeaders(_ request: NSMutableURLRequest) {
        OPNSentry.addTraceHeaders(from: span, to: request)
    }

    public func addTraceHeaders(to request: inout URLRequest) {
        OPNSentry.addTraceHeaders(from: span, to: &request)
    }

    public func finish() {
        guard !finished else { return }
        finished = true
        guard OPNSentry.isTelemetryEnabled() else { return }
        if let success {
            span?.finish(status: success ? .ok : .internalError)
        } else {
            span?.finish()
        }
    }
}

extension OPNSentryTransaction: @unchecked Sendable {}

final class OPNSentry {
    static let dsnInfoPlistKey = "OPNSentryDSN"
    static let diagnosticsLogQueue = DispatchQueue(label: "opn.telemetry.diagnostics-log")
    static let maxDiagnosticsLogBytes = 8 * 1024 * 1024
    static let maxDiagnosticsUploadBytes = 384 * 1024
    private static let telemetryDisabledKey = "OpenNOW.Telemetry.Disabled"
    nonisolated(unsafe) static var initialized = false

    public static func isTelemetryDisabled() -> Bool {
        telemetryDisabled(defaults: .standard)
    }

    public static func isTelemetryEnabled() -> Bool {
        !isTelemetryDisabled()
    }

    public static func setTelemetryDisabled(_ disabled: Bool) {
        setTelemetryDisabled(disabled, defaults: .standard)
        if disabled {
            closeSentry()
        } else {
            initializeSentry()
        }
    }

    static func telemetryDisabled(defaults: UserDefaults) -> Bool {
        booleanValue(defaults.object(forKey: telemetryDisabledKey), defaultValue: false)
    }

    static func setTelemetryDisabled(_ disabled: Bool, defaults: UserDefaults) {
        defaults.set(disabled, forKey: telemetryDisabledKey)
        defaults.synchronize()
    }

    public static func initializeSentry() {
        guard isTelemetryEnabled() else {
            closeSentry()
            return
        }
        guard !initialized else { return }
        guard let dsn = resolvedDsn(), !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = environmentFlagEnabled("OPN_SENTRY_DEBUG")
            options.diagnosticLevel = options.debug ? .debug : .error
            options.sendDefaultPii = !environmentFlagDisabled("OPN_SENTRY_SEND_PII")
            options.environment = resolvedEnvironment()
            options.releaseName = resolvedReleaseName()
            options.dist = resolvedDist()
            options.sampleRate = NSNumber(value: clampedSampleRate(environmentDouble("OPN_SENTRY_EVENT_SAMPLE_RATE") ?? 1.0))
            options.tracesSampleRate = NSNumber(value: clampedSampleRate(environmentDouble("OPN_SENTRY_TRACES_SAMPLE_RATE") ?? 0.25))
            options.configureProfiling = {
                $0.lifecycle = .trace
                // Continuous profiling is CPU-expensive during catalog/session
                // transactions. Default to a conservative sample rate and keep the
                // environment override for higher-fidelity diagnostics.
                $0.sessionSampleRate = Float(clampedSampleRate(environmentDouble("OPN_SENTRY_PROFILES_SAMPLE_RATE") ?? 0.25))
            }
            options.enableAutoSessionTracking = true
            options.enableLogs = true
            options.enableMetrics = true
            options.attachStacktrace = true
            options.attachAllThreads = false
            options.beforeSend = { event in sanitize(event: event) }
            options.beforeBreadcrumb = { breadcrumb in sanitize(breadcrumb: breadcrumb) }
            options.beforeSendLog = { log in sanitize(log: log) }
            options.onLastRunStatusDetermined = { status, _ in
                let message = "[Sentry] Last run status: \(status.description)"
                fputs("\(message)\n", stderr)
                appendDiagnosticsLogLine(message)
            }
        }
        initialized = true
    }

    public static func clearDiagnosticsLogForNewRun() {
        diagnosticsLogQueue.sync {
            clearDiagnosticsLog(at: diagnosticsLogURL())
        }
    }

    static func closeSentry() {
        guard initialized else { return }
        SentrySDK.close()
        initialized = false
    }

    static func shouldLogInfo() -> Bool {
        isTelemetryEnabled() && !environmentFlagEnabled("OPN_DISABLE_INFO_LOGS")
    }

    public static func shouldLogDebug() -> Bool {
        isTelemetryEnabled() && (environmentFlagEnabled("OPN_DEBUG_LOGS") || environmentFlagEnabled("OPN_VERBOSE_LOGS"))
    }

    public static func shouldLogVerbose() -> Bool {
        isTelemetryEnabled() && environmentFlagEnabled("OPN_VERBOSE_LOGS")
    }

    public static func sanitizedLogMessage(_ message: String) -> String {
        sanitizedMessage(message)
    }

    public static func formattedLogMessage(level: String, area: String, message: String) -> String {
        let resolvedLevel = level.isEmpty ? "info" : level.lowercased()
        let resolvedArea = area.isEmpty ? "General" : area
        return "[OpenNOW][\(resolvedLevel)][\(resolvedArea)] \(message)"
    }

    public static func logDebugMessage(_ message: String) {
        guard shouldLogDebug() else { return }
        let sanitized = sanitizedMessage(message)
        fputs("\(sanitized)\n", stderr)
        appendDiagnosticsLogLine(sanitized)
        guard initialized, SentrySDK.isEnabled else { return }
        SentrySDK.logger.debug(sanitized)
    }

    public static func logInfoMessage(_ message: String) {
        guard shouldLogInfo() else { return }
        let sanitized = sanitizedMessage(message)
        fputs("\(sanitized)\n", stderr)
        appendDiagnosticsLogLine(sanitized)
        guard initialized, SentrySDK.isEnabled else { return }
        SentrySDK.logger.info(sanitized)
    }

    public static func logWarningMessage(_ message: String) {
        guard isTelemetryEnabled() else { return }
        let sanitized = sanitizedMessage(message)
        fputs("\(sanitized)\n", stderr)
        appendDiagnosticsLogLine(sanitized)
        guard initialized, SentrySDK.isEnabled else { return }
        SentrySDK.logger.warn(sanitized)
    }

    public static func logErrorMessage(_ message: String) {
        guard isTelemetryEnabled() else { return }
        let sanitized = sanitizedMessage(message)
        fputs("\(sanitized)\n", stderr)
        appendDiagnosticsLogLine(sanitized)
        guard initialized, SentrySDK.isEnabled else { return }
        SentrySDK.logger.error(sanitized)
        SentrySDK.capture(message: sanitized)
    }

    public static func logFatalMessage(_ message: String) {
        guard isTelemetryEnabled() else { return }
        let sanitized = sanitizedMessage(message)
        fputs("\(sanitized)\n", stderr)
        appendDiagnosticsLogLine(sanitized)
        guard initialized, SentrySDK.isEnabled else { return }
        SentrySDK.logger.fatal(sanitized)
        SentrySDK.capture(message: sanitized)
    }

    static func captureExternalLogLine(_ line: String) {
        guard isTelemetryEnabled() else { return }
        guard !line.isEmpty else { return }
        if externalLogLineLooksLikeError(line) || shouldLogInfo() {
            let sanitized = sanitizedMessage(line)
            fputs("\(sanitized)\n", stderr)
            appendDiagnosticsLogLine(sanitized)
            guard initialized, SentrySDK.isEnabled else { return }
            if externalLogLineLooksLikeError(line) {
                SentrySDK.logger.error(sanitized)
                SentrySDK.capture(message: sanitized)
            } else {
                SentrySDK.logger.info(sanitized)
            }
        }
    }

    public static func diagnosticsLogForUpload() -> String {
        let log = diagnosticsLogQueue.sync { diagnosticsLogText() }
        return sanitizedUploadLog(log.isEmpty ? "No OpenNOW diagnostics log lines recorded for this run." : log)
    }

    public static func uploadDiagnosticsLog(_ logText: String) async throws -> URL {
        guard let url = URL(string: "https://paste.c-net.org/") else { throw OPNSentryDiagnosticsUploadError.invalidServiceURL }
        return try await uploadDiagnosticsLog(logText, session: .shared, uploadURL: url)
    }

    static func uploadDiagnosticsLog(_ logText: String, session: URLSession, uploadURL: URL) async throws -> URL {
        guard uploadURL.scheme == "https" else { throw OPNSentryDiagnosticsUploadError.invalidServiceURL }
        let data = try diagnosticsUploadData(logText)
        var request = URLRequest(url: uploadURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let networkStart = OPNNetworkLog.start(&request, operation: "diagnostics.upload")
        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
            OPNNetworkLog.finish(request, operation: "diagnostics.upload", startedAt: networkStart, data: responseData, response: response, error: nil)
        } catch {
            OPNNetworkLog.finish(request, operation: "diagnostics.upload", startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw OPNSentryDiagnosticsUploadError.invalidResponse }
        switch http.statusCode {
        // 206 first: it is a success code, but a partial upload is not a usable paste.
        case 206:
            throw OPNSentryDiagnosticsUploadError.partialUpload
        // Any other 2xx is a success. Accepting only 201 reported a completed upload as
        // "Diagnostics upload failed with HTTP 200" — the paste service answers 200, and the body
        // still carries the URL, so the log was uploaded and then thrown away.
        case 200...299:
            return try diagnosticsPasteURL(from: responseData)
        case 413:
            throw OPNSentryDiagnosticsUploadError.logTooLarge
        case 429:
            throw OPNSentryDiagnosticsUploadError.rateLimited
        case 500...599:
            throw OPNSentryDiagnosticsUploadError.serviceUnavailable(http.statusCode)
        default:
            throw OPNSentryDiagnosticsUploadError.httpStatus(http.statusCode)
        }
    }

    public static func addTraceHeaders(to request: NSMutableURLRequest) {
        guard isTelemetryEnabled() else { return }
        addTraceHeaders(from: SentrySDK.span, to: request)
    }

    static func addTraceHeaders(from span: Span?, to request: NSMutableURLRequest) {
        guard isTelemetryEnabled(), initialized, SentrySDK.isEnabled, let span else { return }
        request.setValue(span.toTraceHeader().value(), forHTTPHeaderField: "sentry-trace")
        if let baggage = span.baggageHttpHeader(), !baggage.isEmpty {
            request.setValue(baggage, forHTTPHeaderField: "baggage")
        }
    }

    static func addTraceHeaders(from span: Span?, to request: inout URLRequest) {
        guard isTelemetryEnabled(), initialized, SentrySDK.isEnabled, let span else { return }
        request.setValue(span.toTraceHeader().value(), forHTTPHeaderField: "sentry-trace")
        if let baggage = span.baggageHttpHeader(), !baggage.isEmpty {
            request.setValue(baggage, forHTTPHeaderField: "baggage")
        }
    }

    public static func startTransaction(name: String, operation: String, makeCurrent: Bool) -> OPNSentryTransaction? {
        guard isTelemetryEnabled() else { return nil }
        let resolvedName = name.isEmpty ? "OpenNOW operation" : name
        let resolvedOperation = operation.isEmpty ? "task" : operation
        let span = initialized && SentrySDK.isEnabled ? SentrySDK.startTransaction(name: resolvedName, operation: resolvedOperation, bindToScope: makeCurrent) : nil
        return OPNSentryTransaction(name: resolvedName, operation: resolvedOperation, makeCurrent: makeCurrent, span: span)
    }

    public static func traceHTTPRequest(_ request: NSMutableURLRequest, name: String) -> OPNSentryTransaction? {
        let transaction = startHTTPTransaction(url: request.url, method: request.httpMethod, fallbackName: name)
        guard let transaction else { return nil }
        transaction.addTraceHeaders(request)
        return transaction
    }

    public static func traceHTTPRequest(_ request: inout URLRequest, name: String) -> OPNSentryTransaction? {
        let transaction = startHTTPTransaction(url: request.url, method: request.httpMethod, fallbackName: name)
        guard let transaction else { return nil }
        transaction.addTraceHeaders(to: &request)
        return transaction
    }

    public static func startHTTPTransaction(for request: URLRequest, name: String) -> OPNSentryTransaction? {
        startHTTPTransaction(url: request.url, method: request.httpMethod, fallbackName: name)
    }
}

public enum OPNSentryDiagnosticsUploadError: LocalizedError {
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
