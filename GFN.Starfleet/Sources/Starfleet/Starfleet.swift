import Foundation
import OpenNOWTelemetry

public enum Starfleet: Sendable {
    public static let systemName = "Starfleet"
    public static let loginBaseURLString = "https://login.nvidia.com"
    public static let clientId = "ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ"
    public static let defaultIdpId = "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg"
    public static let defaultOrigin = "https://nvfile"
    public static let defaultReferer = "https://nvfile/"
    public static let defaultUserAgent = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173"
    public static let oauthScope = "openid consent email tk_client age"
}

public extension Starfleet {
    enum Endpoint: String, CaseIterable, Sendable {
        case authorize = "/authorize"
        case token = "/token"
        case userInfo = "/userinfo"
        case clientToken = "/client_token"
        case logout = "/logout"

        public var urlString: String { Starfleet.loginBaseURLString + rawValue }
    }

    enum GrantType: String, CaseIterable, Sendable {
        case authorizationCode = "authorization_code"
        case refreshToken = "refresh_token"
        case clientToken = "urn:ietf:params:oauth:grant-type:client_token"
    }
}

public struct StarfleetOAuthState: Equatable, Sendable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let state: String
    public let nonce: String

    public init(codeVerifier: String, codeChallenge: String, state: String, nonce: String) {
        self.codeVerifier = codeVerifier
        self.codeChallenge = codeChallenge
        self.state = state
        self.nonce = nonce
    }
}

public struct StarfleetOAuthConfiguration: Equatable, Sendable {
    public let authorizeURLString: String
    public let tokenURLString: String
    public let userInfoURLString: String
    public let clientTokenURLString: String
    public let logoutURLString: String
    public let clientId: String
    public let redirectURI: String
    public let scope: String
    public let defaultIdpId: String
    public let userAgent: String
    public let origin: String
    public let referer: String

    public init(
        authorizeURLString: String = Starfleet.Endpoint.authorize.urlString,
        tokenURLString: String = Starfleet.Endpoint.token.urlString,
        userInfoURLString: String = Starfleet.Endpoint.userInfo.urlString,
        clientTokenURLString: String = Starfleet.Endpoint.clientToken.urlString,
        logoutURLString: String = Starfleet.Endpoint.logout.urlString,
        clientId: String = Starfleet.clientId,
        redirectURI: String = "com.nvidia.geforcenow://oauth/callback",
        scope: String = Starfleet.oauthScope,
        defaultIdpId: String = Starfleet.defaultIdpId,
        userAgent: String = Starfleet.defaultUserAgent,
        origin: String = Starfleet.defaultOrigin,
        referer: String = Starfleet.defaultReferer
    ) {
        self.authorizeURLString = authorizeURLString
        self.tokenURLString = tokenURLString
        self.userInfoURLString = userInfoURLString
        self.clientTokenURLString = clientTokenURLString
        self.logoutURLString = logoutURLString
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scope = scope
        self.defaultIdpId = defaultIdpId
        self.userAgent = userAgent
        self.origin = origin
        self.referer = referer
    }

    public static let gfnPC = StarfleetOAuthConfiguration()
}

