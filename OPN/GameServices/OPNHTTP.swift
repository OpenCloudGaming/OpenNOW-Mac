import Foundation

@objc(OPNHTTP)
final class OPNHTTP: NSObject {
    @objc(makeRequestWithURLString:method:timeout:headers:)
    static func makeRequest(
        urlString: String?,
        method: String?,
        timeout: TimeInterval,
        headers: [String: String]?
    ) -> NSMutableURLRequest? {
        guard let text = urlString, let url = URL(string: text) else { return nil }
        let request = NSMutableURLRequest(url: url)
        request.httpMethod = method.flatMap { $0.isEmpty ? nil : $0 } ?? "GET"
        request.timeoutInterval = timeout
        for (key, value) in headers ?? [:] where !key.isEmpty && !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }
        OPNSentry.addTraceHeaders(to: request)
        return request
    }

    @objc(jsonDataFromObject:errorMessage:)
    static func jsonData(from object: Any?, errorMessage: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Data? {
        guard let object else {
            setErrorMessage(errorMessage, "Missing JSON object")
            return nil
        }
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            setErrorMessage(errorMessage, "Invalid JSON object: \(error.localizedDescription)")
            return nil
        }
    }

    @objc(jsonObjectFromData:errorMessage:)
    static func jsonObject(from data: Data?, errorMessage: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Any? {
        guard let data, !data.isEmpty else {
            setErrorMessage(errorMessage, "Empty response body")
            return nil
        }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            setErrorMessage(errorMessage, "Invalid JSON: \(error.localizedDescription)")
            return nil
        }
    }

    @objc(validateResponse:data:error:expectedStatus:errorMessage:)
    static func validate(
        response: URLResponse?,
        data: Data?,
        error: NSError?,
        expectedStatus: Int,
        errorMessage: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) -> Bool {
        if let error {
            setErrorMessage(errorMessage, error.localizedDescription.isEmpty ? "Network error" : error.localizedDescription)
            recordHTTPMetric(response: response, error: error, expectedStatus: expectedStatus, outcome: "network_error")
            return false
        }
        guard let http = response as? HTTPURLResponse else {
            setErrorMessage(errorMessage, "Missing HTTP response")
            recordHTTPMetric(response: response, error: nil, expectedStatus: expectedStatus, outcome: "missing_response")
            return false
        }
        guard http.statusCode == expectedStatus else {
            setErrorMessage(errorMessage, "HTTP \(http.statusCode)")
            recordHTTPMetric(response: response, error: nil, expectedStatus: expectedStatus, outcome: "http_error")
            return false
        }
        guard data != nil else {
            setErrorMessage(errorMessage, "Empty response body")
            recordHTTPMetric(response: response, error: nil, expectedStatus: expectedStatus, outcome: "empty_body")
            return false
        }
        recordHTTPMetric(response: response, error: nil, expectedStatus: expectedStatus, outcome: "success")
        return true
    }

    private static func setErrorMessage(_ errorMessage: AutoreleasingUnsafeMutablePointer<NSString?>?, _ message: String) {
        errorMessage?.pointee = message as NSString
    }

    private static func httpStatusBucket(_ statusCode: Int) -> String {
        statusCode < 100 ? "unknown" : "\(statusCode / 100)xx"
    }

    private static func httpMetricAttributes(response: URLResponse?, error: NSError?, expectedStatus: Int, outcome: String) -> [String: Any] {
        let http = response as? HTTPURLResponse
        var attributes: [String: Any] = [
            "outcome": outcome.isEmpty ? "unknown" : outcome,
            "method": "unknown",
            "host": http?.url?.host?.isEmpty == false ? http?.url?.host ?? "unknown" : "unknown",
            "expected_status": expectedStatus
        ]
        if let http {
            attributes["status_code"] = http.statusCode
            attributes["status_bucket"] = httpStatusBucket(http.statusCode)
        }
        if let error, !error.domain.isEmpty {
            attributes["error_domain"] = error.domain
            attributes["error_code"] = error.code
        }
        return attributes
    }

    private static func recordHTTPMetric(response: URLResponse?, error: NSError?, expectedStatus: Int, outcome: String) {
        let attributes = httpMetricAttributes(response: response, error: error, expectedStatus: expectedStatus, outcome: outcome) as NSDictionary
        _ = OPNSentry.recordCounterMetric(key: "opennow.http.requests.count", value: 1, attributes: attributes as? [String: Any])
    }
}
