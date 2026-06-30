import Foundation

public struct OPNNetworkLogContext: Sendable {
    public let operation: String
    public let startedAt: Date
    public let requestSummary: String
    public let trace: OPNSentryTransaction?

    fileprivate init(operation: String, startedAt: Date, requestSummary: String, trace: OPNSentryTransaction?) {
        self.operation = operation
        self.startedAt = startedAt
        self.requestSummary = requestSummary
        self.trace = trace
    }

    fileprivate var durationMilliseconds: Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
}

public enum OPNNetworkLog {
    public static func start(_ request: inout URLRequest, operation: String) -> OPNNetworkLogContext {
        let trace = OPNSentry.traceHTTPRequest(&request, name: readableOperationName(operation))
        return startContext(request, operation: operation, trace: trace)
    }

    public static func start(_ request: URLRequest, operation: String) -> OPNNetworkLogContext {
        startContext(request, operation: operation, trace: nil)
    }

    public static func finish(_ request: URLRequest, operation: String, startedAt context: OPNNetworkLogContext, data: Data?, response: URLResponse?, error: Error?) {
        let durationMilliseconds = context.durationMilliseconds
        let byteCount = data?.count ?? 0
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let outcome = httpOutcome(statusCode: statusCode, error: error)
        recordHTTPMetrics(request: request, operation: operation, statusCode: statusCode, durationMilliseconds: durationMilliseconds, byteCount: byteCount, outcome: outcome, error: error)
        finishTrace(context.trace, operation: operation, statusCode: statusCode, durationMilliseconds: durationMilliseconds, byteCount: byteCount, outcome: outcome)

        if let error {
            let level = failureLogLevel(operation: operation, error: error)
            let message = logMessage(level: level, area: "Network", message: "HTTP request failed operation=\(operation) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) error=\(error.localizedDescription)")
            if level == "error" {
                OPNSentry.logErrorMessage(message)
            } else {
                OPNSentry.logWarningMessage(message)
            }
            return
        }

        let message = logMessage(level: outcome == "success" ? "info" : "warning", area: "Network", message: "HTTP request finished operation=\(operation) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount)")
        guard outcome != "success" || shouldLogSuccessfulFinish(operation: operation, durationMilliseconds: durationMilliseconds) else { return }
        if outcome == "success" {
            OPNSentry.logInfoMessage(message)
        } else {
            OPNSentry.logWarningMessage(message)
        }
    }

    public static func graphQLStart(_ request: inout URLRequest, operationName: String, queryHash: String, variables: NSDictionary?) -> OPNNetworkLogContext {
        let trace = OPNSentry.traceHTTPRequest(&request, name: "GraphQL \(operationName.isEmpty ? "operation" : operationName)")
        trace?.setTag("graphql.operation", value: operationName)
        trace?.setTag("graphql.query_hash", value: queryHash)
        return graphQLStartContext(request, operationName: operationName, queryHash: queryHash, variables: variables, trace: trace)
    }

    public static func graphQLStart(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?) -> OPNNetworkLogContext {
        graphQLStartContext(request, operationName: operationName, queryHash: queryHash, variables: variables, trace: nil)
    }

    public static func graphQLFinish(_ request: URLRequest, operationName: String, queryHash: String, startedAt context: OPNNetworkLogContext, data: Data?, response: URLResponse?, error: Error?, responseMessage: String) {
        let durationMilliseconds = context.durationMilliseconds
        let byteCount = data?.count ?? 0
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseDetail = graphQLErrorDetail(data: data)
        let hasGraphQLError = !responseMessage.isEmpty || !responseDetail.isEmpty
        let outcome = error == nil && !hasGraphQLError && ((200..<400).contains(statusCode) || statusCode == -1) ? "success" : (error == nil ? "graphql_error" : "network_error")
        recordHTTPMetrics(request: request, operation: "graphql.\(operationName)", statusCode: statusCode, durationMilliseconds: durationMilliseconds, byteCount: byteCount, outcome: outcome, error: error)
        finishTrace(context.trace, operation: "graphql.\(operationName)", statusCode: statusCode, durationMilliseconds: durationMilliseconds, byteCount: byteCount, outcome: outcome)

        if let error {
            let level = failureLogLevel(operation: "graphql.\(operationName)", error: error)
            let message = logMessage(level: level, area: "GraphQL", message: "Request failed operation=\(operationName) hash=\(queryHash) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) error=\(error.localizedDescription)")
            if level == "error" {
                OPNSentry.logErrorMessage(message)
            } else {
                OPNSentry.logWarningMessage(message)
            }
            return
        }

        let detailText = responseDetail.isEmpty ? "" : " detail=\(responseDetail)"
        let message = logMessage(level: outcome == "success" ? "info" : "warning", area: "GraphQL", message: "Request finished operation=\(operationName) hash=\(queryHash) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) message=\(responseMessage.isEmpty ? "ok" : responseMessage)\(detailText)")
        if outcome == "success" {
            OPNSentry.logInfoMessage(message)
        } else {
            OPNSentry.logWarningMessage(message)
        }
    }

