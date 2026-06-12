import Foundation

public enum UDS: Sendable {
    public static let systemName = "UDS"
}

public extension UDS {
    enum UseCase: String, CaseIterable, Sendable {
        case uds = "UDS"
        case endOfSessionReport = "UdsEndOfSessionReport"
        case summonedReport = "UdsSummonedReport"
        case toastShown = "UDSToastShown"
        case suggestionFeedback = "UDSSuggestionFeedback"
        case dialogShown = "UDSDialogShown"
    }
}

public struct UDSConfiguration: Equatable, Sendable {
    public let serverURLString: String
    public let userAgent: String

    public init(serverURLString: String, userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.serverURLString = serverURLString
        self.userAgent = userAgent
    }
}

public enum UDSRequestFactory {
    public static func request(path: String, method: String = "GET", accessToken: String = "", queryItems: [URLQueryItem] = [], body: [String: Any]? = nil, configuration: UDSConfiguration, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: configuration.serverURLString + path)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = method
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}
