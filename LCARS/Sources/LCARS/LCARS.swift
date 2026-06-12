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

public protocol LCARSHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct LCARSURLSessionTransport: LCARSHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw LCARSServiceError.invalidHTTPResponse }
        return (data, httpResponse)
    }
}

public enum LCARSServiceError: LocalizedError, Equatable, Sendable {
    case invalidGraphQLURL(LCARS.RequestType)
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse

    public var errorDescription: String? {
        switch self {
        case .invalidGraphQLURL(let requestType): "Invalid LCARS GraphQL URL for \(requestType.rawValue)"
        case .invalidHTTPResponse: "Invalid LCARS HTTP response"
        case .httpStatus(let status): "LCARS HTTP status \(status)"
        case .invalidJSONResponse: "Invalid LCARS JSON response"
        }
    }
}

public struct LCARSService<Transport: LCARSHTTPTransport>: Sendable {
    private let configuration: LCARSConfiguration
    private let transport: Transport

    public init(configuration: LCARSConfiguration, transport: Transport) {
        self.configuration = configuration
        self.transport = transport
    }

    public func fetch(requestType: LCARS.RequestType, accessToken: String = "", queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let request = LCARSRequestFactory.graphQLRequest(requestType: requestType, accessToken: accessToken, queryItems: queryItems, configuration: configuration) else { throw LCARSServiceError.invalidGraphQLURL(requestType) }
        return try await performJSONRequest(request)
    }

    private func performJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw LCARSServiceError.httpStatus(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LCARSServiceError.invalidJSONResponse }
        return json
    }
}
