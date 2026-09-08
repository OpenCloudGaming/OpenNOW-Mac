//  Metrics, environment resolution and the scrubbing every event, breadcrumb and log line passes
//  through before it leaves the process.
//

import Foundation
@preconcurrency import Sentry

extension OPNSentry {
    public static func recordCounterMetric(key: String, value: Int64, attributes: [String: Any]?) -> Bool {
        guard isTelemetryEnabled(), initialized, SentrySDK.isEnabled, value >= 0 else { return false }
        SentrySDK.metrics.count(key: key, value: UInt(value), attributes: sentryAttributes(from: attributes))
        return true
    }

    public static func recordGaugeMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        guard isTelemetryEnabled(), initialized, SentrySDK.isEnabled else { return false }
        SentrySDK.metrics.gauge(key: key, value: value, unit: sentryUnit(from: unit), attributes: sentryAttributes(from: attributes))
        return true
    }

    public static func recordDistributionMetric(key: String, value: Double, unit: String?, attributes: [String: Any]?) -> Bool {
        guard isTelemetryEnabled(), initialized, SentrySDK.isEnabled else { return false }
        SentrySDK.metrics.distribution(key: key, value: value, unit: sentryUnit(from: unit), attributes: sentryAttributes(from: attributes))
        return true
    }

    static func sentryAttributes(from attributes: [String: Any]?) -> [String: SentryAttributeValue] {
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

    static func sentryUnit(from unit: String?) -> SentryUnit? {
        guard let unit, !unit.isEmpty else { return nil }
        return SentryUnit(rawValue: unit)
    }

    static func environmentFlagEnabled(_ name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name] else { return false }
        return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame
    }

    static func environmentFlagDisabled(_ name: String) -> Bool {
        guard let value = ProcessInfo.processInfo.environment[name] else { return false }
        return value == "0" || value.caseInsensitiveCompare("false") == .orderedSame || value.caseInsensitiveCompare("no") == .orderedSame
    }

    static func environmentDouble(_ name: String) -> Double? {
        guard let value = ProcessInfo.processInfo.environment[name] else { return nil }
        return Double(value)
    }

    static func environmentString(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func booleanValue(_ value: Any?, defaultValue: Bool) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        return defaultValue
    }

    static func clampedSampleRate(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    static func resolvedDsn() -> String? {
        guard !environmentFlagEnabled("OPN_DISABLE_SENTRY") else { return nil }
        return environmentString("OPN_SENTRY_DSN")
            ?? environmentString("SENTRY_DSN")
            ?? infoPlistString(dsnInfoPlistKey)
    }

    static func infoPlistString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func resolvedEnvironment() -> String {
        if let environment = environmentString("OPN_SENTRY_ENVIRONMENT") ?? environmentString("SENTRY_ENVIRONMENT") {
            return environment
        }
        #if DEBUG
        return "debug"
        #else
        return "production"
        #endif
    }

    static func resolvedReleaseName() -> String? {
        if let release = environmentString("OPN_SENTRY_RELEASE") ?? environmentString("SENTRY_RELEASE") {
            return release
        }
        guard let identifier = Bundle.main.bundleIdentifier, !identifier.isEmpty else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = (info["CFBundleShortVersionString"] as? String)?.isEmpty == false ? info["CFBundleShortVersionString"] as? String ?? "0" : "0"
        let build = (info["CFBundleVersion"] as? String)?.isEmpty == false ? info["CFBundleVersion"] as? String ?? "0" : "0"
        return "\(identifier)@\(version)+\(build)"
    }

    static func resolvedDist() -> String? {
        if let dist = environmentString("OPN_SENTRY_DIST") ?? environmentString("SENTRY_DIST") {
            return dist
        }
        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    static func sanitize(event: Event) -> Event? {
        if shouldDropAutoCapturedHTTPClientError(
            exceptionTypes: event.exceptions?.compactMap(\.type) ?? [],
            exceptionValues: event.exceptions?.compactMap(\.value) ?? [],
            requestURL: event.request?.url
        ) {
            return nil
        }
        if let message = event.message?.formatted, !message.isEmpty {
            event.message = SentryMessage(formatted: sanitizedMessage(message))
        }
        event.logger = event.logger.map(sanitizedMessage)
        event.serverName = nil
        event.transaction = event.transaction.map(sanitizedMessage)
        // The SDK's own HTTP instrumentation attaches the full request URL, which for the OIDC
        // logout carries `id_token_hint`. Nothing else scrubs this field.
        if let request = event.request {
            request.url = request.url.map(sanitizedMessage)
            request.queryString = request.queryString.map(sanitizedMessage)
            request.fragment = request.fragment.map(sanitizedMessage)
            request.cookies = nil
            request.headers = request.headers.map(sanitizedStringDictionary)
        }
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

    static func shouldDropAutoCapturedHTTPClientError(exceptionTypes: [String], exceptionValues: [String], requestURL: String?) -> Bool {
        guard exceptionTypes.contains("HTTPClientError") else { return false }
        guard exceptionValues.contains(where: { value in
            value.range(of: #"\b5\d\d\b"#, options: .regularExpression) != nil
        }) else { return false }
        guard let requestURL, let url = URL(string: requestURL), let host = url.host?.lowercased() else { return false }
        return host.contains("cloudmatchbeta.nvidiagrid.net") && url.path == "/v2/session"
    }

    static func sanitize(breadcrumb: Breadcrumb) -> Breadcrumb? {
        breadcrumb.message = breadcrumb.message.map(sanitizedMessage)
        breadcrumb.category = sanitizedMessage(breadcrumb.category)
        if let data = breadcrumb.data {
            breadcrumb.data = sanitizedDictionary(data)
        }
        return breadcrumb
    }

    static func sanitize(log: SentryLog) -> SentryLog? {
        log.body = sanitizedMessage(log.body)
        log.attributes = sanitizedLogAttributes(log.attributes)
        return log
    }

    static func sanitizedStringDictionary(_ dictionary: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            result[sanitizedMessage(key)] = sanitizedMessage(value)
        }
        return result
    }

    static func sanitizedDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            result[sanitizedMessage(key)] = sanitizedValue(value)
        }
        return result
    }

    static func sanitizedValue(_ value: Any) -> Any {
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

    static func sanitizedLogAttributes(_ attributes: [String: SentryAttribute]) -> [String: SentryAttribute] {
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

    /// Every log sink in the app funnels through here, and all of them are durable: stderr, the
    /// diagnostics file that `uploadDiagnostics` can post to a public paste service, and Sentry.
    /// So this has to strip credentials, not just addresses — a single leaked JWT or session key
    /// in an uploaded bundle is a full account or stream compromise.
    static func sanitizedMessage(_ message: String) -> String {
        var sanitized = message
        for rule in redactionRules {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = rule.expression.stringByReplacingMatches(in: sanitized, range: range, withTemplate: rule.template)
        }
        return sanitized
    }

    /// A message that has already been through `sanitizedMessage`. The type is the proof: the log
    /// sinks each used to re-sanitise what the caller had just sanitised, which on the stream
    /// transport's two-second counter dump meant fourteen regex passes over a couple of kilobytes
    /// every tick, for a second result identical to the first.
    struct SanitizedLogMessage {
        let value: String

        init(_ message: String) {
            value = sanitizedMessage(message)
        }

        init(alreadySanitized value: String) {
            self.value = value
        }
    }

    /// Compiled once. `replacingOccurrences(options: .regularExpression)` recompiles the pattern on
    /// every call, and these run on every log line the app writes.
    private nonisolated(unsafe) static let redactionRules: [(expression: NSRegularExpression, template: String)] = {
        let patterns: [(String, String)] = [
            // Credentials passed as query parameters — `id_token_hint` on the OIDC logout URL is the
            // one that actually reaches here, via OPNNetworkLog's request summary.
            (#"(?i)([?&](?:[a-z0-9_-]*token[a-z0-9_-]*|code|key|secret|password|pwd|assertion)=)[^&\s]+"#, "$1[redacted-secret]"),
            // Bare JWTs (header.payload.signature), whatever field they arrive in.
            (#"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]+"#, "[redacted-jwt]"),
            // Bearer/authorization values.
            (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 [redacted-secret]"),
            // `name=value` / `name: value` credential pairs, e.g. SDP key attributes and token logs.
            // The lookahead keeps this from re-wrapping a value an earlier rule already replaced.
            (#"(?i)\b([a-z0-9_.\[\]-]*(?:token|secret|password|pwd|apikey|encryptionkey)[a-z0-9_.\[\]-]*)\s*[:=]\s*(?!\[redacted)[^\s,;)\]}"']+"#, "$1=[redacted-secret]"),
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[redacted-ip]"),
            (#"(?i)\b(?:(?:[0-9a-f]{1,4}:){7}[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,7}:|(?:[0-9a-f]{1,4}:){1,6}:[0-9a-f]{1,4}|(?:[0-9a-f]{1,4}:){1,5}(?::[0-9a-f]{1,4}){1,2}|(?:[0-9a-f]{1,4}:){1,4}(?::[0-9a-f]{1,4}){1,3}|(?:[0-9a-f]{1,4}:){1,3}(?::[0-9a-f]{1,4}){1,4}|(?:[0-9a-f]{1,4}:){1,2}(?::[0-9a-f]{1,4}){1,5}|[0-9a-f]{1,4}:(?:(?::[0-9a-f]{1,4}){1,6})|:(?:(?::[0-9a-f]{1,4}){1,7}|:))\b"#, "[redacted-ip]")
        ]
        // `.caseInsensitive` is applied to every rule, matching what the previous
        // `replacingOccurrences` call passed. Redaction is the one place to keep the wider match:
        // dropping it here would narrow what gets stripped, which is a leak, not a cleanup.
        return patterns.compactMap { pattern, template in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (expression, template)
        }
    }()

    static func appendDiagnosticsLogLine(_ line: String) {
        guard !line.isEmpty else { return }
        diagnosticsLogQueue.async {
            let timestamp = diagnosticsTimestampFormatter.string(from: Date())
            guard let data = "\(timestamp) \(line)\n".data(using: .utf8) else { return }
            reopenDiagnosticsLogIfFileWentAway()
            guard let handle = diagnosticsLogHandle() else { return }
            try? handle.write(contentsOf: data)
            diagnosticsLogBytesWritten += data.count
            trimDiagnosticsLogIfNeeded(url: diagnosticsLogURL(), writtenBytes: diagnosticsLogBytesWritten)
        }
    }

    /// The open write handle, positioned at the end. Reopening per line cost a `FileHandle`, a
    /// `seekToEnd` and a close for every one of the stream transport's counter lines; the file is
    /// append-only for the life of the process, so the handle is too.
    /// Only ever touched on `diagnosticsLogQueue`.
    private static func diagnosticsLogHandle() -> FileHandle? {
        if let openDiagnosticsLogHandle { return openDiagnosticsLogHandle }
        let url = diagnosticsLogURL()
        let manager = FileManager.default
        try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        let end = (try? handle.seekToEnd()) ?? 0
        diagnosticsLogBytesWritten = Int(clamping: end)
        openDiagnosticsLogHandle = handle
        return handle
    }

    /// Closes the handle so the next append reopens the file — for the paths that replace the file
    /// underneath us (a new run's clear, or a trim's atomic rewrite), where the old descriptor
    /// points at an unlinked inode and every further write would vanish.
    static func closeDiagnosticsLogHandle() {
        try? openDiagnosticsLogHandle?.close()
        openDiagnosticsLogHandle = nil
        diagnosticsLogBytesWritten = 0
    }

    /// Writes through an open descriptor keep succeeding after the file is deleted or replaced —
    /// they land in an unlinked inode nothing can read. Reopening per line is what made this path
    /// expensive, so the existence check is amortised instead: often enough that a user who clears
    /// the log gets a live file back within a second of streaming, rarely enough to stay off the
    /// per-line cost.
    private static func reopenDiagnosticsLogIfFileWentAway() {
        guard openDiagnosticsLogHandle != nil else { return }
        appendsSinceExistenceCheck += 1
        guard appendsSinceExistenceCheck >= appendsBetweenExistenceChecks else { return }
        appendsSinceExistenceCheck = 0
        guard !FileManager.default.fileExists(atPath: diagnosticsLogURL().path) else { return }
        closeDiagnosticsLogHandle()
    }

    private static let appendsBetweenExistenceChecks = 64
    private nonisolated(unsafe) static var appendsSinceExistenceCheck = 0
    private nonisolated(unsafe) static var openDiagnosticsLogHandle: FileHandle?
    /// The size the open handle has written, so the common case costs no `stat` at all.
    private nonisolated(unsafe) static var diagnosticsLogBytesWritten = 0

    /// Only ever touched on `diagnosticsLogQueue`.
    private nonisolated(unsafe) static let diagnosticsTimestampFormatter = ISO8601DateFormatter()

    static func diagnosticsLogText() -> String {
        let url = diagnosticsLogURL()
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    static func diagnosticsLogURL() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("OpenNOW", isDirectory: true).appendingPathComponent("OpenNOW-diagnostics-current.log")
    }

    static func clearDiagnosticsLog(at url: URL, fileManager manager: FileManager = .default) {
        let directory = url.deletingLastPathComponent()
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: url, options: .atomic)
    }

    /// Trims to `trimmedDiagnosticsLogBytes`, not back to the ceiling.
    ///
    /// Trimming to the ceiling left the file exactly at it, so the very next line was over again
    /// and every subsequent write read and rewrote the whole 8 MB — on a stream that logs counters
    /// every two seconds, that is a permanent read-modify-write of megabytes per line, reached
    /// after about an hour. Cutting back to three quarters buys ~2 MB of headroom per trim.
    static func trimDiagnosticsLogIfNeeded(url: URL, writtenBytes: Int) {
        guard writtenBytes > maxDiagnosticsLogBytes else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let kept = Data(data.suffix(trimmedDiagnosticsLogBytes))
        guard (try? kept.write(to: url, options: .atomic)) != nil else { return }
        // The atomic write replaced the file, so the handle now points at an unlinked inode.
        closeDiagnosticsLogHandle()
    }

    static func diagnosticsUploadData(_ text: String) throws -> Data {
        let sanitized = sanitizedUploadLog(text)
        guard let sanitizedData = sanitized.data(using: .utf8), !sanitizedData.isEmpty else { throw OPNSentryDiagnosticsUploadError.emptyLog }
        guard sanitizedData.count > maxDiagnosticsUploadBytes else { return sanitizedData }
        let notice = "OpenNOW diagnostics upload\nNotice: upload is limited to the most recent \(maxDiagnosticsUploadBytes / 1024) KiB because the diagnostics paste service rejects larger payloads.\n\n"
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

    static func diagnosticsPasteURL(from data: Data) throws -> URL {
        guard let responseText = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pasteURL = URL(string: responseText),
              pasteURL.scheme == "https",
              pasteURL.host == "paste.c-net.org" else { throw OPNSentryDiagnosticsUploadError.invalidResponse }
        return pasteURL
    }

    static func sanitizedUploadLog(_ text: String) -> String {
        var sanitized = sanitizedMessage(text)
        for rule in uploadRedactionRules {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = rule.expression.stringByReplacingMatches(in: sanitized, range: range, withTemplate: rule.template)
        }
        return sanitized
    }

    /// Compiled once, like `redactionRules`. These run over the entire diagnostics log — megabytes
    /// — so recompiling each pattern per upload was the expensive half of preparing one.
    private nonisolated(unsafe) static let uploadRedactionRules: [(expression: NSRegularExpression, template: String)] = {
        let patterns: [(String, String)] = [
            (#"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, "[redacted-ip]"),
            (#"\b[0-9A-F]{1,4}(?::[0-9A-F]{1,4}){2,7}\b"#, "[redacted-ip]"),
            (#"(?i)\b(latitude|longitude|lat|lon|lng)([=:]\s*|""\s*:\s*"")-?\d{1,3}(?:\.\d+)?"#, "$1$2[redacted-location]"),
            (#"(?i)\b(city|country|state|province|postal[_-]?code|zip|timezone|location|region|server[_-]?location)([=:]\s*|""\s*:\s*"")[^\s,;\}\]"]+"#, "$1$2[redacted-location]"),
            (#"(?i)\b[a-z]+-[a-z]+\.cloudmatch[^\s,;\}\]"]*"#, "[redacted-location-host]")
        ]
        return patterns.compactMap { pattern, template in
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return (expression, template)
        }
    }()

    static func externalLogLineLooksLikeError(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.contains("error") || lower.contains("exception") || lower.contains("failed") || lower.contains("failure") || lower.contains("crash") || lower.contains("fatal")
    }

    static func startHTTPTransaction(url: URL?, method: String?, fallbackName: String) -> OPNSentryTransaction? {
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

    static func httpTransactionName(url: URL?, method: String?, fallbackName: String) -> String {
        let resolvedMethod = (method?.isEmpty == false ? method ?? "GET" : "GET").uppercased()
        let host = url?.host?.isEmpty == false ? url?.host ?? "unknown-host" : "unknown-host"
        let path = url?.path.isEmpty == false ? sanitizedURLPath(url?.path ?? "/") : "/"
        let name = "HTTP \(resolvedMethod) \(host)\(path)"
        return name.isEmpty ? fallbackName : name
    }

    static func sanitizedURLForTrace(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = sanitizedURLPath(components.path)
        return components.string ?? url.host ?? ""
    }

    static func sanitizedURLPath(_ path: String) -> String {
        path.replacingOccurrences(
            of: #"(?i)((?:/v\d+)?/session/)[^/]+"#,
            with: "$1redacted-id",
            options: [.regularExpression]
        )
    }
}
