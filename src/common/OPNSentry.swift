import Foundation

@objcMembers
@objc(OPNSentryTransaction)
final class OPNSentryTransaction: NSObject {
    private let name: String
    private let operation: String
    private let makeCurrent: Bool
    private var finished = false
    private var tags: [String: String] = [:]
    private var data: [String: String] = [:]
    private var success: Bool?

    init(name: String, operation: String, makeCurrent: Bool) {
        self.name = name.isEmpty ? "OpenNOW operation" : name
        self.operation = operation.isEmpty ? "task" : operation
        self.makeCurrent = makeCurrent
        super.init()
    }

    deinit {
        finish()
    }

    func setTag(_ key: String, value: String) {
        guard !key.isEmpty else { return }
        tags[key] = value
    }

    func setData(_ key: String, value: String) {
        guard !key.isEmpty else { return }
        data[key] = value
    }

    func setStatus(_ success: Bool) {
        self.success = success
    }

    @objc(addTraceHeaders:)
    func addTraceHeaders(_ request: NSMutableURLRequest) {}

    func finish() {
        finished = true
    }
}

extension OPNSentryTransaction: @unchecked Sendable {}

@objcMembers
@objc(OPNSentry)
final class OPNSentry: NSObject {
    private nonisolated(unsafe) static var initialized = false

    static func initializeSentry() {
        initialized = true
    }

    static func closeSentry() {
        initialized = false
    }

    static func shouldLogInfo() -> Bool {
        !environmentFlagEnabled("OPN_DISABLE_INFO_LOGS")
    }

    static func logInfoMessage(_ message: String) {
        guard shouldLogInfo() else { return }
        fputs("\(sanitizedMessage(message))\n", stderr)
    }

    static func logErrorMessage(_ message: String) {
        fputs("\(sanitizedMessage(message))\n", stderr)
    }

    static func captureExternalLogLine(_ line: String) {
        guard !line.isEmpty else { return }
        if externalLogLineLooksLikeError(line) || shouldLogInfo() {
            fputs("\(sanitizedMessage(line))\n", stderr)
        }
    }

    @objc(addTraceHeadersToRequest:)
    static func addTraceHeaders(to request: NSMutableURLRequest) {}

    @objc(startTransactionWithName:operation:makeCurrent:)
    static func startTransaction(name: String, operation: String, makeCurrent: Bool) -> OPNSentryTransaction? {
        OPNSentryTransaction(name: name, operation: operation, makeCurrent: makeCurrent)
    }

    @objc(traceHTTPRequest:name:)
    static func traceHTTPRequest(_ request: NSMutableURLRequest, name: String) -> OPNSentryTransaction? {
        let transaction = OPNSentryTransaction(name: httpTransactionName(for: request, fallbackName: name), operation: "http.client", makeCurrent: false)
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
        return transaction
    }

    @objc(recordCounterMetricWithKey:value:attributes:)
    static func recordCounterMetric(key: String, value: Int64, attributes: [String: Any]?) -> Bool {
        false
    }

    @objc(recordGaugeMetricWithKey:value:unit:attributes:)
    static func recordGaugeMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        false
    }

    @objc(recordDistributionMetricWithKey:value:unit:attributes:)
    static func recordDistributionMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        false
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
