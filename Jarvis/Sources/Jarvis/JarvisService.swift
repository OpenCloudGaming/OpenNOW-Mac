import Foundation

public enum JarvisAuthStatus: String, CaseIterable, Sendable {
    case authorizationError = "AUTHORIZATION_ERROR"
    case unknown = "UNKNOWN"
    case loggedIn = "LOGGED_IN"
    case notLoggedIn = "NOT_LOGGED_IN"
    case pendingLogin = "PENDING_LOGIN"
}

public enum JarvisAuthType: String, CaseIterable, Sendable {
    case none = "NONE"
    case jwt = "JWT"
    case jwtGFN = "JWT_GFN"
    case jwtPartner = "JWT_PARTNER"
}

public protocol JarvisTelemetrySpan: Sendable {
    func setAttribute(_ key: String, value: String)
    func finish(success: Bool)
}

public protocol JarvisTelemetry: Sendable {
    func startSpan(name: String, operation: Jarvis.Operation?, attributes: [String: String]) -> JarvisTelemetrySpan
    func recordBreadcrumb(_ message: String, attributes: [String: String])
    func recordCounter(name: String, attributes: [String: String])
    func recordError(_ error: Error, operation: Jarvis.Operation?, attributes: [String: String])
}

public struct JarvisNoOpTelemetry: JarvisTelemetry {
    public init() {}

    public func startSpan(name: String, operation: Jarvis.Operation?, attributes: [String: String]) -> JarvisTelemetrySpan {
        _ = name
        _ = operation
        _ = attributes
        return JarvisNoOpTelemetrySpan()
    }

    public func recordBreadcrumb(_ message: String, attributes: [String: String]) {
        _ = message
        _ = attributes
    }

    public func recordCounter(name: String, attributes: [String: String]) {
        _ = name
        _ = attributes
    }

    public func recordError(_ error: Error, operation: Jarvis.Operation?, attributes: [String: String]) {
        _ = error
        _ = operation
        _ = attributes
    }
}

public struct JarvisNoOpTelemetrySpan: JarvisTelemetrySpan {
    public init() {}
    public func setAttribute(_ key: String, value: String) { _ = key; _ = value }
    public func finish(success: Bool) { _ = success }
}

public struct JarvisAuthToken: Equatable, Sendable {
    public let tokenType: JarvisAuthType
    public let token: String
    public let userId: String
    public let externalUserId: String
    public let idpId: String

    public init(tokenType: JarvisAuthType, token: String, userId: String = "", externalUserId: String = "", idpId: String = "") {
        self.tokenType = tokenType
        self.token = token
        self.userId = userId
        self.externalUserId = externalUserId
        self.idpId = idpId
    }
}

public struct JarvisUserInfo: Equatable, Sendable {
    public var userId: String
    public var externalId: String
    public var idpId: String
    public var idpName: String
    public var preferredUsername: String
    public var displayName: String
    public var email: String
    public var consent: [String: String]
    public var isAuthenticated: Bool
    public var isNetworkCall: Bool

    public init(
        userId: String = "",
        externalId: String = "",
        idpId: String = "",
        idpName: String = "",
        preferredUsername: String = "",
        displayName: String = "",
        email: String = "",
        consent: [String: String] = [:],
        isAuthenticated: Bool = false,
        isNetworkCall: Bool = false
    ) {
        self.userId = userId
        self.externalId = externalId
        self.idpId = idpId
        self.idpName = idpName
        self.preferredUsername = preferredUsername
        self.displayName = displayName
        self.email = email
        self.consent = consent
        self.isAuthenticated = isAuthenticated
        self.isNetworkCall = isNetworkCall
    }
}

public struct JarvisConsentBlock: Equatable, Sendable {
    public var userId: String
    public var externalUserId: String
    public var idpId: String
    public var userConsent: [String: String]

    public init(userId: String = "", externalUserId: String = "", idpId: String = "", userConsent: [String: String] = [:]) {
        self.userId = userId
        self.externalUserId = externalUserId
        self.idpId = idpId
        self.userConsent = userConsent
    }
}

public struct JarvisOAuthWindowParameters: Equatable, Sendable {
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

public struct JarvisOAuthLoginRequest: Equatable, Sendable {
    public let url: URL
    public let popUpWindowName: String
    public let windowParameters: JarvisOAuthWindowParameters
    public let useAppURL: Bool
    public let state: JarvisOAuthState