public enum StarfleetOAuthRequestFactory {
    public static func authorizationURL(
        configuration: StarfleetOAuthConfiguration = .gfnPC,
        deviceId: String,
        redirectURI: String,
        locale: String,
        oauthState: StarfleetOAuthState,
        providerIdpId: String
    ) -> URL? {
        var components = URLComponents(string: configuration.authorizeURLString)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "scope", value: configuration.scope),
            URLQueryItem(name: "client_id", value: configuration.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "ui_locales", value: locale),
            URLQueryItem(name: "nonce", value: oauthState.nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "code_challenge", value: oauthState.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "idp_id", value: providerIdpId.isEmpty ? configuration.defaultIdpId : providerIdpId),
            URLQueryItem(name: "state", value: oauthState.state),
        ]
        return components?.url
    }

    public static func authorizationCodeTokenBody(authCode: String, redirectURI: String, codeVerifier: String) -> String {
        formBody([
            ("grant_type", Starfleet.GrantType.authorizationCode.rawValue),
            ("code", authCode),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
        ])
    }

    public static func refreshTokenBody(refreshToken: String, configuration: StarfleetOAuthConfiguration = .gfnPC) -> String {
        formBody([
            ("grant_type", Starfleet.GrantType.refreshToken.rawValue),
            ("refresh_token", refreshToken),
            ("client_id", configuration.clientId),
        ])
    }

    public static func clientTokenGrantBody(clientToken: String, userId: String, configuration: StarfleetOAuthConfiguration = .gfnPC) -> String {
        formBody([
            ("grant_type", Starfleet.GrantType.clientToken.rawValue),
            ("client_token", clientToken),
            ("client_id", configuration.clientId),
            ("sub", userId),
        ])
    }

    public static func tokenRequest(body: String, configuration: StarfleetOAuthConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        guard let url = URL(string: configuration.tokenURLString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(configuration.origin, forHTTPHeaderField: "Origin")
        request.setValue(configuration.referer, forHTTPHeaderField: "Referer")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body.data(using: .utf8)
        return request
    }

    public static func userInfoRequest(accessToken: String, configuration: StarfleetOAuthConfiguration = .gfnPC, timeoutInterval: TimeInterval = 10) -> URLRequest? {
        authenticatedGetRequest(urlString: configuration.userInfoURLString, accessToken: accessToken, accept: "application/json", configuration: configuration, timeoutInterval: timeoutInterval)
    }

    public static func clientTokenRequest(accessToken: String, configuration: StarfleetOAuthConfiguration = .gfnPC, timeoutInterval: TimeInterval = 10) -> URLRequest? {
        authenticatedGetRequest(urlString: configuration.clientTokenURLString, accessToken: accessToken, accept: "application/json, text/plain, */*", configuration: configuration, timeoutInterval: timeoutInterval)
    }

    public static func logoutURL(idToken: String, locale: String, configuration: StarfleetOAuthConfiguration = .gfnPC) -> URL? {
        var components = URLComponents(string: configuration.logoutURLString)
        components?.queryItems = [
            URLQueryItem(name: "id_token_hint", value: idToken),
            URLQueryItem(name: "ui_locales", value: locale),
        ]
        return components?.url
    }

    private static func authenticatedGetRequest(urlString: String, accessToken: String, accept: String, configuration: StarfleetOAuthConfiguration, timeoutInterval: TimeInterval) -> URLRequest? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.origin, forHTTPHeaderField: "Origin")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func formBody(_ items: [(String, String)]) -> String {
        items.map { "\(formURLEncode($0.0))=\(formURLEncode($0.1))" }.joined(separator: "&")
    }

    private static func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

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
        var tracedRequest = request
        let networkStart = OPNNetworkLog.start(&tracedRequest, operation: "starfleet.transport")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: tracedRequest)
        } catch {
            OPNNetworkLog.finish(tracedRequest, operation: "starfleet.transport", startedAt: networkStart, data: nil, response: nil, error: error)
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            OPNNetworkLog.finish(tracedRequest, operation: "starfleet.transport", startedAt: networkStart, data: data, response: response, error: StarfleetAuthError.invalidHTTPResponse)
            throw StarfleetAuthError.invalidHTTPResponse
        }
        OPNNetworkLog.finish(tracedRequest, operation: "starfleet.transport", startedAt: networkStart, data: data, response: response, error: nil)
        return (data, httpResponse)
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
    case invalidTokenURL
    case invalidUserInfoURL
    case invalidClientTokenURL
    case invalidHTTPResponse
    case invalidJSONResponse
    case httpStatus(Int)
    case noSavedSession
    case noRefreshMechanism
    case missingAccessToken
    case missingClientToken
    case transportFailure(String, StarfleetAuthFailureCategory)

    public static func transportFailure(_ error: Error) -> StarfleetAuthError {
        if let urlError = error as? URLError {
            return .transportFailure(urlError.localizedDescription, category(for: urlError))
        }
        return .transportFailure(error.localizedDescription, .unknown)
    }

    public var category: StarfleetAuthFailureCategory {
        switch self {
        case .invalidTokenURL, .invalidUserInfoURL, .invalidClientTokenURL, .invalidHTTPResponse:
            .invalidRequest
        case .invalidJSONResponse:
            .parsing
        case .httpStatus(let status):
            Self.category(forHTTPStatus: status)
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
        case .invalidTokenURL: "Invalid Starfleet token URL"
        case .invalidUserInfoURL: "Invalid Starfleet user info URL"
        case .invalidClientTokenURL: "Invalid Starfleet client token URL"
        case .invalidHTTPResponse: "Invalid Starfleet HTTP response"
        case .invalidJSONResponse: "Invalid Starfleet JSON response"
        case .httpStatus(let status): "Starfleet HTTP status \(status)"
        case .noSavedSession: "No saved Starfleet session"
        case .noRefreshMechanism: "No Starfleet refresh mechanism"
        case .missingAccessToken: "Missing Starfleet access token"
        case .missingClientToken: "Missing Starfleet client_token"
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

public struct StarfleetSession: Equatable, Sendable {
    public var accessToken: String
    public var idToken: String
    public var refreshToken: String
    public var userId: String
    public var displayName: String
    public var email: String
    public var idpId: String
    public var expiresAt: Int64
    public var isAuthenticated: Bool
    public var clientToken: String
    public var clientTokenExpiry: Int64
    public var clientTokenExpiryLength: Int64
    public var idTokenExpiry: Int64
    public var accessTokenExpiry: Int64

    public init(
        accessToken: String = "",
        idToken: String = "",
        refreshToken: String = "",
        userId: String = "",
        displayName: String = "",
        email: String = "",
        idpId: String = Starfleet.defaultIdpId,
        expiresAt: Int64 = 0,
        isAuthenticated: Bool = false,
        clientToken: String = "",
        clientTokenExpiry: Int64 = 0,
        clientTokenExpiryLength: Int64 = 0,
        idTokenExpiry: Int64 = 0,
        accessTokenExpiry: Int64 = 0
    ) {
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
        self.userId = userId
        self.displayName = displayName
        self.email = email
        self.idpId = idpId
        self.expiresAt = expiresAt
        self.isAuthenticated = isAuthenticated
        self.clientToken = clientToken
        self.clientTokenExpiry = clientTokenExpiry
        self.clientTokenExpiryLength = clientTokenExpiryLength
        self.idTokenExpiry = idTokenExpiry
        self.accessTokenExpiry = accessTokenExpiry
    }

    public var isAccessTokenValid: Bool { !accessToken.isEmpty && accessTokenExpiry > Self.currentEpochMs() }
    public var isClientTokenValid: Bool { !clientToken.isEmpty && clientTokenExpiry > Self.currentEpochMs() }

    public static func currentEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }
}

public struct StarfleetUserInfo: Equatable, Sendable {
    public var userId: String
    public var externalId: String
    public var idpId: String
    public var preferredUsername: String
    public var displayName: String
    public var email: String
    public var isAuthenticated: Bool
    public var isNetworkCall: Bool

    public init(userId: String = "", externalId: String = "", idpId: String = "", preferredUsername: String = "", displayName: String = "", email: String = "", isAuthenticated: Bool = false, isNetworkCall: Bool = false) {
        self.userId = userId
        self.externalId = externalId
        self.idpId = idpId
        self.preferredUsername = preferredUsername
        self.displayName = displayName
        self.email = email
        self.isAuthenticated = isAuthenticated
        self.isNetworkCall = isNetworkCall
    }
}

public enum StarfleetSessionParser {
    public static func parseTokenResponse(_ json: [String: Any], defaultIdpId: String = Starfleet.defaultIdpId, issuedAt: Date = Date()) -> StarfleetSession {
        let tokenResponse = StarfleetTokenParser.parseTokenResponse(json, issuedAt: issuedAt)
        let claims = StarfleetTokenParser.jwtClaims(tokenResponse.tokenSet.idToken)
        let userId = claims["sub"] as? String ?? ""
        let displayName = claims["name"] as? String ?? (claims["preferred_username"] as? String ?? "")
        let email = claims["email"] as? String ?? ""
        return StarfleetSession(
            accessToken: tokenResponse.tokenSet.accessToken,
            idToken: tokenResponse.tokenSet.idToken,
            refreshToken: tokenResponse.tokenSet.refreshToken,
            userId: userId,
            displayName: displayName,
            email: email,
            idpId: claims["idp_id"] as? String ?? defaultIdpId,
            expiresAt: tokenResponse.expiresAtSeconds,
            isAuthenticated: !tokenResponse.tokenSet.accessToken.isEmpty,
            clientToken: tokenResponse.tokenSet.clientToken,
            clientTokenExpiry: tokenResponse.clientTokenExpiryMs,
            clientTokenExpiryLength: tokenResponse.clientTokenExpiryLengthMs,
            idTokenExpiry: StarfleetTokenParser.idTokenExpiry(tokenResponse.tokenSet.idToken),
            accessTokenExpiry: tokenResponse.accessTokenExpiryMs
        )
    }
}

public actor StarfleetService<Transport: StarfleetHTTPTransport> {
    public private(set) var session: StarfleetSession
    public private(set) var cachedUser: StarfleetUserInfo

    private let configuration: StarfleetOAuthConfiguration
    private let refreshPolicy: StarfleetClientTokenRefreshPolicy
    private let retryPolicy: StarfleetRetryPolicy
    private let transport: Transport
    private let telemetry: StarfleetTelemetry

    public init(
        configuration: StarfleetOAuthConfiguration = .gfnPC,
        refreshPolicy: StarfleetClientTokenRefreshPolicy = .gfnPC,
        retryPolicy: StarfleetRetryPolicy = .gfnPC,
        transport: Transport,
        telemetry: StarfleetTelemetry = StarfleetNoOpTelemetry(),
        session: StarfleetSession = StarfleetSession()
    ) {
        self.configuration = configuration
        self.refreshPolicy = refreshPolicy
        self.retryPolicy = retryPolicy
        self.transport = transport
        self.telemetry = telemetry
        self.session = session
        self.cachedUser = StarfleetUserInfo()
    }

    public func setSession(_ session: StarfleetSession) {
        self.session = session
    }

    public func clearSession() {
        session = StarfleetSession()
        cachedUser = StarfleetUserInfo()
    }

    public func exchangeAuthorizationCode(authCode: String, redirectURI: String, codeVerifier: String, providerIdpId: String = "") async throws -> StarfleetSession {
        let span = telemetry.startSpan(name: "Starfleet_Get_Session_Token", attributes: ["grant_type": Starfleet.GrantType.authorizationCode.rawValue])
        do {
            let body = StarfleetOAuthRequestFactory.authorizationCodeTokenBody(authCode: authCode, redirectURI: redirectURI, codeVerifier: codeVerifier)
            var exchanged = try await requestSession(body: body)
            if !providerIdpId.isEmpty { exchanged.idpId = providerIdpId }
            let enriched = try await ensureClientToken(exchanged)
            session = enriched
            telemetry.recordCounter(name: "starfleet.auth.exchange.count", attributes: ["outcome": "success"])
            span.finish(success: true)
            return enriched
        } catch {
            telemetry.recordError(error, attributes: ["phase": "authorization_code_exchange"])
            telemetry.recordCounter(name: "starfleet.auth.exchange.count", attributes: ["outcome": "failure"])
            span.finish(success: false)
            throw error
        }
    }

    public func refreshSession(force: Bool = false) async throws -> StarfleetSession {
        let span = telemetry.startSpan(name: "Starfleet_Get_Session_Token", attributes: ["force": force ? "true" : "false"])
        do {
            guard session.isAuthenticated else { throw StarfleetAuthError.noSavedSession }
            if !force && session.isAccessTokenValid {
                if shouldRefreshClientToken(session) {
                    let enriched = try await ensureClientToken(session)
                    self.session = enriched
                    span.finish(success: true)
                    return enriched
                }
                span.finish(success: true)
                return session
            }
            if !session.clientToken.isEmpty {
                let body = StarfleetOAuthRequestFactory.clientTokenGrantBody(clientToken: session.clientToken, userId: session.userId, configuration: configuration)
                let refreshed = merge(saved: session, refreshed: try await requestSession(body: body))
                let enriched = try await ensureClientToken(refreshed)
                self.session = enriched
                telemetry.recordCounter(name: "starfleet.auth.refresh.count", attributes: ["outcome": "success", "grant_type": Starfleet.GrantType.clientToken.rawValue])
                span.finish(success: true)
                return enriched
            }
            guard !session.refreshToken.isEmpty else { throw StarfleetAuthError.noRefreshMechanism }
            let body = StarfleetOAuthRequestFactory.refreshTokenBody(refreshToken: session.refreshToken, configuration: configuration)
            let refreshed = merge(saved: session, refreshed: try await requestSession(body: body))
            let enriched = try await ensureClientToken(refreshed)
            self.session = enriched
            telemetry.recordCounter(name: "starfleet.auth.refresh.count", attributes: ["outcome": "success", "grant_type": Starfleet.GrantType.refreshToken.rawValue])
            span.finish(success: true)
            return enriched
        } catch {
            telemetry.recordError(error, attributes: ["phase": "session_refresh"])
            telemetry.recordCounter(name: "starfleet.auth.refresh.count", attributes: ["outcome": "failure"])
            span.finish(success: false)
            throw error
        }
    }

    public func getAuthToken(forceRefresh: Bool = false) async throws -> String {
        let refreshed = try await refreshSession(force: forceRefresh)
        guard !refreshed.accessToken.isEmpty else { throw StarfleetAuthError.missingAccessToken }
        return refreshed.accessToken
    }

    public func getCurrentUser(forceRefresh: Bool = false) async throws -> StarfleetUserInfo {
        let refreshed = try await refreshSession(force: forceRefresh)
        if !forceRefresh, cachedUser.isAuthenticated, cachedUser.userId == refreshed.userId {
            return cachedUser
        }
        let user = try await fetchUserInfo(accessToken: refreshed.accessToken)
        cachedUser = user
        return user
    }

    public func fetchUserInfo(accessToken: String, isNetworkCall: Bool = true) async throws -> StarfleetUserInfo {
        guard let request = StarfleetOAuthRequestFactory.userInfoRequest(accessToken: accessToken, configuration: configuration) else {
            throw StarfleetAuthError.invalidUserInfoURL
        }
        let json = try await performJSONRequest(request)
        return parseUserInfo(json, isNetworkCall: isNetworkCall)
    }

    public func fetchClientToken(accessToken: String) async throws -> (clientToken: String, expiresIn: String) {
        guard let request = StarfleetOAuthRequestFactory.clientTokenRequest(accessToken: accessToken, configuration: configuration) else {
            throw StarfleetAuthError.invalidClientTokenURL
        }
        let json = try await performJSONRequest(request)
        let clientToken = json["client_token"] as? String ?? ""
        guard !clientToken.isEmpty else { throw StarfleetAuthError.missingClientToken }
        let expiresIn = (json["expires_in"] as? NSNumber)?.stringValue ?? (json["expires_in"] as? String ?? "")
        return (clientToken, expiresIn)
    }

    private func requestSession(body: String) async throws -> StarfleetSession {
        guard let request = StarfleetOAuthRequestFactory.tokenRequest(body: body, configuration: configuration) else {
            throw StarfleetAuthError.invalidTokenURL
        }
        return StarfleetSessionParser.parseTokenResponse(try await performJSONRequest(request), defaultIdpId: configuration.defaultIdpId)
    }

    private func ensureClientToken(_ current: StarfleetSession) async throws -> StarfleetSession {
        guard current.isAuthenticated, current.isAccessTokenValid, shouldRefreshClientToken(current) else { return current }
        let result = try await fetchClientToken(accessToken: current.accessToken)
        var enriched = current
        let parsedExpiresIn = Int64(result.expiresIn) ?? 0
        let expiresIn = parsedExpiresIn > 0 ? parsedExpiresIn : 86400
        enriched.clientToken = result.clientToken
        enriched.clientTokenExpiry = StarfleetSession.currentEpochMs() + expiresIn * 1000
        enriched.clientTokenExpiryLength = expiresIn * 1000
        return enriched
    }

    private func shouldRefreshClientToken(_ current: StarfleetSession) -> Bool {
        refreshPolicy.shouldRefresh(clientToken: current.clientToken, clientTokenExpiry: current.clientTokenExpiry, clientTokenExpiryLength: current.clientTokenExpiryLength, currentEpochMs: StarfleetSession.currentEpochMs())
    }

    private func merge(saved: StarfleetSession, refreshed: StarfleetSession) -> StarfleetSession {
        var merged = refreshed
        if merged.refreshToken.isEmpty { merged.refreshToken = saved.refreshToken }
        if merged.clientToken.isEmpty {
            merged.clientToken = saved.clientToken
            merged.clientTokenExpiry = saved.clientTokenExpiry
            merged.clientTokenExpiryLength = saved.clientTokenExpiryLength
        }
        if merged.email.isEmpty { merged.email = saved.email }
        if merged.displayName.isEmpty { merged.displayName = saved.displayName }
        if merged.userId.isEmpty { merged.userId = saved.userId }
        if merged.idpId.isEmpty { merged.idpId = saved.idpId }
        return merged
    }

    private func performJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        var attempt = 0
        while true {
            do {
                return try await performJSONRequestOnce(request)
            } catch let error as StarfleetAuthError {
                guard retryPolicy.shouldRetry(error, attempt: attempt) else { throw error }
                telemetry.recordCounter(name: "starfleet.auth.retry.count", attributes: ["category": error.category.rawValue, "attempt": String(attempt + 1)])
                let delay = retryPolicy.delayNanoseconds(forAttempt: attempt)
                attempt += 1
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            } catch {
                let mapped = StarfleetAuthError.transportFailure(error)
                guard retryPolicy.shouldRetry(mapped, attempt: attempt) else { throw mapped }
                telemetry.recordCounter(name: "starfleet.auth.retry.count", attributes: ["category": mapped.category.rawValue, "attempt": String(attempt + 1)])
                let delay = retryPolicy.delayNanoseconds(forAttempt: attempt)
                attempt += 1
                if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            }
        }
    }

    private func performJSONRequestOnce(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch let error as StarfleetAuthError {
            throw error
        } catch {
            throw StarfleetAuthError.transportFailure(error)
        }

        guard response.statusCode == 200 else { throw StarfleetAuthError.httpStatus(response.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StarfleetAuthError.invalidJSONResponse
        }
        return json
    }

    private func parseUserInfo(_ json: [String: Any], isNetworkCall: Bool) -> StarfleetUserInfo {
        let userId = json["sub"] as? String ?? (json["userId"] as? String ?? "")
        let displayName = json["name"] as? String ?? (json["preferred_username"] as? String ?? "")
        return StarfleetUserInfo(
            userId: userId,
            externalId: json["external_id"] as? String ?? (json["externalId"] as? String ?? ""),
            idpId: json["idp_id"] as? String ?? (json["idpId"] as? String ?? Starfleet.defaultIdpId),
            preferredUsername: json["preferred_username"] as? String ?? "",
            displayName: displayName,
            email: json["email"] as? String ?? "",
            isAuthenticated: !userId.isEmpty || !displayName.isEmpty,
            isNetworkCall: isNetworkCall
        )
    }
}
