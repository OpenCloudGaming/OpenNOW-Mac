//  Token exchange and the plumbing around it: what a token response looks like, when a client token
//  needs refreshing, how requests are sent, retried and reported, and what can go wrong.
//

import Foundation

public struct StarfleetTokenSet: Equatable, Sendable {
    public let accessToken: String
    public let idToken: String
    public let refreshToken: String
    public let clientToken: String

    public init(accessToken: String, idToken: String, refreshToken: String, clientToken: String) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.clientToken = clientToken
    }
}

public struct StarfleetTokenResponse: Equatable, Sendable {
    public let tokenSet: StarfleetTokenSet
    public let expiresIn: Int64
    public let clientTokenExpiresIn: Int64
    public let issuedAt: Date

    public init(tokenSet: StarfleetTokenSet, expiresIn: Int64, clientTokenExpiresIn: Int64, issuedAt: Date) {
        self.tokenSet = tokenSet
        self.expiresIn = expiresIn
        self.clientTokenExpiresIn = clientTokenExpiresIn
        self.issuedAt = issuedAt
    }

    public var accessTokenExpiryMs: Int64 { issuedAtMs + expiresIn * 1000 }
    public var expiresAtSeconds: Int64 { Int64(issuedAt.timeIntervalSince1970) + expiresIn }
    public var clientTokenExpiryMs: Int64 { clientTokenExpiresIn > 0 && !tokenSet.clientToken.isEmpty ? issuedAtMs + clientTokenExpiresIn * 1000 : 0 }
    public var clientTokenExpiryLengthMs: Int64 { clientTokenExpiresIn > 0 && !tokenSet.clientToken.isEmpty ? clientTokenExpiresIn * 1000 : 0 }

    private var issuedAtMs: Int64 { Int64(issuedAt.timeIntervalSince1970 * 1000.0) }
}

public enum StarfleetTokenParser {
    public static func parseTokenResponse(_ json: [String: Any], issuedAt: Date = Date()) -> StarfleetTokenResponse {
        StarfleetTokenResponse(
            tokenSet: StarfleetTokenSet(
                accessToken: json["access_token"] as? String ?? "",
                idToken: json["id_token"] as? String ?? "",
                refreshToken: json["refresh_token"] as? String ?? "",
                clientToken: json["client_token"] as? String ?? ""
            ),
            expiresIn: int64Value(json["expires_in"]) ?? 86400,
            clientTokenExpiresIn: int64Value(json["client_token_expires_in"]) ?? 0,
            issuedAt: issuedAt
        )
    }

    public static func parseQueryString(_ query: String?) -> [String: String] {
        guard let query, !query.isEmpty else { return [:] }
        var params: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            let key = components[0].removingPercentEncoding ?? components[0]
            let value = components[1].removingPercentEncoding ?? ""
            params[key] = value
        }
        return params
    }

    public static func jwtClaims(_ idToken: String) -> [String: Any] {
        let parts = idToken.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return [:] }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return claims
    }

    public static func idTokenExpiry(_ idToken: String) -> Int64 {
        guard let exp = jwtClaims(idToken)["exp"] as? NSNumber else { return 0 }
        return exp.int64Value * 1000
    }

    public static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let int = value as? Int { return Int64(int) }
        if let int64 = value as? Int64 { return int64 }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}

public struct StarfleetClientTokenRefreshPolicy: Equatable, Sendable {
    public let fixedWindowMs: Int64
    public let percentageWindow: Int64

    public init(fixedWindowMs: Int64 = 5 * 60 * 1000, percentageWindow: Int64 = 20) {
        self.fixedWindowMs = fixedWindowMs
        self.percentageWindow = percentageWindow
    }

    public static let gfnPC = StarfleetClientTokenRefreshPolicy()

    public func shouldRefresh(clientToken: String, clientTokenExpiry: Int64, clientTokenExpiryLength: Int64, currentEpochMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000.0)) -> Bool {
        if clientToken.isEmpty || clientTokenExpiry == 0 { return true }
        let remainingMs = clientTokenExpiry - currentEpochMs
        if clientTokenExpiryLength > 0 {
            return remainingMs < (clientTokenExpiryLength * percentageWindow) / 100
        }
        return remainingMs < fixedWindowMs
    }
}

public protocol StarfleetHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct StarfleetURLSessionTransport: StarfleetHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await OPNURLSessionHTTPTransport.send(request, operation: "starfleet.transport", invalidHTTPResponseError: StarfleetAuthError.invalidHTTPResponse)
    }
}

public protocol StarfleetTelemetrySpan: Sendable {
    func setAttribute(_ key: String, value: String)
    func finish(success: Bool)
}

public protocol StarfleetTelemetry: Sendable {
    func startSpan(name: String, attributes: [String: String]) -> StarfleetTelemetrySpan
    func recordCounter(name: String, attributes: [String: String])
    func recordError(_ error: Error, attributes: [String: String])
}

public struct StarfleetNoOpTelemetry: StarfleetTelemetry {
    public init() {}

    public func startSpan(name: String, attributes: [String: String]) -> StarfleetTelemetrySpan {
        _ = name
        _ = attributes
        return StarfleetNoOpTelemetrySpan()
    }

    public func recordCounter(name: String, attributes: [String: String]) {
        _ = name
        _ = attributes
    }

    public func recordError(_ error: Error, attributes: [String: String]) {
        _ = error
        _ = attributes
    }
}

public struct StarfleetNoOpTelemetrySpan: StarfleetTelemetrySpan {
    public init() {}
    public func setAttribute(_ key: String, value: String) { _ = key; _ = value }
    public func finish(success: Bool) { _ = success }
}

