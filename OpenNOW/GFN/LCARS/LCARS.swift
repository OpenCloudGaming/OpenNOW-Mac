import Foundation
import CryptoKit

public enum LCARS: Sendable {
    public static let systemName = "LCARS"
    public static let graphQLPath = "/graphql"
    public static let productionGraphQLURLString = "https://games.geforce.com/graphql"
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

public struct LCARSClientHeaders: Equatable, Sendable {
    public static let swCacheBypassHeader = "x-sw-cachebypass"
    public static let swNotifyFetchHeader = "sw-notify-fetch"

    public let clientId: String
    public let clientType: String
    public let clientVersion: String
    public let clientStreamer: String
    public let deviceOS: String
    public let deviceType: String
    public let deviceMake: String
    public let deviceModel: String
    public let browserType: String
    public let userAgent: String

    public init(clientId: String = "ec7e38d4-03af-4b58-b131-cfb0495903ab",
                clientType: String = "NATIVE",
                clientVersion: String = "2.0.80.173",
                clientStreamer: String = "NVIDIA-CLASSIC",
                deviceOS: String = "MACOS",
                deviceType: String = "DESKTOP",
                deviceMake: String = "UNKNOWN",
                deviceModel: String = "UNKNOWN",
                browserType: String = "CHROME",
                userAgent: String = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 GFN-PC/2.0.80.173") {
        self.clientId = clientId
        self.clientType = clientType
        self.clientVersion = clientVersion
        self.clientStreamer = clientStreamer
        self.deviceOS = deviceOS
        self.deviceType = deviceType
        self.deviceMake = deviceMake
        self.deviceModel = deviceModel
        self.browserType = browserType
        self.userAgent = userAgent
    }

    public static let lcars = LCARSClientHeaders()

    public func apply(
        to request: inout URLRequest,
        accessToken: String,
        contentType: String,
        cacheBypass: Bool? = nil,
        notifyFetch: Bool = false,
        cascadeContent: String = "",
        stage: String = "",
        cascadePreviewToken: String = "",
        previewTime: String = ""
    ) {
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        request.setValue("https://play.geforcenow.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let cacheBypass { request.setValue(cacheBypass ? "true" : "false", forHTTPHeaderField: Self.swCacheBypassHeader) }
        if notifyFetch { request.setValue("true", forHTTPHeaderField: Self.swNotifyFetchHeader) }
        if !cascadeContent.isEmpty { request.setValue(cascadeContent, forHTTPHeaderField: "NV-Cascade-Content") }
        if !stage.isEmpty { request.setValue(stage, forHTTPHeaderField: "NV-Env") }
        if !cascadePreviewToken.isEmpty {
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("false", forHTTPHeaderField: Self.swCacheBypassHeader)
            request.setValue(cascadePreviewToken, forHTTPHeaderField: "NV-Additional")
            if !previewTime.isEmpty { request.setValue(previewTime, forHTTPHeaderField: "NV-Preview-Time") }
        }
        if !accessToken.isEmpty { request.setValue("GFNJWT \(accessToken)", forHTTPHeaderField: "Authorization") }
        if !clientId.isEmpty { request.setValue(clientId, forHTTPHeaderField: "NV-Client-ID") }
        if !clientType.isEmpty { request.setValue(clientType, forHTTPHeaderField: "NV-Client-Type") }
        if !clientVersion.isEmpty { request.setValue(clientVersion, forHTTPHeaderField: "NV-Client-Version") }
        if !clientStreamer.isEmpty { request.setValue(clientStreamer, forHTTPHeaderField: "NV-Client-Streamer") }
        if !deviceOS.isEmpty { request.setValue(deviceOS, forHTTPHeaderField: "NV-Device-OS") }
        if !deviceType.isEmpty { request.setValue(deviceType, forHTTPHeaderField: "NV-Device-Type") }
        if !deviceMake.isEmpty { request.setValue(deviceMake, forHTTPHeaderField: "NV-Device-Make") }
        if !deviceModel.isEmpty { request.setValue(deviceModel, forHTTPHeaderField: "NV-Device-Model") }
        if !browserType.isEmpty { request.setValue(browserType, forHTTPHeaderField: "NV-Browser-Type") }
    }
}

public struct LCARSConfiguration: Equatable, Sendable {
    public let graphQLURLString: String
    public let cdnGraphQLURLString: String
    public let headers: LCARSClientHeaders
    public let cascadeContent: String
    public let stage: String
    public let cascadePreviewToken: String
    public let previewTime: String

