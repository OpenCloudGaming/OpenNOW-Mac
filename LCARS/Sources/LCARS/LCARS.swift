import Foundation

public enum LCARS: Sendable {
    public static let systemName = "LCARS"
    public static let graphQLPath = "/graphql"
}

public extension LCARS {
    enum RequestType: String, CaseIterable, Sendable {
        case panels
        case staticAppData
        case userAccount
        case clientStrings
        case loginWallData
        case loginWallStrings
    }
}

public struct LCARSConfiguration: Equatable, Sendable {
    public let baseURLString: String
    public let userAgent: String

    public init(baseURLString: String, userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173") {
        self.baseURLString = baseURLString
        self.userAgent = userAgent
    }
}

public enum LCARSRequestFactory {
    public static func graphQLRequest(requestType: LCARS.RequestType, accessToken: String = "", queryItems: [URLQueryItem] = [], configuration: LCARSConfiguration, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var items = [URLQueryItem(name: "requestType", value: requestType.rawValue)]
        items.append(contentsOf: queryItems)
        var components = URLComponents(string: configuration.baseURLString + LCARS.graphQLPath)
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        return request
    }
}
