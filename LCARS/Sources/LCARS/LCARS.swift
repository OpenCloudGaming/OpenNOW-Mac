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
        case overallGfnSupportedLanguages

        public var cachePolicy: LCARSCachePolicy {
            switch self {
            case .panels:
                LCARSCachePolicy(cacheName: "LCARS", maxEntries: 10, maxAgeSeconds: 1_209_600)
            case .staticAppData:
                LCARSCachePolicy(cacheName: "LCARSStatic", maxEntries: 5, maxAgeSeconds: 1_209_600)
            case .userAccount, .clientStrings, .loginWallData, .loginWallStrings:
                LCARSCachePolicy(cacheName: cacheName, maxEntries: 2, maxAgeSeconds: self == .loginWallData || self == .loginWallStrings ? 604_800 : 1_209_600)
            case .overallGfnSupportedLanguages:
                LCARSCachePolicy(cacheName: cacheName, maxEntries: 1, maxAgeSeconds: 1_209_600)
            }
        }

        public var cacheName: String {
            switch self {
            case .panels: "LCARS"
            case .staticAppData: "LCARSStatic"
            case .userAccount: "LCARSUserAccount"
            case .clientStrings: "LCARSClientStrings"
            case .loginWallData: "LoginWallData"
            case .loginWallStrings: "LoginWallStrings"
            case .overallGfnSupportedLanguages: "OverallGfnSupportedLanguages"
            }
        }
    }
}

public struct LCARSCachePolicy: Equatable, Sendable {
    public let cacheName: String
    public let maxEntries: Int
    public let maxAgeSeconds: Int
    public let purgeOnQuotaError: Bool

    public init(cacheName: String, maxEntries: Int, maxAgeSeconds: Int, purgeOnQuotaError: Bool = true) {
        self.cacheName = cacheName
        self.maxEntries = maxEntries
        self.maxAgeSeconds = maxAgeSeconds
        self.purgeOnQuotaError = purgeOnQuotaError
    }

    public func isExpired(cachedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(cachedAt) >= TimeInterval(maxAgeSeconds)
    }

    public func cacheKey(prefix: String, requestType: LCARS.RequestType) -> String {
        "\(prefix)-\(cacheName)-\(requestType.rawValue)"
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