public enum StarfleetAuthFailureCategory: String, CaseIterable, Sendable {
    case invalidRequest = "INVALID_REQUEST"
    case authorization = "AUTHORIZATION"
    case offline = "OFFLINE"
    case timeout = "TIMEOUT"
    case server = "SERVER"
    case rateLimited = "RATE_LIMITED"
    case unavailable = "UNAVAILABLE"
    case parsing = "PARSING"
    case missingData = "MISSING_DATA"
    case unknown = "UNKNOWN"
}

public enum StarfleetAuthError: Error, Equatable, Sendable {
    case invalidOAuthURL
    case invalidTokenURL
    case invalidDeviceAuthorizeURL
    case invalidUserInfoURL
    case invalidClientTokenURL
    case invalidHTTPResponse
    case invalidJSONResponse
    case httpStatus(Int)
    case oauthError(String)
    case stateMismatch
    case missingAuthorizationCode
    case noSavedSession
    case noRefreshMechanism
    case missingAccessToken
    case missingClientToken
    case missingDeviceCode
    case deviceAuthorizationPending
    case deviceAuthorizationSlowDown
    case deviceAuthorizationExpired
    case transportFailure(String, StarfleetAuthFailureCategory)

    public static func transportFailure(_ error: Error) -> StarfleetAuthError {
        if let urlError = error as? URLError {
            return .transportFailure(urlError.localizedDescription, category(for: urlError))
        }
        return .transportFailure(error.localizedDescription, .unknown)
    }

    public var category: StarfleetAuthFailureCategory {
        switch self {
        case .invalidOAuthURL, .invalidTokenURL, .invalidDeviceAuthorizeURL, .invalidUserInfoURL, .invalidClientTokenURL, .invalidHTTPResponse, .missingAuthorizationCode, .stateMismatch, .missingDeviceCode:
            .invalidRequest
        case .invalidJSONResponse:
            .parsing
        case .httpStatus(let status):
            Self.category(forHTTPStatus: status)
        case .oauthError:
            .authorization
        case .deviceAuthorizationPending, .deviceAuthorizationSlowDown:
            .unavailable
        case .deviceAuthorizationExpired:
            .authorization
        case .noSavedSession, .noRefreshMechanism, .missingAccessToken, .missingClientToken:
            .missingData
        case .transportFailure(_, let category):
            category
        }
    }

    private static func category(forHTTPStatus status: Int) -> StarfleetAuthFailureCategory {
        switch status {
        case 400, 404: .invalidRequest
        case 401, 403: .authorization
        case 408: .timeout
        case 429: .rateLimited
        case 500, 502: .server
        case 503, 504: .unavailable
        default: .unknown
        }
    }

    private static func category(for urlError: URLError) -> StarfleetAuthFailureCategory {
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            .offline
        case .timedOut:
            .timeout
        case .resourceUnavailable, .internationalRoamingOff, .dataNotAllowed:
            .unavailable
        default:
            .unknown
        }
    }
}

extension StarfleetAuthError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidOAuthURL: "Invalid Starfleet OAuth URL"
        case .invalidTokenURL: "Invalid Starfleet token URL"
        case .invalidDeviceAuthorizeURL: "Invalid Starfleet device authorization URL"
        case .invalidUserInfoURL: "Invalid Starfleet user info URL"
        case .invalidClientTokenURL: "Invalid Starfleet client token URL"
        case .invalidHTTPResponse: "Invalid Starfleet HTTP response"
        case .invalidJSONResponse: "Invalid Starfleet JSON response"
        case .httpStatus(let status): "Starfleet HTTP status \(status)"
        case .oauthError(let message): message.isEmpty ? "Starfleet OAuth failed" : message
        case .stateMismatch: "Starfleet OAuth state mismatch"
        case .missingAuthorizationCode: "Missing Starfleet authorization code"
        case .noSavedSession: "No saved Starfleet session"
        case .noRefreshMechanism: "No Starfleet refresh mechanism"
        case .missingAccessToken: "Missing Starfleet access token"
        case .missingClientToken: "Missing Starfleet client_token"
        case .missingDeviceCode: "Missing Starfleet device code"
        case .deviceAuthorizationPending: "Starfleet device authorization is pending"
        case .deviceAuthorizationSlowDown: "Starfleet device authorization polling slowed down"
        case .deviceAuthorizationExpired: "Starfleet device authorization expired"
        case .transportFailure(let message, _): message
        }
    }
}

public struct StarfleetRetryPolicy: Equatable, Sendable {
    public let maxRetries: Int
    public let baseDelayMs: UInt64
    public let retryableHTTPStatuses: Set<Int>

    public init(maxRetries: Int = 1, baseDelayMs: UInt64 = 250, retryableHTTPStatuses: Set<Int> = [408, 425, 429, 500, 502, 503, 504]) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelayMs = baseDelayMs
        self.retryableHTTPStatuses = retryableHTTPStatuses
    }

    public static let gfnPC = StarfleetRetryPolicy()

    public func shouldRetry(_ error: StarfleetAuthError, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }
        return switch error {
        case .httpStatus(let status): retryableHTTPStatuses.contains(status)
        case .transportFailure(_, let category): category == .timeout || category == .offline || category == .unavailable
        default: false
        }
    }

    public func delayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        guard baseDelayMs > 0 else { return 0 }
        return baseDelayMs * UInt64(max(1, attempt + 1)) * 1_000_000
    }
}
