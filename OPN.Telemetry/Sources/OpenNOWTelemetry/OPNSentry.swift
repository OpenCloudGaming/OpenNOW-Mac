import Foundation
@preconcurrency import Sentry

@objcMembers
@objc(OPNSentryTransaction)
public final class OPNSentryTransaction: NSObject {
    private let span: Span?
    private var finished = false
    private var success: Bool?

    init(name _: String, operation _: String, makeCurrent _: Bool, span: Span?) {
        self.span = span
        super.init()
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

    @objc(addTraceHeaders:)
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

@objcMembers
@objc(OPNSentry)
public final class OPNSentry: NSObject {
    private static let fallbackDsn = "https://75bd4534356a68eb8887bea8f6977b59@o4509317113184256.ingest.us.sentry.io/4511592927264768"
    private static let diagnosticsLogQueue = DispatchQueue(label: "opn.telemetry.diagnostics-log")
    private static let maxDiagnosticsLogBytes = 8 * 1024 * 1024
    private static let maxDiagnosticsUploadBytes = 384 * 1024
    private static let telemetryDisabledKey = "OpenNOW.Telemetry.Disabled"
    private nonisolated(unsafe) static var initialized = false

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
        guard let url = URL(string: "https://paste.rs") else { throw OPNSentryDiagnosticsUploadError.invalidServiceURL }
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
            (responseData, response) = try await URLSession.shared.data(for: request)
            OPNNetworkLog.finish(request, operation: "diagnostics.upload", startedAt: networkStart, data: responseData, response: response, error: nil)
        } catch {
            OPNNetworkLog.finish(request, operation: "diagnostics.upload", startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw OPNSentryDiagnosticsUploadError.invalidResponse }
        switch http.statusCode {
        case 201:
            return try diagnosticsPasteURL(from: responseData)
        case 206:
            throw OPNSentryDiagnosticsUploadError.partialUpload
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

    @objc(addTraceHeadersToRequest:)
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

    @objc(startTransactionWithName:operation:makeCurrent:)
    public static func startTransaction(name: String, operation: String, makeCurrent: Bool) -> OPNSentryTransaction? {
        guard isTelemetryEnabled() else { return nil }
        let resolvedName = name.isEmpty ? "OpenNOW operation" : name
        let resolvedOperation = operation.isEmpty ? "task" : operation
        let span = initialized && SentrySDK.isEnabled ? SentrySDK.startTransaction(name: resolvedName, operation: resolvedOperation, bindToScope: makeCurrent) : nil
        return OPNSentryTransaction(name: resolvedName, operation: resolvedOperation, makeCurrent: makeCurrent, span: span)
    }

    @objc(traceHTTPRequest:name:)
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

    @objc(recordCounterMetricWithKey:value:attributes:)
    public static func recordCounterMetric(key: String, value: Int64, attributes: [String: Any]?) -> Bool {
        guard isTelemetryEnabled(), initialized, SentrySDK.isEnabled, value >= 0 else { return false }
        SentrySDK.metrics.count(key: key, value: UInt(value), attributes: sentryAttributes(from: attributes))
        return true
    }

    @objc(recordGaugeMetricWithKey:value:unit:attributes:)
    public static func recordGaugeMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        guard isTelemetryEnabled(), initialized, SentrySDK.isEnabled else { return false }
        SentrySDK.metrics.gauge(key: key, value: value, unit: sentryUnit(from: unit), attributes: sentryAttributes(from: attributes))
        return true
    }

    @objc(recordDistributionMetricWithKey:value:unit:attributes:)
    public static func recordDistributionMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        guard isTelemetryEnabled(), initialized, SentrySDK.isEnabled else { return false }
        SentrySDK.metrics.distribution(key: key, value: value, unit: sentryUnit(from: unit), attributes: sentryAttributes(from: attributes))
        return true
    }

    private static func sentryAttributes(from attributes: [String: Any]?) -> [String: SentryAttributeValue] {
        var result: [String: SentryAttributeValue] = [:]
        for (key, value) in attributes ?? [:] where !key.isEmpty {
            switch value {
            case let string as String:
                result[key] = string
            case let bool as Bool:
                result[key] = bool
            case let int as Int:
                result[key] = int
            case let int64 as Int64:
                result[key] = Int(clamping: int64)
            case let double as Double:
                result[key] = double
            case let float as Float:
                result[key] = float
            case let strings as [String]:
                result[key] = strings
            case let bools as [Bool]:
                result[key] = bools
            case let ints as [Int]:
                result[key] = ints
            case let doubles as [Double]:
                result[key] = doubles
            default:
                result[key] = String(describing: value)
            }
        }
        return result
    }

    private static func sentryUnit(from unit: String?) -> SentryUnit? {
        guard let unit, !unit.isEmpty else { return nil }
        return SentryUnit(rawValue: unit)
    }

    private static func environmentFlagEnabled(_ name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name] else { return false }
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
    }

