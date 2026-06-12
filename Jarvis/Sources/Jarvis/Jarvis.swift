import Foundation

public enum Jarvis: Sendable {
    public static let systemName = "Jarvis"
    public static let oauthLoggerName = "jarvis/o-auth"
    public static let oauthSpanName = "JarvisOAuth"
    public static let loginTelemetryName = "JARVIS_LOGIN"
    public static let logoutTelemetryName = "JARVIS_LOGOUT"
    public static let monitorLoginStatusTelemetryName = "JARVIS_MONITOR_LOGIN_STATUS"
    public static let defaultIdpId = "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg"

    public static let operations: [Operation] = [
        .chainSession,
        .getDelegateToken,
        .getLoginToken,
        .getSessionToken,
        .getThirdPartyProviderInfo,
        .getUserInfo,
        .getUserToken,
        .redeemDelegateToken,
        .requestEmailVerify,
    ]
}

public extension Jarvis {
    enum Operation: String, CaseIterable, Sendable {
        case chainSession = "JARVIS_Chain_Session"
        case getDelegateToken = "JARVIS_Get_Delegate_Token"
        case getLoginToken = "JARVIS_Get_Login_Token"
        case getSessionToken = "JARVIS_Get_Session_Token"
        case getThirdPartyProviderInfo = "JARVIS_Get_Third_Party_Provider_Info"
        case getUserInfo = "JARVIS_Get_User_Info"
        case getUserToken = "JARVIS_Get_User_Token"
        case redeemDelegateToken = "JARVIS_Redeem_Delegate_Token"
        case requestEmailVerify = "JARVIS_Request_Email_Verify"
        case getPin = "JARVIS_Get_Pin"
        case setPin = "JARVIS_Set_Pin"
        case verifyPin = "JARVIS_Verify_Pin"
    }
}

public struct JarvisIdentity: Equatable, Sendable {
    public let userId: String
    public let externalUserId: String
    public let idpId: String

    public init(userId: String, externalUserId: String, idpId: String) {
        self.userId = userId
        self.externalUserId = externalUserId
        self.idpId = idpId
    }
}

public struct JarvisCredentials: Equatable, Sendable {
    public var email: String
    public var providerIdpId: String
    public var stayLoggedIn: Bool

    public init(email: String = "", providerIdpId: String = "", stayLoggedIn: Bool = true) {
        self.email = email
        self.providerIdpId = providerIdpId
        self.stayLoggedIn = stayLoggedIn
    }
}

public struct JarvisSession: Equatable, Sendable {
    public var accessToken: String
    public var idToken: String
    public var refreshToken: String
    public var userId: String
    public var displayName: String
    public var email: String
    public var membershipTier: String
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
        membershipTier: String = "",
        idpId: String = "",
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
        self.membershipTier = membershipTier
        self.idpId = idpId
        self.expiresAt = expiresAt
        self.isAuthenticated = isAuthenticated
        self.clientToken = clientToken
        self.clientTokenExpiry = clientTokenExpiry
        self.clientTokenExpiryLength = clientTokenExpiryLength
        self.idTokenExpiry = idTokenExpiry
        self.accessTokenExpiry = accessTokenExpiry
    }

    public static func currentEpochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    public var isClientTokenValid: Bool {
        !clientToken.isEmpty && clientTokenExpiry > Self.currentEpochMs()
    }

    public var isAccessTokenValid: Bool {
        !accessToken.isEmpty && accessTokenExpiry > Self.currentEpochMs()
    }

    public var hasAccessToken: Bool {
        !accessToken.isEmpty
    }

    public mutating func clear() {
        self = JarvisSession()
    }
}

public struct JarvisOAuthState: Equatable, Sendable {
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

public struct JarvisOAuthConfiguration: Equatable, Sendable {
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
        authorizeURLString: String = "https://login.nvidia.com/authorize",
        tokenURLString: String = "https://login.nvidia.com/token",
        userInfoURLString: String = "https://login.nvidia.com/userinfo",
        clientTokenURLString: String = "https://login.nvidia.com/client_token",
        logoutURLString: String = "https://login.nvidia.com/logout",
        clientId: String = "ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ",
        redirectURI: String = "com.nvidia.geforcenow://oauth/callback",
        scope: String = "openid consent email tk_client age",
        defaultIdpId: String = Jarvis.defaultIdpId,
        userAgent: String = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173",
        origin: String = "https://nvfile",
        referer: String = "https://nvfile/"
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

