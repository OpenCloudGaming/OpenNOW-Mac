import Foundation

public enum OPNURLSessionHTTPTransport {
    public static func send(_ request: URLRequest, operation: String, invalidHTTPResponseError: any Error) async throws -> (Data, HTTPURLResponse) {
        var tracedRequest = request
        let networkStart = OPNNetworkLog.start(&tracedRequest, operation: operation)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: tracedRequest)
        } catch {
            OPNNetworkLog.finish(tracedRequest, operation: operation, startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            OPNNetworkLog.finish(tracedRequest, operation: operation, startedAt: networkStart, data: data, response: response, error: invalidHTTPResponseError)
            throw invalidHTTPResponseError
        }
        OPNNetworkLog.finish(tracedRequest, operation: operation, startedAt: networkStart, data: data, response: response, error: nil)
        return (data, httpResponse)
    }
}
