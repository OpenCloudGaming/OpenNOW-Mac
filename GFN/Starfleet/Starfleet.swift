import Foundation

public enum Starfleet: Sendable {
    public static let systemName = "Starfleet"
    public static let loginBaseURLString = "https://login.nvidia.com"
    public static let clientId = "ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ"
    public static let defaultIdpId = "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg"
    public static let defaultOrigin = "https://nvfile"
    public static let defaultReferer = "https://nvfile/"
    public static let defaultUserAgent = GFNClientMetadata.nativeUserAgent
    public static let oauthScope = "openid consent email tk_client age"
}

public extension Starfleet {
    enum Endpoint: String, CaseIterable, Sendable {
        case authorize = "/authorize"
        case token = "/token"
        case deviceAuthorize = "/device/authorize"
        case userInfo = "/userinfo"
        case clientToken = "/client_token"
        case logout = "/logout"

        public var urlString: String { Starfleet.loginBaseURLString + rawValue }
    }

    enum GrantType: String, CaseIterable, Sendable {
        case authorizationCode = "authorization_code"
        case refreshToken = "refresh_token"
        case clientToken = "urn:ietf:params:oauth:grant-type:client_token"
        case deviceCode = "urn:ietf:params:oauth:grant-type:device_code"
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
    public let deviceAuthorizeURLString: String
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
        deviceAuthorizeURLString: String = Starfleet.Endpoint.deviceAuthorize.urlString,
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
        self.deviceAuthorizeURLString = deviceAuthorizeURLString
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

public struct StarfleetOAuthWindowParameters: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var left: Int
    public var top: Int
    public var resizable: Bool
    public var scrollbars: Bool

    public init(width: Int = 480, height: Int = 720, left: Int = 0, top: Int = 0, resizable: Bool = true, scrollbars: Bool = true) {
        self.width = width
        self.height = height
        self.left = left
        self.top = top
        self.resizable = resizable
        self.scrollbars = scrollbars
    }

    public var featureString: String {
        [
            "width=\(width)",
            "height=\(height)",
            "left=\(left)",
            "top=\(top)",
            "resizable=\(resizable ? "yes" : "no")",
            "scrollbars=\(scrollbars ? "yes" : "no")",
        ].joined(separator: ",")
    }
}

public struct StarfleetOAuthLoginRequest: Equatable, Sendable {
    public let url: URL
    public let popUpWindowName: String
    public let windowParameters: StarfleetOAuthWindowParameters
    public let useAppURL: Bool
    public let state: StarfleetOAuthState

    public init(url: URL, popUpWindowName: String = "app_oauth_window_with_back_button", windowParameters: StarfleetOAuthWindowParameters = StarfleetOAuthWindowParameters(), useAppURL: Bool = false, state: StarfleetOAuthState) {
        self.url = url
        self.popUpWindowName = popUpWindowName
        self.windowParameters = windowParameters
        self.useAppURL = useAppURL
        self.state = state
    }
}

public struct StarfleetOAuthCallback: Equatable, Sendable {
    public let code: String
    public let state: String
    public let error: String
    public let errorDescription: String

    public init(code: String = "", state: String = "", error: String = "", errorDescription: String = "") {
        self.code = code
        self.state = state
        self.error = error
        self.errorDescription = errorDescription
    }

    public var isSuccess: Bool { !code.isEmpty && error.isEmpty && errorDescription.isEmpty }
    public var resolvedError: String { errorDescription.isEmpty ? error : errorDescription }
}

public struct StarfleetDeviceAuthorizationResponse: Equatable, Sendable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: String
    public let verificationURIComplete: String
    public let expiresIn: Int64
    public let interval: Int64
    public let issuedAt: Date

    public init(deviceCode: String = "", userCode: String = "", verificationURI: String = "", verificationURIComplete: String = "", expiresIn: Int64 = 0, interval: Int64 = 5, issuedAt: Date = Date()) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval <= 0 ? 5 : interval
        self.issuedAt = issuedAt
    }

    public var expiresAt: Date { issuedAt.addingTimeInterval(TimeInterval(max(0, expiresIn))) }
    public var verificationURL: URL? { URL(string: verificationURIComplete.isEmpty ? verificationURI : verificationURIComplete) }
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

    public static func deviceAuthorizeBody(deviceId: String, displayName: String = "", providerIdpId: String = "", configuration: StarfleetOAuthConfiguration = .gfnPC) -> String {
        var items = [
            ("client_id", configuration.clientId),
            ("scope", configuration.scope),
            ("device_id", deviceId),
        ]
        if !displayName.isEmpty { items.append(("display_name", displayName)) }
        let idpId = providerIdpId.isEmpty ? configuration.defaultIdpId : providerIdpId
        if !idpId.isEmpty { items.append(("idp_id", idpId)) }
        return formBody(items)
    }

    public static func deviceCodeTokenBody(deviceCode: String, configuration: StarfleetOAuthConfiguration = .gfnPC) -> String {
        formBody([
            ("grant_type", Starfleet.GrantType.deviceCode.rawValue),
            ("device_code", deviceCode),
            ("client_id", configuration.clientId),
        ])
    }

    public static func deviceAuthorizeRequest(body: String, configuration: StarfleetOAuthConfiguration = .gfnPC, timeoutInterval: TimeInterval = 15) -> URLRequest? {
        guard let url = URL(string: configuration.deviceAuthorizeURLString) else { return nil }
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

    public static func logoutURL(idToken: String, locale: String, postLogoutRedirectURI: String = "", configuration: StarfleetOAuthConfiguration = .gfnPC) -> URL? {
        var components = URLComponents(string: configuration.logoutURLString)
        var queryItems = [
            URLQueryItem(name: "id_token_hint", value: idToken),
            URLQueryItem(name: "ui_locales", value: locale),
        ]
        if !postLogoutRedirectURI.isEmpty { queryItems.append(URLQueryItem(name: "post_logout_redirect_uri", value: postLogoutRedirectURI)) }
        components?.queryItems = queryItems
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

public enum StarfleetOAuthCallbackParser {
    public static func parse(query: String?) -> StarfleetOAuthCallback {
        let params = StarfleetTokenParser.parseQueryString(query)
        return StarfleetOAuthCallback(
            code: params["code"] ?? "",
            state: params["state"] ?? "",
            error: params["error"] ?? "",
            errorDescription: params["error_description"] ?? ""
        )
    }

    public static func parseCallbackPath(_ path: String) -> StarfleetOAuthCallback {
        let query = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
        return parse(query: query)
    }
}