    public static let gfnPC = JarvisOAuthConfiguration()
}

public enum JarvisOAuthRequestFactory {
    public static func authorizationURL(
        configuration: JarvisOAuthConfiguration = .gfnPC,
        deviceId: String,
        redirectURI: String,
        locale: String,
        oauthState: JarvisOAuthState,
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
            ("grant_type", "authorization_code"),
            ("code", authCode),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
        ])
    }

    public static func refreshTokenBody(refreshToken: String, configuration: JarvisOAuthConfiguration = .gfnPC) -> String {
        formBody([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", configuration.clientId),
        ])
    }

    public static func clientTokenGrantBody(clientToken: String, userId: String, configuration: JarvisOAuthConfiguration = .gfnPC) -> String {
        formBody([
            ("grant_type", "urn:ietf:params:oauth:grant-type:client_token"),
            ("client_token", clientToken),
            ("client_id", configuration.clientId),
            ("sub", userId),
        ])
    }

    public static func tokenRequest(body: String, configuration: JarvisOAuthConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
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

    public static func userInfoRequest(accessToken: String, configuration: JarvisOAuthConfiguration = .gfnPC, timeoutInterval: TimeInterval = 10) -> URLRequest? {
        authenticatedGetRequest(urlString: configuration.userInfoURLString, accessToken: accessToken, accept: "application/json", configuration: configuration, timeoutInterval: timeoutInterval)
    }

    public static func clientTokenRequest(accessToken: String, configuration: JarvisOAuthConfiguration = .gfnPC, timeoutInterval: TimeInterval = 10) -> URLRequest? {
        authenticatedGetRequest(urlString: configuration.clientTokenURLString, accessToken: accessToken, accept: "application/json, text/plain, */*", configuration: configuration, timeoutInterval: timeoutInterval)
    }

    public static func logoutURL(idToken: String, locale: String, configuration: JarvisOAuthConfiguration = .gfnPC) -> URL? {
        var components = URLComponents(string: configuration.logoutURLString)
        components?.queryItems = [
            URLQueryItem(name: "id_token_hint", value: idToken),
            URLQueryItem(name: "ui_locales", value: locale),
        ]
        return components?.url
    }

    private static func authenticatedGetRequest(urlString: String, accessToken: String, accept: String, configuration: JarvisOAuthConfiguration, timeoutInterval: TimeInterval) -> URLRequest? {
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

public enum JarvisSessionParser {
    public static func parseTokenResponse(_ json: [String: Any], now: Date = Date(), defaultIdpId: String = Jarvis.defaultIdpId) -> JarvisSession {
        var session = JarvisSession()
        session.accessToken = json["access_token"] as? String ?? ""
        session.idToken = json["id_token"] as? String ?? ""
        session.refreshToken = json["refresh_token"] as? String ?? ""
        session.clientToken = json["client_token"] as? String ?? ""
        let expiresIn = int64Value(json["expires_in"]) ?? 86400
        let nowMs = Int64(now.timeIntervalSince1970 * 1000.0)
        session.accessTokenExpiry = nowMs + expiresIn * 1000
        session.expiresAt = Int64(now.timeIntervalSince1970) + expiresIn

        if let clientTokenExpiresIn = int64Value(json["client_token_expires_in"]), clientTokenExpiresIn > 0, !session.clientToken.isEmpty {
            session.clientTokenExpiry = nowMs + clientTokenExpiresIn * 1000
            session.clientTokenExpiryLength = clientTokenExpiresIn * 1000
        }

        if !session.idToken.isEmpty {
            session.idTokenExpiry = idTokenExpiry(session.idToken)
            let claims = jwtClaims(session.idToken)
            session.userId = claims["sub"] as? String ?? ""
            session.displayName = claims["name"] as? String ?? (claims["preferred_username"] as? String ?? "")
            session.email = claims["email"] as? String ?? ""
            session.membershipTier = claims["membership_tier"] as? String ?? "Free"
            session.idpId = claims["idp_id"] as? String ?? ""
        }
        if !session.idToken.isEmpty, session.membershipTier.isEmpty { session.membershipTier = "Free" }
        if session.idpId.isEmpty { session.idpId = defaultIdpId }
        if session.expiresAt == 0 {
            session.expiresAt = Int64(now.timeIntervalSince1970) + 86400
            session.accessTokenExpiry = nowMs + 86_400_000
        }
        session.isAuthenticated = !session.accessToken.isEmpty
        return session
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
