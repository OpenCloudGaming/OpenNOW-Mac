import Foundation

public struct OPNNetworkLogContext: Sendable {
    public let operation: String
    public let startedAt: Date
    public let requestSummary: String

    fileprivate init(operation: String, startedAt: Date, requestSummary: String) {
        self.operation = operation
        self.startedAt = startedAt
        self.requestSummary = requestSummary
    }

    fileprivate var durationMilliseconds: Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
    }
}

public enum OPNNetworkLog {
    public static func start(_ request: URLRequest, operation: String) -> OPNNetworkLogContext {
        startContext(request, operation: operation)
    }

    /// `request` is gone from this signature: the Sentry metrics and trace it fed are removed
    /// (NEC-47), and `context.requestSummary` already carries the sanitized request line.
    public static func finish(operation: String, startedAt context: OPNNetworkLogContext, data: Data?, response: URLResponse?, error: Error?) {
        let durationMilliseconds = context.durationMilliseconds
        let byteCount = data?.count ?? 0
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let outcome = httpOutcome(statusCode: statusCode, error: error)

        if let error {
            let level = failureLogLevel(operation: operation, error: error)
            let message = logMessage(level: level, area: "Network", message: "HTTP request failed operation=\(operation) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) error=\(error.localizedDescription)")
            if level == "error" {
                OPNDiagnostics.logErrorMessage(message)
            } else {
                OPNDiagnostics.logWarningMessage(message)
            }
            return
        }

        let message = logMessage(level: outcome == "success" ? "info" : "warning", area: "Network", message: "HTTP request finished operation=\(operation) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount)")
        guard outcome != "success" || shouldLogSuccessfulFinish(operation: operation, durationMilliseconds: durationMilliseconds) else { return }
        if outcome == "success" {
            OPNDiagnostics.logInfoMessage(message)
        } else {
            OPNDiagnostics.logWarningMessage(message)
        }
    }

    public static func graphQLStart(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?) -> OPNNetworkLogContext {
        graphQLStartContext(request, operationName: operationName, queryHash: queryHash, variables: variables)
    }

    public static func graphQLFinish(operationName: String, queryHash: String, startedAt context: OPNNetworkLogContext, data: Data?, response: URLResponse?, error: Error?, responseMessage: String) {
        let durationMilliseconds = context.durationMilliseconds
        let byteCount = data?.count ?? 0
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseDetail = graphQLErrorDetail(data: data)
        let hasGraphQLError = !responseMessage.isEmpty || !responseDetail.isEmpty
        let outcome = error == nil && !hasGraphQLError && ((200..<400).contains(statusCode) || statusCode == -1) ? "success" : (error == nil ? "graphql_error" : "network_error")

        if let error {
            let level = failureLogLevel(operation: "graphql.\(operationName)", error: error)
            let message = logMessage(level: level, area: "GraphQL", message: "Request failed operation=\(operationName) hash=\(queryHash) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) error=\(error.localizedDescription)")
            if level == "error" {
                OPNDiagnostics.logErrorMessage(message)
            } else {
                OPNDiagnostics.logWarningMessage(message)
            }
            return
        }

        let detailText = responseDetail.isEmpty ? "" : " detail=\(responseDetail)"
        let message = logMessage(level: outcome == "success" ? "info" : "warning", area: "GraphQL", message: "Request finished operation=\(operationName) hash=\(queryHash) request=\(context.requestSummary) status=\(statusText(statusCode)) duration=\(durationMilliseconds)ms bytes=\(byteCount) message=\(responseMessage.isEmpty ? "ok" : responseMessage)\(detailText)")
        if outcome == "success" {
            OPNDiagnostics.logInfoMessage(message)
        } else {
            OPNDiagnostics.logWarningMessage(message)
        }
    }

    public static func webSocketEvent(_ event: String, url: URL?, detail: String = "") {
        guard shouldLogWebSocketEvent(event) else { return }
        let detailText = detail.isEmpty ? "" : " detail=\(sanitizedDetail(detail))"
        OPNDiagnostics.logInfoMessage(logMessage(level: "info", area: "WebSocket", message: "Event \(event) url=\(sanitizedURL(url))\(detailText)"))
    }

