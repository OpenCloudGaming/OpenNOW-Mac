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

    /// Validates a response and reports the reason through `errorMessage`. The outcome used to be a
    /// Sentry metric too; with the SDK gone (NEC-47) the returned message is the whole report.
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
            return false
        }
        guard let http = response as? HTTPURLResponse else {
            setErrorMessage(errorMessage, "Missing HTTP response")
            return false
        }
        guard http.statusCode == expectedStatus else {
            setErrorMessage(errorMessage, "HTTP \(http.statusCode)")
            return false
        }
        guard data != nil else {
            setErrorMessage(errorMessage, "Empty response body")
            return false
        }
        return true
    }

    private static func setErrorMessage(_ errorMessage: AutoreleasingUnsafeMutablePointer<NSString?>?, _ message: String) {
        errorMessage?.pointee = message as NSString
    }
}
