import Foundation

public enum NetworkTest: Sendable {
    public static let systemName = "NetworkTest"
    public static let routePath = "/v2/nettestsession"
}

public extension NetworkTest {
    enum EventName: String, CaseIterable, Sendable {
        case analytics = "NetworkTestAnalytics"
        case completed = "NetworkTestCompleted"
        case httpEvent = "NetworkTest_Http_Event"
        case exception = "NetworkTest_Exception_Event"
    }
}

public struct NetworkTestConfiguration: Equatable, Sendable {
    public let baseURLString: String
    public let userAgent: String

    public init(baseURLString: String = "https://prod.cloudmatchbeta.nvidiagrid.net", userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.baseURLString = baseURLString
        self.userAgent = userAgent
    }

    public static let gfnPC = NetworkTestConfiguration()
}

public enum NetworkTestRequestFactory {
    public static func sessionRequest(accessToken: String = "", queryItems: [URLQueryItem] = [], configuration: NetworkTestConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: configuration.baseURLString + NetworkTest.routePath)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
