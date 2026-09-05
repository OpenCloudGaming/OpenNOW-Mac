//  The authenticated session — what it holds, how it is parsed, and the actor that drives the
//  login, refresh and user-info calls.
//

import Foundation

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

    public var isClientTokenValid: Bool { !clientToken.isEmpty && clientTokenExpiry > Self.currentEpochMs() }
    public var isAccessTokenValid: Bool { !accessToken.isEmpty && accessTokenExpiry > Self.currentEpochMs() }
    public var isIdTokenValid: Bool { !idToken.isEmpty && (idTokenExpiry == 0 || idTokenExpiry > Self.currentEpochMs()) }

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

    let configuration: StarfleetOAuthConfiguration
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

    public nonisolated func createOAuthLoginRequest(deviceId: String, redirectURI: String, locale: String, oauthState: StarfleetOAuthState, providerIdpId: String, windowParameters: StarfleetOAuthWindowParameters = StarfleetOAuthWindowParameters(), useAppURL: Bool = false) throws -> StarfleetOAuthLoginRequest {
        guard let url = StarfleetOAuthRequestFactory.authorizationURL(configuration: configuration, deviceId: deviceId, redirectURI: redirectURI, locale: locale, oauthState: oauthState, providerIdpId: providerIdpId) else {
            throw StarfleetAuthError.invalidOAuthURL
        }
        return StarfleetOAuthLoginRequest(url: url, windowParameters: windowParameters, useAppURL: useAppURL, state: oauthState)
    }

    public nonisolated func parseCallback(query: String?, expectedState: String) throws -> StarfleetOAuthCallback {
        let parsed = StarfleetOAuthCallbackParser.parse(query: query)
        if !parsed.error.isEmpty || !parsed.errorDescription.isEmpty { throw StarfleetAuthError.oauthError(parsed.resolvedError) }
        guard parsed.state == expectedState else { throw StarfleetAuthError.stateMismatch }
        guard !parsed.code.isEmpty else { throw StarfleetAuthError.missingAuthorizationCode }
        return parsed
    }

    public func requestDeviceAuthorization(deviceId: String, displayName: String = "", providerIdpId: String = "") async throws -> StarfleetDeviceAuthorizationResponse {
        let body = StarfleetOAuthRequestFactory.deviceAuthorizeBody(deviceId: deviceId, displayName: displayName, providerIdpId: providerIdpId, configuration: configuration)
        guard let request = StarfleetOAuthRequestFactory.deviceAuthorizeRequest(body: body, configuration: configuration) else { throw StarfleetAuthError.invalidDeviceAuthorizeURL }
        return parseDeviceAuthorizationResponse(try await performJSONRequest(request))
    }

    public func exchangeDeviceCode(deviceCode: String) async throws -> StarfleetSession {
        guard !deviceCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StarfleetAuthError.missingDeviceCode }
        let span = telemetry.startSpan(name: "Starfleet_Get_Session_Token", attributes: ["grant_type": Starfleet.GrantType.deviceCode.rawValue])
        do {
            let body = StarfleetOAuthRequestFactory.deviceCodeTokenBody(deviceCode: deviceCode, configuration: configuration)
            var exchanged = try await requestDeviceCodeSession(body: body)
            if exchanged.idpId.isEmpty { exchanged.idpId = configuration.defaultIdpId }
            let enriched = try await ensureClientToken(exchanged)
            session = enriched
            telemetry.recordCounter(name: "starfleet.auth.device_code.count", attributes: ["outcome": "success"])
            span.finish(success: true)
            return enriched
        } catch {
            telemetry.recordError(error, attributes: ["phase": "device_code_exchange"])
            telemetry.recordCounter(name: "starfleet.auth.device_code.count", attributes: ["outcome": "failure"])
            span.finish(success: false)
            throw error
        }
    }

    public func pollDeviceAuthorization(deviceCode: String, interval: TimeInterval = 5, timeout: TimeInterval = 900) async throws -> StarfleetSession {
        let startedAt = Date()
        var delay = max(0, interval)
        while Date().timeIntervalSince(startedAt) < timeout {
            do {
                return try await exchangeDeviceCode(deviceCode: deviceCode)
            } catch StarfleetAuthError.deviceAuthorizationPending {
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            } catch StarfleetAuthError.deviceAuthorizationSlowDown {
                delay += 5
                if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            }
        }
        throw StarfleetAuthError.deviceAuthorizationExpired
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

    private func requestDeviceCodeSession(body: String) async throws -> StarfleetSession {
        guard let request = StarfleetOAuthRequestFactory.tokenRequest(body: body, configuration: configuration) else {
            throw StarfleetAuthError.invalidTokenURL
        }
        return StarfleetSessionParser.parseTokenResponse(try await performDeviceCodeJSONRequest(request), defaultIdpId: configuration.defaultIdpId)
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

        guard response.statusCode == 200 else {
            if retryPolicy.retryableHTTPStatuses.contains(response.statusCode) {
                throw StarfleetAuthError.httpStatus(response.statusCode)
            }
            throw starfleetOAuthError(data: data, statusCode: response.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StarfleetAuthError.invalidJSONResponse
        }
        return json
    }

    private func performDeviceCodeJSONRequest(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await transport.send(request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if response.statusCode == 200 {
            guard let json else { throw StarfleetAuthError.invalidJSONResponse }
            return json
        }
        let error = (json?["error"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch error {
        case "authorization_pending": throw StarfleetAuthError.deviceAuthorizationPending
        case "slow_down": throw StarfleetAuthError.deviceAuthorizationSlowDown
        case "expired_token": throw StarfleetAuthError.deviceAuthorizationExpired
        default:
            if !error.isEmpty { throw StarfleetAuthError.oauthError(json?["error_description"] as? String ?? error) }
            throw StarfleetAuthError.httpStatus(response.statusCode)
        }
    }

    private func parseDeviceAuthorizationResponse(_ json: [String: Any], issuedAt: Date = Date()) -> StarfleetDeviceAuthorizationResponse {
        StarfleetDeviceAuthorizationResponse(
            deviceCode: starfleetStringValue(json["device_code"]) ?? starfleetStringValue(json["deviceCode"]) ?? "",
            userCode: starfleetStringValue(json["user_code"]) ?? starfleetStringValue(json["userCode"]) ?? "",
            verificationURI: starfleetStringValue(json["verification_uri"]) ?? starfleetStringValue(json["verificationUri"]) ?? starfleetStringValue(json["verification_url"]) ?? "",
            verificationURIComplete: starfleetStringValue(json["verification_uri_complete"]) ?? starfleetStringValue(json["verificationUriComplete"]) ?? "",
            expiresIn: StarfleetTokenParser.int64Value(json["expires_in"] ?? json["expiresIn"]) ?? 0,
            interval: StarfleetTokenParser.int64Value(json["interval"]) ?? 5,
            issuedAt: issuedAt
        )
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

private func starfleetStringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

private func starfleetOAuthError(data: Data, statusCode: Int) -> StarfleetAuthError {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        return .httpStatus(statusCode)
    }
    let error = (json["error"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let description = (json["error_description"] as? String ?? json["errorDescription"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if !description.isEmpty { return .oauthError(description) }
    if !error.isEmpty { return .oauthError(error) }
    return .httpStatus(statusCode)
}