    public init(url: URL, popUpWindowName: String = "app_oauth_window_with_back_button", windowParameters: JarvisOAuthWindowParameters = JarvisOAuthWindowParameters(), useAppURL: Bool = false, state: JarvisOAuthState) {
        self.url = url
        self.popUpWindowName = popUpWindowName
        self.windowParameters = windowParameters
        self.useAppURL = useAppURL
        self.state = state
    }
}

public struct JarvisOAuthCallback: Equatable, Sendable {
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

public struct JarvisOperationRequest: Equatable, Sendable {
    public let operation: Jarvis.Operation
    public let parameters: [String: String]

    public init(operation: Jarvis.Operation, parameters: [String: String] = [:]) {
        self.operation = operation
        self.parameters = parameters
    }
}

public enum JarvisOperationFactory {
    public static func chainSession(sessionId: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .chainSession, parameters: ["sessionId": sessionId])
    }

    public static func getDelegateToken(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getDelegateToken, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func getLoginToken(email: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getLoginToken, parameters: email.isEmpty ? [:] : ["email": email])
    }

    public static func getSessionToken(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getSessionToken, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func getThirdPartyProviderInfo(idpId: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getThirdPartyProviderInfo, parameters: ["idpId": idpId])
    }

    public static func getUserInfo(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getUserInfo, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func getUserToken(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getUserToken, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func redeemDelegateToken(delegateToken: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .redeemDelegateToken, parameters: ["delegateToken": delegateToken])
    }

    public static func requestEmailVerify(email: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .requestEmailVerify, parameters: ["email": email])
    }

    public static func getPin(userId: String = "") -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .getPin, parameters: userId.isEmpty ? [:] : ["userId": userId])
    }

    public static func setPin(pin: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .setPin, parameters: ["pin": pin])
    }

    public static func verifyPin(pin: String) -> JarvisOperationRequest {
        JarvisOperationRequest(operation: .verifyPin, parameters: ["pin": pin])
    }
}

public protocol JarvisHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct JarvisURLSessionTransport: JarvisHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JarvisAuthError.invalidHTTPResponse
        }
        return (data, httpResponse)
    }
}

public enum JarvisAuthError: LocalizedError, Equatable, Sendable {
    case invalidOAuthURL
    case invalidTokenURL
    case invalidUserInfoURL
    case invalidClientTokenURL
    case invalidCallbackRequest
    case oauthError(String)
    case stateMismatch
    case missingAuthorizationCode
    case noSavedSession
    case noRefreshMechanism
    case invalidHTTPResponse
    case httpStatus(Int)
    case invalidJSONResponse
    case missingClientToken
    case missingAccessToken

    public var errorDescription: String? {
        switch self {
        case .invalidOAuthURL: "Invalid OAuth URL"
        case .invalidTokenURL: "Invalid token URL"
        case .invalidUserInfoURL: "Invalid userinfo URL"
        case .invalidClientTokenURL: "Invalid client token URL"
        case .invalidCallbackRequest: "Invalid OAuth callback request"
        case .oauthError(let message): message
        case .stateMismatch: "State mismatch"
        case .missingAuthorizationCode: "Missing authorization code"
        case .noSavedSession: "No saved session available"
        case .noRefreshMechanism: "No refresh mechanism available"
        case .invalidHTTPResponse: "Invalid HTTP response"
        case .httpStatus(let status): "HTTP \(status)"
        case .invalidJSONResponse: "Invalid JSON response"
        case .missingClientToken: "No client_token in response"
        case .missingAccessToken: "Missing access token"
        }
    }
}