    public var baseURLString: String { graphQLURLString }
    public var userAgent: String { headers.userAgent }

    public init(
        baseURLString: String = LCARS.productionGraphQLURLString,
        cdnBaseURLString: String = "",
        headers: LCARSClientHeaders = .lcars,
        cascadeContent: String = "",
        stage: String = "",
        cascadePreviewToken: String = "",
        previewTime: String = ""
    ) {
        self.graphQLURLString = LCARSConfiguration.graphQLURLString(from: baseURLString)
        self.cdnGraphQLURLString = LCARSConfiguration.graphQLURLString(from: cdnBaseURLString.isEmpty ? baseURLString : cdnBaseURLString)
        self.headers = headers
        self.cascadeContent = cascadeContent
        self.stage = stage
        self.cascadePreviewToken = cascadePreviewToken
        self.previewTime = previewTime
    }

    public init(baseURLString: String = LCARS.productionGraphQLURLString, userAgent: String) {
        self.init(baseURLString: baseURLString, headers: LCARSClientHeaders(userAgent: userAgent))
    }

    private static func graphQLURLString(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return LCARS.productionGraphQLURLString }
        if trimmed.hasSuffix(LCARS.graphQLPath) { return trimmed }
        return trimmed + LCARS.graphQLPath
    }
}

public struct LCARSRequestOptions: Equatable, Sendable {
    public let forceCacheBypass: Bool
    public let notifyFetch: Bool
    public let useCDN: Bool

    public init(forceCacheBypass: Bool = false, notifyFetch: Bool = false, useCDN: Bool = false) {
        self.forceCacheBypass = forceCacheBypass
        self.notifyFetch = notifyFetch
        self.useCDN = useCDN
    }

    public static let standard = LCARSRequestOptions()
}

public enum LCARSRequestFactory {
    public static func persistedQueryRequest(operationName: String, queryHash: String, variables: Any? = nil, accessToken: String = "", configuration: LCARSConfiguration = LCARSConfiguration(), options: LCARSRequestOptions = .standard, huId: String = "", userId: String = "", timeoutInterval: TimeInterval = 20) -> URLRequest? {
        let resolvedHuId = huId.isEmpty ? makeHuId(userId: userId) : huId
        let extensions: [String: Any] = ["persistedQuery": ["sha256Hash": queryHash]]
        var queryItems = [
            URLQueryItem(name: "requestType", value: operationName),
            URLQueryItem(name: "extensions", value: jsonString(extensions) ?? "{}"),
        ]
        if !resolvedHuId.isEmpty { queryItems.append(URLQueryItem(name: "huId", value: resolvedHuId)) }
        queryItems.append(URLQueryItem(name: "variables", value: jsonString(variables) ?? "{}"))
        var components = URLComponents(string: options.useCDN && accessToken.isEmpty ? configuration.cdnGraphQLURLString : configuration.graphQLURLString)
        components?.queryItems = queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        configuration.headers.apply(
            to: &request,
            accessToken: accessToken,
            contentType: "application/graphql",
            cacheBypass: options.forceCacheBypass ? true : nil,
            notifyFetch: options.notifyFetch,
            cascadeContent: configuration.cascadeContent,
            stage: configuration.stage,
            cascadePreviewToken: configuration.cascadePreviewToken,
            previewTime: configuration.previewTime
        )
        return request
    }

    public static func inlineGraphQLRequest(query: String, variables: Any? = nil, accessToken: String = "", configuration: LCARSConfiguration = LCARSConfiguration(), options: LCARSRequestOptions = .standard, timeoutInterval: TimeInterval = 20) -> URLRequest? {
        var body: [String: Any] = ["query": query]
        if let variables { body["variables"] = variables }
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body), let url = URL(string: options.useCDN && accessToken.isEmpty ? configuration.cdnGraphQLURLString : configuration.graphQLURLString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.httpBody = bodyData
        configuration.headers.apply(
            to: &request,
            accessToken: accessToken,
            contentType: "application/json",
            cacheBypass: options.forceCacheBypass ? true : nil,
            notifyFetch: options.notifyFetch,
            cascadeContent: configuration.cascadeContent,
            stage: configuration.stage,
            cascadePreviewToken: configuration.cascadePreviewToken,
            previewTime: configuration.previewTime
        )
        return request
    }