    public static func webSocketError(_ event: String, url: URL?, error: Error?) {
        let level = failureLogLevel(operation: "websocket.\(event)", error: error)
        let message = logMessage(level: level, area: "WebSocket", message: "Event \(event) failed url=\(sanitizedURL(url)) error=\(error?.localizedDescription ?? "unknown")")
        if level == "error" {
            OPNDiagnostics.logErrorMessage(message)
        } else {
            OPNDiagnostics.logWarningMessage(message)
        }
    }

    private static func startContext(_ request: URLRequest, operation: String) -> OPNNetworkLogContext {
        let context = OPNNetworkLogContext(operation: operation, startedAt: Date(), requestSummary: requestSummary(request))
        if shouldLogStart(operation: operation) {
            OPNDiagnostics.logInfoMessage(logMessage(level: "info", area: "Network", message: "HTTP request started operation=\(operation) request=\(context.requestSummary)"))
        }
        return context
    }

    private static func graphQLStartContext(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?) -> OPNNetworkLogContext {
        let operation = "graphql.\(operationName.isEmpty ? "operation" : operationName)"
        let context = OPNNetworkLogContext(operation: operation, startedAt: Date(), requestSummary: requestSummary(request))
        if shouldLogGraphQLStart(operationName: operationName) {
            OPNDiagnostics.logInfoMessage(logMessage(level: "info", area: "GraphQL", message: "Request started operation=\(operationName) hash=\(queryHash) variableKeys=\(sortedKeys(in: variables)) request=\(context.requestSummary)"))
        }
        return context
    }

    private static func requestSummary(_ request: URLRequest) -> String {
        let method = request.httpMethod?.isEmpty == false ? request.httpMethod ?? "GET" : "GET"
        return "\(method) \(sanitizedURL(request.url))"
    }

    static func sanitizedURL(_ url: URL?) -> String {
        guard let url else { return "unknown-url" }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "unknown-url" }
        return OPNDiagnostics.sanitizedLogMessage(components.string ?? url.host ?? "unknown-url")
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

    /// URL errors that describe the network rather than the request: they are expected in the
    /// field, so they log as warnings instead of errors.
    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .cancelled,
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .networkConnectionLost,
        .notConnectedToInternet,
        .serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot,
        .serverCertificateNotYetValid,
        .secureConnectionFailed,
        .badURL
    ]

    private static func failureLogLevel(operation: String, error: Error?) -> String {
        if operation == "stream.measureRegion" { return "warning" }
        guard let error else { return "warning" }
        // An error that is not a `URLError` at all is still an error: it is a protocol or transport
        // failure of ours, not the network being the network.
        guard let urlErrorCode = (error as? URLError)?.code else { return "error" }
        return transientURLErrorCodes.contains(urlErrorCode) ? "warning" : "error"
    }

    private static func shouldLogGraphQLStart(operationName: String) -> Bool {
        operationName != "appMetaData"
    }

    private static func shouldLogWebSocketEvent(_ event: String) -> Bool {
        if ["iceCandidateReceived", "receiveStopped"].contains(event) {
            return OPNDiagnostics.shouldLogVerbose()
        }
        return true
    }

    private static func sanitizedDetail(_ detail: String) -> String {
        OPNDiagnostics.sanitizedLogMessage(detail.replacingOccurrences(
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
        return String(OPNDiagnostics.sanitizedLogMessage(singleLine).prefix(500))
    }

    private static func httpOutcome(statusCode: Int, error: Error?) -> String {
        if error != nil { return "network_error" }
        if statusCode == -1 || (200..<400).contains(statusCode) { return "success" }
        return "http_error"
    }

    private static func statusText(_ statusCode: Int) -> String {
        statusCode >= 0 ? String(statusCode) : "unknown"
    }

    private static func logMessage(level: String, area: String, message: String) -> String {
        OPNDiagnostics.formattedLogMessage(level: level, area: area, message: message)
    }
}
