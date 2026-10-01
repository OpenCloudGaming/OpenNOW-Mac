import Foundation

public enum OPNURLSessionHTTPTransport {
    public static func send(_ request: URLRequest, operation: String, invalidHTTPResponseError: any Error, allowsSessionProxy: Bool = true) async throws -> (Data, HTTPURLResponse) {
        let networkStart = OPNNetworkLog.start(request, operation: operation)
        let data: Data
        let response: URLResponse
        do {
            if allowsSessionProxy {
                (data, response) = try await OPNSessionProxySessionProvider.shared.data(for: request)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
        } catch {
            OPNNetworkLog.finish(operation: operation, startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            OPNNetworkLog.finish(operation: operation, startedAt: networkStart, data: data, response: response, error: invalidHTTPResponseError)
            throw invalidHTTPResponseError
        }
        OPNNetworkLog.finish(operation: operation, startedAt: networkStart, data: data, response: response, error: nil)
        return (data, httpResponse)
    }
}