    public static func webSocketEvent(_ event: String, url: URL?, detail: String = "") {
        guard shouldLogWebSocketEvent(event) else { return }
        let detailText = detail.isEmpty ? "" : " detail=\(sanitizedDetail(detail))"
        OPNSentry.logInfoMessage(logMessage(level: "info", area: "WebSocket", message: "Event \(event) url=\(sanitizedURL(url))\(detailText)"))
    }

    public static func webSocketError(_ event: String, url: URL?, error: Error?) {
        OPNSentry.logErrorMessage(logMessage(level: "error", area: "WebSocket", message: "Event \(event) failed url=\(sanitizedURL(url)) error=\(error?.localizedDescription ?? "unknown")"))
    }

    private static func startContext(_ request: URLRequest, operation: String, trace: OPNSentryTransaction?) -> OPNNetworkLogContext {
        let context = OPNNetworkLogContext(operation: operation, startedAt: Date(), requestSummary: requestSummary(request), trace: trace)
        trace?.setTag("opennow.operation", value: operation)
        if shouldLogStart(operation: operation) {
            OPNSentry.logInfoMessage(logMessage(level: "info", area: "Network", message: "HTTP request started operation=\(operation) request=\(context.requestSummary)"))
        }
        return context
    }

    private static func graphQLStartContext(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?, trace: OPNSentryTransaction?) -> OPNNetworkLogContext {
        let operation = "graphql.\(operationName.isEmpty ? "operation" : operationName)"
        let context = OPNNetworkLogContext(operation: operation, startedAt: Date(), requestSummary: requestSummary(request), trace: trace)
        if shouldLogGraphQLStart(operationName: operationName) {
            OPNSentry.logInfoMessage(logMessage(level: "info", area: "GraphQL", message: "Request started operation=\(operationName) hash=\(queryHash) variableKeys=\(sortedKeys(in: variables)) request=\(context.requestSummary)"))
        }
        return context
    }

    private static func finishTrace(_ trace: OPNSentryTransaction?, operation: String, statusCode: Int, durationMilliseconds: Int, byteCount: Int, outcome: String) {
        guard let trace else { return }
        trace.setTag("opennow.operation", value: operation)
        trace.setTag("opennow.outcome", value: outcome)
        if statusCode >= 0 {
            trace.setTag("http.status_code", value: String(statusCode))
        }
        trace.setData("duration_ms", value: String(durationMilliseconds))
        trace.setData("bytes", value: String(byteCount))
        trace.setStatus(outcome == "success")
        trace.finish()
    }

    private static func recordHTTPMetrics(request: URLRequest, operation: String, statusCode: Int, durationMilliseconds: Int, byteCount: Int, outcome: String, error: Error?) {
        var attributes: [String: Any] = [
            "operation": operation,
            "method": request.httpMethod?.isEmpty == false ? request.httpMethod ?? "GET" : "GET",
            "host": request.url?.host?.isEmpty == false ? request.url?.host ?? "unknown" : "unknown",
            "outcome": outcome,
            "status_bucket": statusBucket(statusCode)
        ]
        if statusCode >= 0 {
            attributes["status_code"] = statusCode
        }
        if let error = error as NSError?, !error.domain.isEmpty {
            attributes["error_domain"] = error.domain
            attributes["error_code"] = error.code
        }
        _ = OPNSentry.recordCounterMetric(key: "opennow.http.requests.count", value: 1, attributes: attributes)
        _ = OPNSentry.recordDistributionMetric(key: "opennow.http.duration_ms", value: Double(durationMilliseconds), unit: "millisecond", attributes: attributes)
        if byteCount > 0 {
            _ = OPNSentry.recordDistributionMetric(key: "opennow.http.response_bytes", value: Double(byteCount), unit: "byte", attributes: attributes)
        }
    }

