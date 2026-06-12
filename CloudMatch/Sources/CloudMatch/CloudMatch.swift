import Foundation

public enum CloudMatch: Sendable {
    public static let systemName = "CloudMatch"
    public static let productionBaseURLString = "https://prod.cloudmatchbeta.nvidiagrid.net"
}

public extension CloudMatch {
    enum Endpoint: String, CaseIterable, Sendable {
        case serviceUrls = "/v1/serviceUrls"
        case serverInfo = "/v2/serverInfo"
        case networkTestSession = "/v2/nettestsession"

        public var path: String { rawValue }
    }
}

public struct CloudMatchConfiguration: Equatable, Sendable {
    public let baseURLString: String
    public let userAgent: String

    public init(baseURLString: String = CloudMatch.productionBaseURLString, userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.baseURLString = baseURLString
        self.userAgent = userAgent
    }

    public static let gfnPC = CloudMatchConfiguration()
}

public enum CloudMatchRequestFactory {
    public static func request(endpoint: CloudMatch.Endpoint, accessToken: String = "", queryItems: [URLQueryItem] = [], configuration: CloudMatchConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: configuration.baseURLString + endpoint.path)
        if !queryItems.isEmpty { components?.queryItems = queryItems }
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
