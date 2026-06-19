import Foundation

public enum OPNNetworkLog {
    public static func start(_ request: URLRequest, operation: String) -> Date {
        let startedAt = Date()
        OPNSentry.logInfoMessage("[OpenNOW][network][start] operation=\(operation) request=\(requestSummary(request))")
        return startedAt
    }

    public static func finish(_ request: URLRequest, operation: String, startedAt: Date, data: Data?, response: URLResponse?, error: Error?) {
        let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let byteCount = data?.count ?? 0
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
            OPNSentry.logErrorMessage("[OpenNOW][network][error] operation=\(operation) request=\(requestSummary(request)) status=\(statusCode) durationMs=\(durationMilliseconds) bytes=\(byteCount) error=\(error.localizedDescription)")
            return
        }
        let message = "[OpenNOW][network][finish] operation=\(operation) request=\(requestSummary(request)) status=\(statusCode) durationMs=\(durationMilliseconds) bytes=\(byteCount)"
        if (200..<400).contains(statusCode) || statusCode == -1 {
            OPNSentry.logInfoMessage(message)
        } else {
            OPNSentry.logWarningMessage(message)
        }
    }

    public static func graphQLStart(_ request: URLRequest, operationName: String, queryHash: String, variables: NSDictionary?) -> Date {
        let variableKeys = sortedKeys(in: variables)
        let startedAt = Date()
        OPNSentry.logInfoMessage("[OpenNOW][graphql][start] operation=\(operationName) hash=\(queryHash) variableKeys=\(variableKeys) request=\(requestSummary(request))")
        return startedAt
    }

    public static func graphQLFinish(_ request: URLRequest, operationName: String, queryHash: String, startedAt: Date, data: Data?, response: URLResponse?, error: Error?, responseMessage: String) {
        let durationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let byteCount = data?.count ?? 0
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let error {
            OPNSentry.logErrorMessage("[OpenNOW][graphql][error] operation=\(operationName) hash=\(queryHash) status=\(statusCode) durationMs=\(durationMilliseconds) bytes=\(byteCount) error=\(error.localizedDescription) request=\(requestSummary(request))")
            return
        }
        let message = "[OpenNOW][graphql][finish] operation=\(operationName) hash=\(queryHash) status=\(statusCode) durationMs=\(durationMilliseconds) bytes=\(byteCount) message=\(responseMessage.isEmpty ? "ok" : responseMessage) request=\(requestSummary(request))"
        if responseMessage.isEmpty && ((200..<400).contains(statusCode) || statusCode == -1) {
            OPNSentry.logInfoMessage(message)
        } else {
            OPNSentry.logWarningMessage(message)
        }
    }

    public static func webSocketEvent(_ event: String, url: URL?, detail: String = "") {
        let detailText = detail.isEmpty ? "" : " detail=\(detail)"
        OPNSentry.logInfoMessage("[OpenNOW][websocket][\(event)] url=\(sanitizedURL(url))\(detailText)")
    }

    public static func webSocketError(_ event: String, url: URL?, error: Error?) {
        OPNSentry.logErrorMessage("[OpenNOW][websocket][\(event)] url=\(sanitizedURL(url)) error=\(error?.localizedDescription ?? "unknown")")
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
        return components.string ?? url.host ?? "unknown-url"
    }

    private static func sortedKeys(in dictionary: NSDictionary?) -> String {
        guard let dictionary else { return "[]" }
        let keys = dictionary.allKeys.compactMap { $0 as? String }.sorted()
        return "[\(keys.joined(separator: ","))]"
    }
}
