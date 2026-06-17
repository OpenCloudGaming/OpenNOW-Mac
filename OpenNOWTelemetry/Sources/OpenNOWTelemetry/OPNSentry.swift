import Foundation
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
        guard !key.isEmpty else { return }
        span?.setTag(value: value, key: key)
    }

    public func setData(_ key: String, value: String) {
        guard !key.isEmpty else { return }
        span?.setData(value: value, key: key)
    }

    public func setStatus(_ success: Bool) {
        self.success = success
    }

    @objc(addTraceHeaders:)
    public func addTraceHeaders(_ request: NSMutableURLRequest) {
        OPNSentry.addTraceHeaders(from: span, to: request)
    }

    public func finish() {
        guard !finished else { return }
        finished = true
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
    private static let fallbackDsn = "https://9db09e478cd379b8abdb101361ae5248@o4509317113184256.ingest.us.sentry.io/4511552111247360"
    private nonisolated(unsafe) static var initialized = false

    public static func initializeSentry() {
        guard !initialized else { return }
        guard let dsn = resolvedDsn(), !dsn.isEmpty else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = environmentFlagEnabled("OPN_SENTRY_DEBUG")
            options.diagnosticLevel = options.debug ? .debug : .error
            options.sendDefaultPii = environmentFlagEnabled("OPN_SENTRY_SEND_PII")
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
        !environmentFlagEnabled("OPN_DISABLE_INFO_LOGS")
    }

    public static func logInfoMessage(_ message: String) {
        guard shouldLogInfo() else { return }
        let sanitized = sanitizedMessage(message)
        fputs("\(sanitized)\n", stderr)
        guard initialized, SentrySDK.isEnabled else { return }
        SentrySDK.logger.info(sanitized)
    }

    public static func logErrorMessage(_ message: String) {
        let sanitized = sanitizedMessage(message)
        fputs("\(sanitized)\n", stderr)
        guard initialized, SentrySDK.isEnabled else { return }
        SentrySDK.logger.error(sanitized)
        SentrySDK.capture(message: sanitized)
    }

    static func captureExternalLogLine(_ line: String) {
        guard !line.isEmpty else { return }
        if externalLogLineLooksLikeError(line) || shouldLogInfo() {
            let sanitized = sanitizedMessage(line)
            fputs("\(sanitized)\n", stderr)
            guard initialized, SentrySDK.isEnabled else { return }
            if externalLogLineLooksLikeError(line) {
                SentrySDK.logger.error(sanitized)
                SentrySDK.capture(message: sanitized)
            } else {
                SentrySDK.logger.info(sanitized)
            }
        }
    }

    @objc(addTraceHeadersToRequest:)
    public static func addTraceHeaders(to request: NSMutableURLRequest) {
        addTraceHeaders(from: SentrySDK.span, to: request)
    }

    static func addTraceHeaders(from span: Span?, to request: NSMutableURLRequest) {
        guard initialized, SentrySDK.isEnabled, let span else { return }
        request.setValue(span.toTraceHeader().value(), forHTTPHeaderField: "sentry-trace")
        if let baggage = span.baggageHttpHeader(), !baggage.isEmpty {
            request.setValue(baggage, forHTTPHeaderField: "baggage")
        }
    }

    @objc(startTransactionWithName:operation:makeCurrent:)
    public static func startTransaction(name: String, operation: String, makeCurrent: Bool) -> OPNSentryTransaction? {
        let resolvedName = name.isEmpty ? "OpenNOW operation" : name
        let resolvedOperation = operation.isEmpty ? "task" : operation
        let span = initialized && SentrySDK.isEnabled ? SentrySDK.startTransaction(name: resolvedName, operation: resolvedOperation, bindToScope: makeCurrent) : nil
        return OPNSentryTransaction(name: resolvedName, operation: resolvedOperation, makeCurrent: makeCurrent, span: span)
    }

    @objc(traceHTTPRequest:name:)
    public static func traceHTTPRequest(_ request: NSMutableURLRequest, name: String) -> OPNSentryTransaction? {
        let transaction = startTransaction(name: httpTransactionName(for: request, fallbackName: name), operation: "http.client", makeCurrent: false)
        guard let transaction else { return nil }
        let requestMethod = request.httpMethod
        let method = (requestMethod.isEmpty ? "GET" : requestMethod).uppercased()
        transaction.setTag("http.method", value: method)
        if let host = request.url?.host, !host.isEmpty {
            transaction.setTag("server.address", value: host)
        }
        let sanitizedUrl = sanitizedURLForTrace(request.url)
        if !sanitizedUrl.isEmpty {
            transaction.setData("url.full", value: sanitizedUrl)
        }
        transaction.addTraceHeaders(request)
        return transaction
    }

    @objc(recordCounterMetricWithKey:value:attributes:)
    public static func recordCounterMetric(key: String, value: Int64, attributes: [String: Any]?) -> Bool {
        guard initialized, SentrySDK.isEnabled, value >= 0 else { return false }
        SentrySDK.metrics.count(key: key, value: UInt(value), attributes: sentryAttributes(from: attributes))
        return true
    }

    @objc(recordGaugeMetricWithKey:value:unit:attributes:)
    public static func recordGaugeMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        guard initialized, SentrySDK.isEnabled else { return false }
        SentrySDK.metrics.gauge(key: key, value: value, unit: sentryUnit(from: unit), attributes: sentryAttributes(from: attributes))
        return true
    }

    @objc(recordDistributionMetricWithKey:value:unit:attributes:)
    public static func recordDistributionMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        guard initialized, SentrySDK.isEnabled else { return false }
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

    private static func environmentDouble(_ name: String) -> Double? {
        guard let value = ProcessInfo.processInfo.environment[name] else { return nil }
        return Double(value)
    }

    private static func environmentString(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
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
            (#"\b(?:\+?\d[\d .()\-]{7,}\d)\b"#, "[redacted-phone]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[redacted-ip]"),
            (#"\b[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\b"#, "[redacted-id]"),
            (#"\b[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#, "[redacted-token]"),
            (#"(?i)(bearer|basic)\s+[^\s,;]+"#, "$1 [redacted-token]"),
            (#"(?i)((?:access|refresh|id)?_?token|authorization|password|secret|api[_-]?key|session[_-]?id)([=:]\s*|""\s*:\s*"")[^\s,;\}\""]+"#, "$1$2[redacted-secret]"),
            (#"/Users/[^/\s]+"#, "/Users/[redacted-user]")
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

    private static func httpTransactionName(for request: NSMutableURLRequest, fallbackName: String) -> String {
        let requestMethod = request.httpMethod
        let method = (requestMethod.isEmpty ? "GET" : requestMethod).uppercased()
        let host = request.url?.host?.isEmpty == false ? request.url?.host ?? "unknown-host" : "unknown-host"
        let path = request.url?.path.isEmpty == false ? request.url?.path ?? "/" : "/"
        let name = "HTTP \(method) \(host)\(path)"
        return name.isEmpty ? fallbackName : name
    }

    private static func sanitizedURLForTrace(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? url.host ?? ""
    }
}