public actor JarvisAuthService<Transport: JarvisHTTPTransport> {
    public private(set) var session: JarvisSession
    public private(set) var cachedUser: JarvisUserInfo
    public private(set) var status: JarvisAuthStatus

    private let configuration: JarvisOAuthConfiguration
    private let refreshPolicy: JarvisClientTokenRefreshPolicy
    private let transport: Transport
    private let telemetry: JarvisTelemetry
    private var isSessionRefreshable: Bool

    public init(
        configuration: JarvisOAuthConfiguration = .gfnPC,
        refreshPolicy: JarvisClientTokenRefreshPolicy = .gfnPC,
        transport: Transport,
        telemetry: JarvisTelemetry = JarvisNoOpTelemetry(),
        session: JarvisSession = JarvisSession()
    ) {
        self.configuration = configuration
        self.refreshPolicy = refreshPolicy
        self.transport = transport
        self.telemetry = telemetry
        self.session = session
        self.cachedUser = JarvisUserInfo()
        self.status = session.isAuthenticated ? .loggedIn : .notLoggedIn
        self.isSessionRefreshable = true
    }

    public func setSession(_ session: JarvisSession) {
        self.session = session
        self.status = session.isAuthenticated ? .loggedIn : .notLoggedIn
    }

    public func clearSession() {
        session = JarvisSession()
        cachedUser = JarvisUserInfo()
        status = .notLoggedIn
        isSessionRefreshable = true
        telemetry.recordBreadcrumb("Jarvis session cleared", attributes: ["status": status.rawValue])
    }

    public func createOAuthLoginRequest(deviceId: String, redirectURI: String, locale: String, oauthState: JarvisOAuthState, providerIdpId: String, windowParameters: JarvisOAuthWindowParameters = JarvisOAuthWindowParameters(), useAppURL: Bool = false) throws -> JarvisOAuthLoginRequest {
        let span = telemetry.startSpan(name: Jarvis.oauthSpanName, operation: .getLoginToken, attributes: ["provider_idp_id": providerIdpId.isEmpty ? configuration.defaultIdpId : providerIdpId])
        guard let url = JarvisOAuthRequestFactory.authorizationURL(configuration: configuration, deviceId: deviceId, redirectURI: redirectURI, locale: locale, oauthState: oauthState, providerIdpId: providerIdpId) else {
            telemetry.recordError(JarvisAuthError.invalidOAuthURL, operation: .getLoginToken, attributes: [:])
            span.finish(success: false)
            throw JarvisAuthError.invalidOAuthURL
        }
        telemetry.recordBreadcrumb("Jarvis OAuth login URL created", attributes: ["provider_idp_id": providerIdpId.isEmpty ? configuration.defaultIdpId : providerIdpId])
        span.finish(success: true)
        return JarvisOAuthLoginRequest(url: url, windowParameters: windowParameters, useAppURL: useAppURL, state: oauthState)
    }

    public func exchangeAuthorizationCode(authCode: String, redirectURI: String, codeVerifier: String, providerIdpId: String = "") async throws -> JarvisSession {
        let span = telemetry.startSpan(name: Jarvis.Operation.getSessionToken.rawValue, operation: .getSessionToken, attributes: ["grant_type": "authorization_code"])
        do {
            let body = JarvisOAuthRequestFactory.authorizationCodeTokenBody(authCode: authCode, redirectURI: redirectURI, codeVerifier: codeVerifier)
            var exchanged = try await requestSession(body: body, operation: .getSessionToken)
            if !providerIdpId.isEmpty { exchanged.idpId = providerIdpId }
            let enriched = try await ensureClientToken(exchanged)
            session = enriched
            status = enriched.isAuthenticated ? .loggedIn : .notLoggedIn
            telemetry.recordCounter(name: "jarvis.auth.exchange.count", attributes: ["outcome": "success"])
            span.finish(success: true)
            return enriched
        } catch {
            telemetry.recordError(error, operation: .getSessionToken, attributes: ["phase": "authorization_code_exchange"])
            telemetry.recordCounter(name: "jarvis.auth.exchange.count", attributes: ["outcome": "failure"])
            span.finish(success: false)
            throw error
        }
    }

    public func refreshSession(force: Bool = false) async throws -> JarvisSession {
        let span = telemetry.startSpan(name: Jarvis.Operation.getSessionToken.rawValue, operation: .getSessionToken, attributes: ["force": force ? "true" : "false"])
        do {
            guard session.isAuthenticated else { throw JarvisAuthError.noSavedSession }
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
            guard isSessionRefreshable else { throw JarvisAuthError.noRefreshMechanism }
            if !session.clientToken.isEmpty {
                let body = JarvisOAuthRequestFactory.clientTokenGrantBody(clientToken: session.clientToken, userId: session.userId, configuration: configuration)
                let refreshed = merge(saved: session, refreshed: try await requestSession(body: body, operation: .getSessionToken))
                let enriched = try await ensureClientToken(refreshed)
                session = enriched
                status = enriched.isAuthenticated ? .loggedIn : .notLoggedIn
                telemetry.recordCounter(name: "jarvis.auth.refresh.count", attributes: ["outcome": "success", "grant_type": "client_token"])
                span.finish(success: true)
                return enriched
            }
            let refreshed = try await refreshWithOAuthToken()
            telemetry.recordCounter(name: "jarvis.auth.refresh.count", attributes: ["outcome": "success", "grant_type": "refresh_token"])
            span.finish(success: true)
            return refreshed
        } catch {
            telemetry.recordError(error, operation: .getSessionToken, attributes: ["phase": "session_refresh"])
            telemetry.recordCounter(name: "jarvis.auth.refresh.count", attributes: ["outcome": "failure"])
            span.finish(success: false)
            throw error
        }
    }

    public func getAuthToken(forceRefresh: Bool = false) async throws -> JarvisAuthToken {
        let span = telemetry.startSpan(name: Jarvis.Operation.getUserToken.rawValue, operation: .getUserToken, attributes: ["force_refresh": forceRefresh ? "true" : "false"])
        do {
            let refreshed = try await refreshSession(force: forceRefresh)
            guard !refreshed.accessToken.isEmpty else { throw JarvisAuthError.missingAccessToken }
            span.finish(success: true)
            return JarvisAuthToken(tokenType: .jwtGFN, token: refreshed.accessToken, userId: refreshed.userId, externalUserId: refreshed.userId, idpId: refreshed.idpId)
        } catch {
            telemetry.recordError(error, operation: .getUserToken, attributes: [:])
            span.finish(success: false)
            throw error
        }
    }

    public func getCurrentUser(forceRefresh: Bool = false) async throws -> JarvisUserInfo {
        let span = telemetry.startSpan(name: Jarvis.Operation.getUserInfo.rawValue, operation: .getUserInfo, attributes: ["force_refresh": forceRefresh ? "true" : "false"])
        do {
            let refreshed = try await refreshSession(force: forceRefresh)
            if !forceRefresh, cachedUser.isAuthenticated, cachedUser.userId == refreshed.userId {
                span.setAttribute("cache", value: "hit")
                span.finish(success: true)
                return cachedUser
            }
            let user = try await fetchUserInfo(accessToken: refreshed.accessToken, isNetworkCall: true)
            cachedUser = user
            span.setAttribute("cache", value: "miss")
            span.finish(success: true)
            return user
        } catch {
            telemetry.recordError(error, operation: .getUserInfo, attributes: [:])
            span.finish(success: false)
            throw error
        }
    }

    public func fetchUserInfo(accessToken: String, isNetworkCall: Bool = true) async throws -> JarvisUserInfo {
        let span = telemetry.startSpan(name: Jarvis.Operation.getUserInfo.rawValue, operation: .getUserInfo, attributes: ["network_call": isNetworkCall ? "true" : "false"])
        guard let request = JarvisOAuthRequestFactory.userInfoRequest(accessToken: accessToken, configuration: configuration) else {
            telemetry.recordError(JarvisAuthError.invalidUserInfoURL, operation: .getUserInfo, attributes: [:])
            span.finish(success: false)
            throw JarvisAuthError.invalidUserInfoURL
        }
        do {
            let json = try await performJSONRequest(request, operation: .getUserInfo)
            span.finish(success: true)
            return parseUserInfo(json, isNetworkCall: isNetworkCall)
        } catch {
            telemetry.recordError(error, operation: .getUserInfo, attributes: [:])
            span.finish(success: false)
            throw error
        }
    }

    public func fetchClientToken(accessToken: String) async throws -> (clientToken: String, expiresIn: String) {
        let span = telemetry.startSpan(name: "Get_Client_Token", operation: .getSessionToken, attributes: [:])
        guard let request = JarvisOAuthRequestFactory.clientTokenRequest(accessToken: accessToken, configuration: configuration) else {
            telemetry.recordError(JarvisAuthError.invalidClientTokenURL, operation: .getSessionToken, attributes: [:])
            span.finish(success: false)
            throw JarvisAuthError.invalidClientTokenURL
        }
        let json = try await performJSONRequest(request, operation: .getSessionToken)
        let clientToken = json["client_token"] as? String ?? ""
        guard !clientToken.isEmpty else {
            telemetry.recordError(JarvisAuthError.missingClientToken, operation: .getSessionToken, attributes: [:])
            span.finish(success: false)
            throw JarvisAuthError.missingClientToken
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.stringValue ?? (json["expires_in"] as? String ?? "")
        span.finish(success: true)
        return (clientToken, expiresIn)
    }

    public func createSessionFromIdToken(_ idToken: String, validForSeconds: Int64 = 172_800) -> JarvisSession {
        let claims = JarvisSessionParser.jwtClaims(idToken)
        let nowMs = JarvisSession.currentEpochMs()
        var created = JarvisSession()
        created.accessToken = "This is required for the session object to validate, but is not used"
        created.clientToken = "This is required for the session object to validate, but is not used"
        created.idToken = idToken
        created.userId = claims["sub"] as? String ?? ""
        created.displayName = claims["name"] as? String ?? (claims["preferred_username"] as? String ?? "")
        created.email = claims["email"] as? String ?? ""
        created.idpId = claims["idp_id"] as? String ?? Jarvis.defaultIdpId
        created.idTokenExpiry = JarvisSessionParser.idTokenExpiry(idToken)
        created.accessTokenExpiry = nowMs + validForSeconds * 1000
        created.clientTokenExpiry = nowMs + validForSeconds * 1000
        created.clientTokenExpiryLength = validForSeconds * 1000
        created.expiresAt = Int64(Date().timeIntervalSince1970) + validForSeconds
        created.isAuthenticated = true
        isSessionRefreshable = false
        session = created
        status = .loggedIn
        return created
    }

    public func sameTabAuthStarted() -> JarvisAuthStatus {
        status = .pendingLogin
        telemetry.recordBreadcrumb("Jarvis same-tab auth started", attributes: ["status": status.rawValue])
        return status
    }

    public func finishLogin(success: Bool) -> JarvisAuthStatus {
        status = success ? .loggedIn : .authorizationError
        telemetry.recordCounter(name: "jarvis.auth.login.count", attributes: ["outcome": success ? "success" : "failure"])
        return status
    }

    public func createConsentBlock(userInfo: JarvisUserInfo? = nil) -> JarvisConsentBlock {
        let user = userInfo ?? cachedUser
        return JarvisConsentBlock(userId: user.userId, externalUserId: user.externalId, idpId: user.idpId, userConsent: user.consent)
    }

    public func parseCallback(query: String?, expectedState: String) throws -> JarvisOAuthCallback {
        let parsed = JarvisOAuthCallbackParser.parse(query: query)
        telemetry.recordBreadcrumb("Jarvis OAuth callback captured", attributes: ["has_code": parsed.code.isEmpty ? "false" : "true", "has_error": parsed.resolvedError.isEmpty ? "false" : "true"])
        if !parsed.error.isEmpty || !parsed.errorDescription.isEmpty {
            let error = JarvisAuthError.oauthError(parsed.resolvedError)
            telemetry.recordError(error, operation: .getLoginToken, attributes: ["phase": "callback"])
            throw error
        }
        guard parsed.state == expectedState else {
            telemetry.recordError(JarvisAuthError.stateMismatch, operation: .getLoginToken, attributes: ["phase": "callback"])
            throw JarvisAuthError.stateMismatch
        }
        guard !parsed.code.isEmpty else {
            telemetry.recordError(JarvisAuthError.missingAuthorizationCode, operation: .getLoginToken, attributes: ["phase": "callback"])
            throw JarvisAuthError.missingAuthorizationCode
        }
        return parsed
    }

    private func refreshWithOAuthToken() async throws -> JarvisSession {
        guard !session.refreshToken.isEmpty else {
            if session.isAccessTokenValid { return try await ensureClientToken(session) }
            throw JarvisAuthError.noRefreshMechanism
        }
        let body = JarvisOAuthRequestFactory.refreshTokenBody(refreshToken: session.refreshToken, configuration: configuration)
        let refreshed = merge(saved: session, refreshed: try await requestSession(body: body, operation: .getSessionToken))
        let enriched = try await ensureClientToken(refreshed)
        session = enriched
        status = enriched.isAuthenticated ? .loggedIn : .notLoggedIn
        return enriched
    }

    private func requestSession(body: String, operation: Jarvis.Operation) async throws -> JarvisSession {
        guard let request = JarvisOAuthRequestFactory.tokenRequest(body: body, configuration: configuration) else {
            telemetry.recordError(JarvisAuthError.invalidTokenURL, operation: operation, attributes: [:])
            throw JarvisAuthError.invalidTokenURL
        }
        let json = try await performJSONRequest(request, operation: operation)
        return JarvisSessionParser.parseTokenResponse(json, defaultIdpId: configuration.defaultIdpId)
    }

    private func ensureClientToken(_ current: JarvisSession) async throws -> JarvisSession {
        guard current.isAuthenticated, current.isAccessTokenValid, shouldRefreshClientToken(current) else { return current }
        let result = try await fetchClientToken(accessToken: current.accessToken)
        var enriched = current
        let parsedExpiresIn = Int64(result.expiresIn) ?? 0
        let expiresIn = parsedExpiresIn > 0 ? parsedExpiresIn : 86400
        enriched.clientToken = result.clientToken
        enriched.clientTokenExpiry = JarvisSession.currentEpochMs() + expiresIn * 1000
        enriched.clientTokenExpiryLength = expiresIn * 1000
        return enriched
    }

    private func shouldRefreshClientToken(_ current: JarvisSession) -> Bool {
        refreshPolicy.shouldRefresh(clientToken: current.clientToken, clientTokenExpiry: current.clientTokenExpiry, clientTokenExpiryLength: current.clientTokenExpiryLength, currentEpochMs: JarvisSession.currentEpochMs())
    }

    private func merge(saved: JarvisSession, refreshed: JarvisSession) -> JarvisSession {
        var merged = refreshed
        if merged.refreshToken.isEmpty { merged.refreshToken = saved.refreshToken }
        if merged.clientToken.isEmpty {
            merged.clientToken = saved.clientToken
            merged.clientTokenExpiry = saved.clientTokenExpiry
            merged.clientTokenExpiryLength = saved.clientTokenExpiryLength
        }
        if merged.email.isEmpty { merged.email = saved.email }
        if merged.displayName.isEmpty { merged.displayName = saved.displayName }
        if merged.membershipTier.isEmpty { merged.membershipTier = saved.membershipTier }
        if merged.userId.isEmpty { merged.userId = saved.userId }
        if merged.idpId.isEmpty { merged.idpId = saved.idpId }
        return merged
    }

    private func performJSONRequest(_ request: URLRequest, operation: Jarvis.Operation?) async throws -> [String: Any] {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            let error = JarvisAuthError.httpStatus(response.statusCode)
            telemetry.recordError(error, operation: operation, attributes: ["status_code": String(response.statusCode)])
            throw error
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            telemetry.recordError(JarvisAuthError.invalidJSONResponse, operation: operation, attributes: [:])
            throw JarvisAuthError.invalidJSONResponse
        }
        return json
    }

    private func parseUserInfo(_ json: [String: Any], isNetworkCall: Bool) -> JarvisUserInfo {
        let consent = json["consent"] as? [String: String] ?? [:]
        let userId = json["sub"] as? String ?? (json["userId"] as? String ?? "")
        let displayName = json["name"] as? String ?? (json["preferred_username"] as? String ?? "")
        return JarvisUserInfo(
            userId: userId,
            externalId: json["external_id"] as? String ?? (json["externalId"] as? String ?? ""),
            idpId: json["idp_id"] as? String ?? (json["idpId"] as? String ?? Jarvis.defaultIdpId),
            idpName: json["idp_name"] as? String ?? "",
            preferredUsername: json["preferred_username"] as? String ?? "",
            displayName: displayName,
            email: json["email"] as? String ?? "",
            consent: consent,
            isAuthenticated: !userId.isEmpty || !displayName.isEmpty,
            isNetworkCall: isNetworkCall
        )
    }
}

public enum JarvisOAuthCallbackParser {
    public static func parse(query: String?) -> JarvisOAuthCallback {
        let params = JarvisSessionParser.parseQueryString(query)
        return JarvisOAuthCallback(
            code: params["code"] ?? "",
            state: params["state"] ?? "",
            error: params["error"] ?? "",
            errorDescription: params["error_description"] ?? ""
        )
    }

    public static func parseCallbackPath(_ path: String) -> JarvisOAuthCallback {
        let query = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
        return parse(query: query)
    }
}
