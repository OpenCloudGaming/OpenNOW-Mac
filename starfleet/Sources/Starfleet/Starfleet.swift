import Foundation

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