    private static func environmentFlagDisabled(_ name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name] else { return false }
        return value == "0" || value.caseInsensitiveCompare("false") == .orderedSame || value.caseInsensitiveCompare("no") == .orderedSame
    }

    private static func environmentDouble(_ name: String) -> Double? {
        guard let value = ProcessInfo.processInfo.environment[name] else { return nil }
        return Double(value)
    }

    private static func environmentString(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func booleanValue(_ value: Any?, defaultValue: Bool) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return defaultValue
    }

    private static func clampedSampleRate(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func resolvedDsn() -> String? {
        guard !environmentFlagEnabled("OPN_DISABLE_SENTRY") else { return nil }
        return environmentString("OPN_SENTRY_DSN") ?? environmentString("SENTRY_DSN") ?? fallbackDsn
    }

    private static func resolvedEnvironment() -> String {
        if let environment = environmentString("OPN_SENTRY_ENVIRONMENT") ?? environmentString("SENTRY_ENVIRONMENT") {
            return environment
        }
        #if DEBUG
        return "debug"
        #else
        return "production"
        #endif
    }

    private static func resolvedReleaseName() -> String? {
        if let release = environmentString("OPN_SENTRY_RELEASE") ?? environmentString("SENTRY_RELEASE") {
            return release
        }
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String)?.isEmpty == false ? info["CFBundleShortVersionString"] as? String ?? "0" : "0"
        let build = (info["CFBundleVersion"] as? String)?.isEmpty == false ? info["CFBundleVersion"] as? String ?? "0" : "0"
        return "\(identifier)@\(version)+\(build)"
    }

    private static func resolvedDist() -> String? {
        if let dist = environmentString("OPN_SENTRY_DIST") ?? environmentString("SENTRY_DIST") {
            return dist
        }
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    private static func sanitize(event: Event) -> Event? {
        if let message = event.message?.formatted, !message.isEmpty {
            event.message = SentryMessage(formatted: sanitizedMessage(message))
        }
        event.logger = event.logger.map(sanitizedMessage)
        event.serverName = nil
        event.transaction = event.transaction.map(sanitizedMessage)
        if let tags = event.tags {
            event.tags = sanitizedStringDictionary(tags)
        }
        if let extra = event.extra {
            event.extra = sanitizedDictionary(extra)
        }
        if let user = event.user {
            user.email = nil
            user.ipAddress = nil
            user.name = nil
            user.username = nil
            user.data = nil
        }
        return event
    }

    private static func sanitize(breadcrumb: Breadcrumb) -> Breadcrumb? {
        breadcrumb.message = breadcrumb.message.map(sanitizedMessage)
        breadcrumb.category = sanitizedMessage(breadcrumb.category)
        if let data = breadcrumb.data {
            breadcrumb.data = sanitizedDictionary(data)
        }
        return breadcrumb
    }

    private static func sanitize(log: SentryLog) -> SentryLog? {
        log.body = sanitizedMessage(log.body)
        log.attributes = sanitizedLogAttributes(log.attributes)
        return log
    }

    private static func sanitizedStringDictionary(_ dictionary: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            result[sanitizedMessage(key)] = sanitizedMessage(value)
        }
        return result
    }

    private static func sanitizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            result[sanitizedMessage(key)] = sanitizedValue(value)
        }
        return result
    }

    private static func sanitizedValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return sanitizedMessage(string)
        case let dictionary as [String: Any]:
            return sanitizedDictionary(dictionary)
        case let array as [Any]:
            return array.map(sanitizedValue)
        default:
            return value
        }
    }

    private static func sanitizedLogAttributes(_ attributes: [String: SentryAttribute]) -> [String: SentryAttribute] {
        var result: [String: SentryAttribute] = [:]
        for (key, attribute) in attributes {
            let sanitizedKey = sanitizedMessage(key)
            if let value = attribute.value as? String {
                result[sanitizedKey] = SentryAttribute(string: sanitizedMessage(value))
            } else if let values = attribute.value as? [String] {
                result[sanitizedKey] = SentryAttribute(stringArray: values.map(sanitizedMessage))
            } else {
                result[sanitizedKey] = attribute
            }
        }
        return result
    }

    private static func sanitizedMessage(_ message: String) -> String {
        var sanitized = message
        let replacements: [(String, String)] = [
            (#"\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#, "[redacted-email]"),
            (#"\b(?:\+\d[\d .()\-]{7,}\d|\d[\d .()\-]{2,}\d[ .()\-]+\d[\d .()\-]*\d)\b"#, "[redacted-phone]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[redacted-ip]"),
            (#"\b[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\b"#, "[redacted-id]"),
            (#"\b[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\.[A-Za-z0-9_-]{12,}\b"#, "[redacted-token]"),
            (#"(?i)(bearer|basic)\s+[^\s,;]+"#, "$1 [redacted-token]"),
            (#"(?i)(x-nv-sessionid[.=])[^\s,;]+"#, "$1[redacted-secret]"),
            (#"(?i)((?:access|refresh|id)?_?token|authorization|password|secret|api[_-]?key|session[_-]?id)([=:]\s*|""\s*:\s*"")[^\s,;\}\""]+"#, "$1$2[redacted-secret]"),
            (#"/Users/[^/\s]+"#, "/Users/[redacted-user]")
        ]
        for replacement in replacements {
            sanitized = sanitized.replacingOccurrences(of: replacement.0, with: replacement.1, options: [.regularExpression, .caseInsensitive])
        }
        return sanitized
    }

    private static func appendDiagnosticsLogLine(_ line: String) {
        guard !line.isEmpty else { return }
        diagnosticsLogQueue.async {
            let url = diagnosticsLogURL()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let entry = "\(timestamp) \(line)\n"
            guard let data = entry.data(using: .utf8) else { return }
            let manager = FileManager.default
            let directory = url.deletingLastPathComponent()
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            trimDiagnosticsLogIfNeeded(url: url)
        }
    }

    private static func diagnosticsLogText() -> String {
        let url = diagnosticsLogURL()
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    private static func diagnosticsLogURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("OpenNOW", isDirectory: true).appendingPathComponent("OpenNOW-diagnostics-current.log")
    }

    private static func trimDiagnosticsLogIfNeeded(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > maxDiagnosticsLogBytes,
              let data = try? Data(contentsOf: url) else { return }
        try? Data(data.suffix(maxDiagnosticsLogBytes)).write(to: url, options: .atomic)
    }

    private static func diagnosticsUploadData(_ text: String) throws -> Data {
        let sanitized = sanitizedUploadLog(text)
        guard let sanitizedData = sanitized.data(using: .utf8), !sanitizedData.isEmpty else { throw OPNSentryDiagnosticsUploadError.emptyLog }
        guard sanitizedData.count > maxDiagnosticsUploadBytes else { return sanitizedData }
        let notice = "OpenNOW diagnostics upload\nNotice: upload is limited to the most recent \(maxDiagnosticsUploadBytes / 1024) KiB because paste.rs rejects larger payloads.\n\n"
        guard let noticeData = notice.data(using: .utf8), noticeData.count < maxDiagnosticsUploadBytes else { throw OPNSentryDiagnosticsUploadError.emptyLog }
        let suffixByteCount = max(0, maxDiagnosticsUploadBytes - noticeData.count - 16)
        var suffixText = String(decoding: sanitizedData.suffix(suffixByteCount), as: UTF8.self)
        if let newlineIndex = suffixText.firstIndex(of: "\n") {
            suffixText.removeSubrange(suffixText.startIndex...newlineIndex)
        }
        while let uploadData = (notice + suffixText).data(using: .utf8) {
            if !uploadData.isEmpty, uploadData.count <= maxDiagnosticsUploadBytes { return uploadData }
            guard !suffixText.isEmpty else { break }
            suffixText.removeFirst()
        }
        throw OPNSentryDiagnosticsUploadError.emptyLog
    }

    private static func diagnosticsPasteURL(from data: Data) throws -> URL {
        guard let responseText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pasteURL = URL(string: responseText),
              pasteURL.scheme == "https",
              pasteURL.host == "paste.rs" else { throw OPNSentryDiagnosticsUploadError.invalidResponse }
        return pasteURL
    }

    private static func sanitizedUploadLog(_ text: String) -> String {
        var sanitized = sanitizedMessage(text)
        let replacements: [(String, String)] = [
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[redacted-ip]"),
            (#"\b[0-9A-F]{1,4}(?::[0-9A-F]{1,4}){2,7}\b"#, "[redacted-ip]"),
            (#"(?i)\b(latitude|longitude|lat|lon|lng)([=:]\s*|""\s*:\s*"")-?\d{1,3}(?:\.\d+)?"#, "$1$2[redacted-location]"),
            (#"(?i)\b(city|country|state|province|postal[_-]?code|zip|timezone|location|region|server[_-]?location)([=:]\s*|""\s*:\s*"")[^\s,;\}\]"]+"#, "$1$2[redacted-location]"),
            (#"(?i)\b[a-z]+-[a-z]+\.cloudmatch[^\s,;\}\]"]*"#, "[redacted-location-host]")
        ]
        for replacement in replacements {
            sanitized = sanitized.replacingOccurrences(of: replacement.0, with: replacement.1, options: [.regularExpression, .caseInsensitive])
        }
        return sanitized
    }

    private static func externalLogLineLooksLikeError(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("error") || lower.contains("exception") || lower.contains("failed") || lower.contains("failure") || lower.contains("crash") || lower.contains("fatal")
    }

    private static func startHTTPTransaction(url: URL?, method: String?, fallbackName: String) -> OPNSentryTransaction? {
        let transaction = startTransaction(name: httpTransactionName(url: url, method: method, fallbackName: fallbackName), operation: "http.client", makeCurrent: false)
        guard let transaction else { return nil }
        let resolvedMethod = (method?.isEmpty == false ? method ?? "GET" : "GET").uppercased()
        transaction.setTag("http.method", value: resolvedMethod)
        if let host = url?.host, !host.isEmpty {
            transaction.setTag("server.address", value: host)
        }
        let sanitizedUrl = sanitizedURLForTrace(url)
        if !sanitizedUrl.isEmpty {
            transaction.setData("url.full", value: sanitizedUrl)
        }
        return transaction
    }

    private static func httpTransactionName(url: URL?, method: String?, fallbackName: String) -> String {
        let resolvedMethod = (method?.isEmpty == false ? method ?? "GET" : "GET").uppercased()
        let host = url?.host?.isEmpty == false ? url?.host ?? "unknown-host" : "unknown-host"
        let path = url?.path.isEmpty == false ? sanitizedURLPath(url?.path ?? "/") : "/"
        let name = "HTTP \(resolvedMethod) \(host)\(path)"
        return name.isEmpty ? fallbackName : name
    }

    private static func sanitizedURLForTrace(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = sanitizedURLPath(components.path)
        return components.string ?? url.host ?? ""
    }

    private static func sanitizedURLPath(_ path: String) -> String {
        path.replacingOccurrences(
            of: #"(?i)((?:/v\d+)?/session/)[^/]+"#,
            with: "$1redacted-id",
            options: [.regularExpression]
        )
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
