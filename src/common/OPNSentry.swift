import Foundation
import Foundation
@preconcurrency import Sentry

@objcMembers
@objc(OPNSentryTransaction)
final class OPNSentryTransaction: NSObject {
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

    func setTag(_ key: String, value: String) {
        guard !key.isEmpty else { return }
        span?.setTag(value: value, key: key)
    }

    func setData(_ key: String, value: String) {
        guard !key.isEmpty else { return }
        span?.setData(value: value, key: key)
    }

    func setStatus(_ success: Bool) {
        self.success = success
    }

    @objc(addTraceHeaders:)
    func addTraceHeaders(_ request: NSMutableURLRequest) {
        OPNSentry.addTraceHeaders(from: span, to: request)
    }

    func finish() {
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
final class OPNSentry: NSObject {
    private static let dsn = "https://9db09e478cd379b8abdb101361ae5248@o4509317113184256.ingest.us.sentry.io/4511552111247360"
    private nonisolated(unsafe) static var initialized = false

    static func initializeSentry() {
        guard !initialized else { return }
        SentrySDK.start { options in
            options.dsn = dsn
            options.debug = true
            options.sendDefaultPii = true
            options.tracesSampleRate = 1.0
            options.enableMetrics = true
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

    static func logInfoMessage(_ message: String) {
        guard shouldLogInfo() else { return }
        let sanitized = sanitizedMessage(message)
        fputs("\(sanitized)\n", stderr)
        guard initialized, SentrySDK.isEnabled else { return }
        SentrySDK.logger.info(sanitized)
    }

    static func logErrorMessage(_ message: String) {
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
    static func addTraceHeaders(to request: NSMutableURLRequest) {
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
    static func startTransaction(name: String, operation: String, makeCurrent: Bool) -> OPNSentryTransaction? {
        let resolvedName = name.isEmpty ? "OpenNOW operation" : name
        let resolvedOperation = operation.isEmpty ? "task" : operation
        let span = initialized && SentrySDK.isEnabled ? SentrySDK.startTransaction(name: resolvedName, operation: resolvedOperation, bindToScope: makeCurrent) : nil
        return OPNSentryTransaction(name: resolvedName, operation: resolvedOperation, makeCurrent: makeCurrent, span: span)
    }

    @objc(traceHTTPRequest:name:)
    static func traceHTTPRequest(_ request: NSMutableURLRequest, name: String) -> OPNSentryTransaction? {
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
    static func recordCounterMetric(key: String, value: Int64, attributes: [String: Any]?) -> Bool {
        guard initialized, SentrySDK.isEnabled, value >= 0 else { return false }
        SentrySDK.metrics.count(key: key, value: UInt(value), attributes: sentryAttributes(from: attributes))
        return true
    }

    @objc(recordGaugeMetricWithKey:value:unit:attributes:)
    static func recordGaugeMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        guard initialized, SentrySDK.isEnabled else { return false }
        SentrySDK.metrics.gauge(key: key, value: value, unit: sentryUnit(from: unit), attributes: sentryAttributes(from: attributes))
        return true
    }

    @objc(recordDistributionMetricWithKey:value:unit:attributes:)
    static func recordDistributionMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
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
        return value == "1"
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