    public static func graphQLRequest(requestType: LCARS.RequestType, accessToken: String = "", queryItems: [URLQueryItem] = [], configuration: LCARSConfiguration, options: LCARSRequestOptions = .standard, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        var components = URLComponents(string: options.useCDN && accessToken.isEmpty ? configuration.cdnGraphQLURLString : configuration.graphQLURLString)
        components?.queryItems = [URLQueryItem(name: "requestType", value: requestType.rawValue)] + queryItems
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        configuration.headers.apply(
            to: &request,
            accessToken: accessToken,
            contentType: "application/graphql",
            cacheBypass: options.forceCacheBypass ? true : nil,
            notifyFetch: options.notifyFetch,
            cascadeContent: configuration.cascadeContent,
            stage: configuration.stage,
            cascadePreviewToken: configuration.cascadePreviewToken,
            previewTime: configuration.previewTime
        )
        return request
    }

    public static func makeHuId(date: Date = Date(), uuid: UUID = UUID()) -> String {
        "\(Int(date.timeIntervalSince1970 * 1000))\(uuid.uuidString.replacingOccurrences(of: "-", with: "").prefix(8))"
    }

    public static func makeHuId(userId: String) -> String {
        let trimmed = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return makeHuId() }
        return Insecure.SHA1.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

public protocol LCARSHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct LCARSURLSessionTransport: LCARSHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await OPNURLSessionHTTPTransport.send(request, operation: "lcars.transport", invalidHTTPResponseError: LCARSServiceError.invalidHTTPResponse)
    }
}

public enum LCARSServiceError: LocalizedError, Equatable, Sendable {
    case invalidGraphQLURL(LCARS.RequestType)
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse
    case missingFallbackQuery

    public var errorDescription: String? {
        switch self {
        case .invalidGraphQLURL(let requestType): "Invalid LCARS GraphQL URL for \(requestType.rawValue)"
        case .invalidHTTPResponse: "Invalid LCARS HTTP response"
        case .httpStatus(let status): "LCARS HTTP status \(status)"
        case .invalidJSONResponse: "Invalid LCARS JSON response"
        case .missingFallbackQuery: "Missing LCARS fallback query"
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

    public func fetch(requestType: LCARS.RequestType, accessToken: String = "", queryItems: [URLQueryItem] = [], options: LCARSRequestOptions = .standard) async throws -> [String: Any] {
        guard let request = LCARSRequestFactory.graphQLRequest(requestType: requestType, accessToken: accessToken, queryItems: queryItems, configuration: configuration, options: options) else { throw LCARSServiceError.invalidGraphQLURL(requestType) }
        return try await performJSONRequest(request)
    }

    public func fetchPersistedQuery(operationName: String, queryHash: String, query: String = "", variables: Any? = nil, accessToken: String = "", userId: String = "", options: LCARSRequestOptions = .standard) async throws -> [String: Any] {
        guard let request = LCARSRequestFactory.persistedQueryRequest(operationName: operationName, queryHash: queryHash, variables: variables, accessToken: accessToken, configuration: configuration, options: options, userId: userId) else { throw LCARSServiceError.invalidGraphQLURL(.panels) }
        let (data, response) = try await transport.send(request)
        if response.statusCode == 400 {
            guard !query.isEmpty else { throw LCARSServiceError.missingFallbackQuery }
            guard let fallback = LCARSRequestFactory.inlineGraphQLRequest(query: query, variables: variables, accessToken: accessToken, configuration: configuration, options: LCARSRequestOptions(forceCacheBypass: true, notifyFetch: options.notifyFetch, useCDN: options.useCDN)) else { throw LCARSServiceError.invalidGraphQLURL(.panels) }
            return try await performJSONRequest(fallback)
        }
        return try decodeJSON(data: data, response: response)
    }

    private func performJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport.send(request)
        return try decodeJSON(data: data, response: response)
    }

    private func decodeJSON(data: Data, response: HTTPURLResponse) throws -> [String: Any] {
        guard response.statusCode == 200 else { throw LCARSServiceError.httpStatus(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LCARSServiceError.invalidJSONResponse }
        return json
    }
}