    private static func requestSummary(_ request: URLRequest) -> String {
        let method = request.httpMethod?.isEmpty == false ? request.httpMethod ?? "GET" : "GET"
        return "\(method) \(sanitizedURL(request.url))"
    }

    private static func sanitizedURL(_ url: URL?) -> String {
        guard let url else { return "unknown-url" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "unknown-url" }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = sanitizedURLPath(components.path)
        return components.string ?? url.host ?? "unknown-url"
    }

    private static func sanitizedURLPath(_ path: String) -> String {
        path.replacingOccurrences(
            of: #"(?i)((?:/v\d+)?/session/)[^/]+"#,
            with: "$1redacted-id",
            options: [.regularExpression]
        )
    }

    private static func sortedKeys(in dictionary: NSDictionary?) -> String {
        guard let dictionary else { return "[]" }
        let keys = dictionary.allKeys.compactMap { $0 as? String }.sorted()
        return "[\(keys.joined(separator: ","))]"
    }

    private static func shouldLogStart(operation: String) -> Bool {
        !["stream.measureRegion", "catalog.image"].contains(operation)
    }

    private static func shouldLogSuccessfulFinish(operation: String, durationMilliseconds: Int) -> Bool {
        if operation == "stream.measureRegion" { return durationMilliseconds >= 1_000 }
        if operation == "catalog.image" { return false }
        return true
    }

    private static func failureLogLevel(operation: String, error: Error) -> String {
        if operation == "stream.measureRegion" { return "warning" }
        let urlErrorCode = (error as? URLError)?.code
        if urlErrorCode == .cancelled { return "warning" }
        if urlErrorCode == .timedOut { return "warning" }
        if urlErrorCode == .cannotFindHost { return "warning" }
        if urlErrorCode == .cannotConnectToHost { return "warning" }
        if urlErrorCode == .networkConnectionLost { return "warning" }
        if urlErrorCode == .notConnectedToInternet { return "warning" }
        return "error"
    }

    private static func shouldLogGraphQLStart(operationName: String) -> Bool {
        operationName != "appMetaData"
    }

    private static func shouldLogWebSocketEvent(_ event: String) -> Bool {
        if ["iceCandidateReceived", "receiveStopped"].contains(event) {
            return OPNSentry.shouldLogVerbose()
        }
        return true
    }

    private static func sanitizedDetail(_ detail: String) -> String {
        OPNSentry.sanitizedLogMessage(detail.replacingOccurrences(
            of: #"(?i)(x-nv-sessionid[.=])[^\s,;]+"#,
            with: "$1[redacted-secret]",
            options: [.regularExpression]
        ))
    }

    private static func graphQLErrorDetail(data: Data?) -> String {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = json["errors"] as? [[String: Any]],
              !errors.isEmpty,
              let errorData = try? JSONSerialization.data(withJSONObject: ["errors": errors]),
              let text = String(data: errorData, encoding: .utf8) else { return "" }
        let singleLine = text.replacingOccurrences(of: #"\s+"#, with: " ", options: [.regularExpression])
        return String(OPNSentry.sanitizedLogMessage(singleLine).prefix(500))
    }

    private static func httpOutcome(statusCode: Int, error: Error?) -> String {
        if error != nil { return "network_error" }
        if statusCode == -1 || (200..<400).contains(statusCode) { return "success" }
        return "http_error"
    }

    private static func statusBucket(_ statusCode: Int) -> String {
        statusCode < 100 ? "unknown" : "\(statusCode / 100)xx"
    }

    private static func statusText(_ statusCode: Int) -> String {
        statusCode >= 0 ? String(statusCode) : "unknown"
    }

    private static func readableOperationName(_ operation: String) -> String {
        operation.isEmpty ? "OpenNOW network request" : operation
    }

    private static func logMessage(level: String, area: String, message: String) -> String {
        OPNSentry.formattedLogMessage(level: level, area: area, message: message)
    }
}
