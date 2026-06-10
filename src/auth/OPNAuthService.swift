import AppKit
import CryptoKit
import Darwin
import Foundation

typealias OPNAuthCallback = @Sendable (_ success: Bool, _ session: OPNAuthSession, _ error: String) -> Void
typealias OPNSimpleCallback = @Sendable (_ success: Bool, _ error: String) -> Void

final class OPNAuthService: @unchecked Sendable {
    static let shared = OPNAuthService()

    static let oAuthAuthorizeURL = "https://login.nvidia.com/authorize"
    static let oAuthTokenURL = "https://login.nvidia.com/token"
    static let oAuthClientId = "ZU7sPN-miLujMD95LfOQ453IB0AtjM8sMyvgJ9wCXEQ"
    static let oAuthRedirectURI = "com.nvidia.geforcenow://oauth/callback"
    static let oAuthScope = "openid consent email tk_client age"
    static let defaultIdpId = "PDiAhv2kJTFeQ7WOPqiQ2tRZ7lGhR2X11dXvM4TZSxg"
    static let defaultUserAgent = "NVIDIACEFClient/HEAD/debb5919f6 GFN-PC/2.0.80.173"
    static let oAuthLogoutURL = "https://login.nvidia.com/logout"

    private static let clientTokenRefreshWindowMs: Int64 = 5 * 60 * 1000
    private static let clientTokenRefreshWindowPercent: Int64 = 20
    private static let uuidLock = NSLock()
    nonisolated(unsafe) private static var cachedUUID = ""

    private init() {}

    func startOAuthLogin(completion: @escaping OPNAuthCallback) {
        startOAuthLogin(providerIdpId: Self.defaultIdpId, completion: completion)
    }

    func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback) {
        let port = findAvailablePort()
        guard port > 0 else {
            DispatchQueue.main.async { completion(false, OPNAuthSession(), "No available port for OAuth callback") }
            return
        }

        let pkce = generatePKCEState()
        let deviceId = generateOpenNOWDeviceId()
        let nonce = generateRandomString(length: 32)
        let redirectUri = "http://localhost:\(port)"
        let selectedProviderIdpId = providerIdpId.isEmpty ? Self.defaultIdpId : providerIdpId
        let locale = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")

        var components = URLComponents(string: Self.oAuthAuthorizeURL)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "device_id", value: deviceId),
            URLQueryItem(name: "scope", value: Self.oAuthScope),
            URLQueryItem(name: "client_id", value: Self.oAuthClientId),
            URLQueryItem(name: "redirect_uri", value: redirectUri),
            URLQueryItem(name: "ui_locales", value: locale),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "prompt", value: "select_account"),
            URLQueryItem(name: "code_challenge", value: pkce.codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "idp_id", value: selectedProviderIdpId),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        guard let authURL = components?.url else {
            DispatchQueue.main.async { completion(false, OPNAuthSession(), "Invalid OAuth authorize URL") }
            return
        }

        startOAuthCallbackListener(port: port, expectedState: pkce.state) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let code):
                self.doOAuthTokenExchange(
                    authCode: code,
                    codeVerifier: pkce.codeVerifier,
                    redirectUri: redirectUri,
                    providerIdpId: selectedProviderIdpId,
                    completion: completion
                )
            case .failure(let error):
                DispatchQueue.main.async { completion(false, OPNAuthSession(), error.localizedDescription) }
            }
        }

        NSWorkspace.shared.open(authURL)
    }

    func refreshSession(completion: @escaping OPNAuthCallback, forceRefresh: Bool = false) {
        let session = loadSavedSession()
        guard session.isAuthenticated else {
            completion(false, OPNAuthSession(), "No saved session available")
            return
        }

        if !forceRefresh && session.isAccessTokenValid {
            if shouldRefreshClientToken(session) {
                completeRefreshWithSession(session, completion: completion)
            } else {
                completion(true, session, "")
            }
            return
        }

        let savedSession = session
        let refreshWithOAuthToken: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            if savedSession.refreshToken.isEmpty {
                if savedSession.isAccessTokenValid {
                    self.completeRefreshWithSession(savedSession, completion: completion)
                } else {
                    completion(false, savedSession, "No refresh mechanism available")
                }
                return
            }

            let body = "grant_type=refresh_token&refresh_token=\(self.formURLEncode(savedSession.refreshToken))&client_id=\(self.formURLEncode(Self.oAuthClientId))"
            self.performTokenRequest(body: body) { result in
                switch result {
                case .success(let json):
                    let refreshed = self.mergeRefreshedSession(saved: savedSession, refreshed: Self.parseOAuthSession(json: json))
                    self.completeRefreshWithSession(refreshed, completion: completion)
                case .failure(let error):
                    completion(false, savedSession, error.localizedDescription)
                }
            }
        }

        guard !session.clientToken.isEmpty else {
            refreshWithOAuthToken()
            return
        }

        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Aclient_token&client_token=\(formURLEncode(session.clientToken))&client_id=\(formURLEncode(Self.oAuthClientId))&sub=\(formURLEncode(session.userId))"
        performTokenRequest(body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let json):
                let refreshed = self.mergeRefreshedSession(saved: savedSession, refreshed: Self.parseOAuthSession(json: json))
                self.completeRefreshWithSession(refreshed, completion: completion)
            case .failure:
                refreshWithOAuthToken()
            }
        }
    }

    func fetchStarFleetUserInfo(accessToken: String, completion: @escaping @Sendable (Bool, NSDictionary?, String) -> Void) {
        guard let url = URL(string: "https://login.nvidia.com/userinfo") else {
            completion(false, nil, "Invalid userinfo URL")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://nvfile", forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        performJSONRequest(request) { result in
            switch result {
            case .success(let json): completion(true, json, "")
            case .failure(let error): completion(false, nil, error.localizedDescription)
            }
        }
    }

    func fetchClientToken(accessToken: String, completion: @escaping @Sendable (Bool, String, String) -> Void) {
        guard let url = URL(string: "https://login.nvidia.com/client_token") else {
            completion(false, "", "Invalid client token URL")
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("https://nvfile", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        performJSONRequest(request) { result in
            switch result {
            case .success(let json):
                let clientToken = json["client_token"] as? String ?? ""
                let expiresIn = (json["expires_in"] as? NSNumber)?.stringValue ?? (json["expires_in"] as? String ?? "")
                if clientToken.isEmpty {
                    completion(false, "", "No client_token in response")
                } else {
                    completion(true, clientToken, expiresIn)
                }
            case .failure(let error):
                completion(false, "", error.localizedDescription)
            }
        }
    }

    func serverLogout(idToken: String, locale: String, completion: @escaping OPNSimpleCallback) {
        guard !idToken.isEmpty else {
            clearSession()
            completion(true, "")
            return
        }
        let resolvedLocale = locale.isEmpty ? Locale.current.identifier.replacingOccurrences(of: "-", with: "_") : locale
        let urlString = "\(Self.oAuthLogoutURL)?id_token_hint=\(urlEncode(idToken))&ui_locales=\(urlEncode(resolvedLocale))"
        guard let url = URL(string: urlString) else {
            clearSession()
            completion(false, "Invalid logout URL")
            return
        }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 10)) { _, _, error in
            DispatchQueue.main.async {
                self.clearSession()
                if let error {
                    completion(false, error.localizedDescription)
                } else {
                    completion(true, "")
                }
            }
        }.resume()
    }

    static func getPersistentDeviceUUID() -> String {
        uuidLock.lock()
        defer { uuidLock.unlock() }
        if !cachedUUID.isEmpty { return cachedUUID }

        let key = "OPN_PersistentDeviceUUID"
        let legacyKey = "GFN_PersistentDeviceUUID"
        let defaults = authUserDefaults()
        if let stored = defaults.string(forKey: key), !stored.isEmpty {
            cachedUUID = stored
            return stored
        }
        if let legacy = defaults.string(forKey: legacyKey), !legacy.isEmpty {
            defaults.set(legacy, forKey: key)
            defaults.synchronize()
            cachedUUID = legacy
            return legacy
        }
        let uuid = UUID().uuidString
        defaults.set(uuid, forKey: key)
        defaults.synchronize()
        cachedUUID = uuid
        return uuid
    }

    func saveSession(_ session: OPNAuthSession) {
        guard session.isAuthenticated, !session.accessToken.isEmpty else { return }
        guard let identity = sessionIdentity(from: session), !identity.isEmpty else { return }

        let existing = loadAccountDictionaries(activeUserId: nil)
        var accounts = existing.filter { sessionIdentity(from: $0) != identity }
        accounts.insert(dictionary(from: session), at: 0)
        saveAccountDictionaries(accounts, activeUserId: identity)

        let defaults = Self.authUserDefaults()
        defaults.set(true, forKey: "OPN_HasSavedSession")
        defaults.set(identity, forKey: "OPN_ActiveUserId")
        defaults.synchronize()
    }

    func loadSavedSession() -> OPNAuthSession {
        let defaults = Self.authUserDefaults()
        var activeUserId: String?
        let accounts = loadAccountDictionaries(activeUserId: &activeUserId)
        let preferredUserId = defaults.string(forKey: "OPN_ActiveUserId") ?? activeUserId
        var fallback: NSDictionary?

        for account in accounts {
            if fallback == nil { fallback = account }
            let identity = sessionIdentity(from: account)
            if preferredUserId?.isEmpty == false, identity == preferredUserId {
                let session = session(from: account)
                if session.isAuthenticated { return session }
            }
        }

        if let fallback {
            let session = session(from: fallback)
            if let identity = sessionIdentity(from: fallback), !identity.isEmpty {
                defaults.set(identity, forKey: "OPN_ActiveUserId")
            }
            defaults.set(true, forKey: "OPN_HasSavedSession")
            defaults.synchronize()
            return session
        }

        if !defaults.bool(forKey: "OPN_HasSavedSession") && !defaults.bool(forKey: "GFN_HasSavedSession") {
            return OPNAuthSession()
        }
        let legacy = loadLegacySingleSession()
        if legacy.isAuthenticated { saveSession(legacy) }
        return legacy
    }

    func loadSavedSessions() -> [OPNAuthSession] {
        var sessions = loadAccountDictionaries(activeUserId: nil).map(session).filter(\.isAuthenticated)
        if sessions.isEmpty {
            let legacy = loadLegacySingleSession()
            if legacy.isAuthenticated { sessions.append(legacy) }
        }
        return sessions
    }

    func loadSavedSession(forUserId userId: String) -> OPNAuthSession {
        guard !userId.isEmpty else { return OPNAuthSession() }
        for account in loadAccountDictionaries(activeUserId: nil) {
            if sessionIdentity(from: account) == userId {
                return session(from: account)
            }
        }
        return OPNAuthSession()
    }

    func setActiveSessionUserId(_ userId: String) {
        guard !userId.isEmpty else { return }
        var activeUserId: String?
        let accounts = loadAccountDictionaries(activeUserId: &activeUserId)
        guard accounts.contains(where: { sessionIdentity(from: $0) == userId }) else { return }
        saveAccountDictionaries(accounts, activeUserId: userId)
        let defaults = Self.authUserDefaults()
        defaults.set(userId, forKey: "OPN_ActiveUserId")
        defaults.set(true, forKey: "OPN_HasSavedSession")
        defaults.synchronize()
    }

    func removeSavedSession(userId: String) {
        guard !userId.isEmpty else { return }
        var activeUserId: String?
        let existing = loadAccountDictionaries(activeUserId: &activeUserId)
        let accounts = existing.filter { sessionIdentity(from: $0) != userId }
        let newActive = activeUserId == userId ? accounts.compactMap(sessionIdentity).first : activeUserId
        saveAccountDictionaries(accounts, activeUserId: newActive)
        let defaults = Self.authUserDefaults()
        if let newActive, !newActive.isEmpty {
            defaults.set(newActive, forKey: "OPN_ActiveUserId")
            defaults.set(true, forKey: "OPN_HasSavedSession")
        } else {
            defaults.removeObject(forKey: "OPN_ActiveUserId")
            defaults.removeObject(forKey: "OPN_HasSavedSession")
        }
        defaults.synchronize()
    }

    func clearSession() {
        let defaults = Self.authUserDefaults()
        if let activeUserId = defaults.string(forKey: "OPN_ActiveUserId"), !activeUserId.isEmpty {
            removeSavedSession(userId: activeUserId)
            return
        }
        [accountsFilePath(), sessionFilePath(), legacySessionFilePath()].forEach { path in
            if let path { try? FileManager.default.removeItem(atPath: path) }
        }
        defaults.removeObject(forKey: "OPN_HasSavedSession")
        defaults.removeObject(forKey: "GFN_HasSavedSession")
        defaults.removeObject(forKey: "OPN_ActiveUserId")
        defaults.synchronize()
    }

    func getStayLoggedIn() -> Bool {
        let defaults = Self.authUserDefaults()
        if defaults.object(forKey: "OPN_StayLoggedIn") != nil { return defaults.bool(forKey: "OPN_StayLoggedIn") }
        if defaults.object(forKey: "GFN_StayLoggedIn") != nil { return defaults.bool(forKey: "GFN_StayLoggedIn") }
        return true
    }

    func setStayLoggedIn(_ value: Bool) {
        let defaults = Self.authUserDefaults()
        defaults.set(value, forKey: "OPN_StayLoggedIn")
        defaults.synchronize()
    }

    static func parseOAuthSession(json: NSDictionary) -> OPNAuthSession {
        var session = OPNAuthSession()
        session.accessToken = json["access_token"] as? String ?? ""
        session.idToken = json["id_token"] as? String ?? ""
        session.refreshToken = json["refresh_token"] as? String ?? ""
        session.clientToken = json["client_token"] as? String ?? ""
        let expiresIn = int64Value(json["expires_in"]) ?? 86400
        let nowMs = OPNAuthSession.currentEpochMs()
        session.accessTokenExpiry = nowMs + expiresIn * 1000
        session.expiresAt = Int64(Date().timeIntervalSince1970) + expiresIn

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
            session.expiresAt = Int64(Date().timeIntervalSince1970) + 86400
            session.accessTokenExpiry = OPNAuthSession.currentEpochMs() + 86_400_000
        }
        session.isAuthenticated = !session.accessToken.isEmpty
        return session
    }

    static func parseQueryString(_ query: String?) -> NSDictionary {
        let params = NSMutableDictionary()
        guard let query, !query.isEmpty else { return params }
        for pair in query.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard components.count == 2 else { continue }
            let key = components[0].removingPercentEncoding ?? components[0]
            let value = components[1].removingPercentEncoding ?? ""
            params[key] = value
        }
        return params
    }

    private func doOAuthTokenExchange(
        authCode: String,
        codeVerifier: String,
        redirectUri: String,
        providerIdpId: String,
        completion: @escaping OPNAuthCallback
    ) {
        let body = "grant_type=authorization_code&code=\(formURLEncode(authCode))&redirect_uri=\(formURLEncode(redirectUri))&code_verifier=\(formURLEncode(codeVerifier))"
        performTokenRequest(body: body) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let json):
                var session = Self.parseOAuthSession(json: json)
                if !providerIdpId.isEmpty { session.idpId = providerIdpId }
                self.ensureClientToken(session) { enriched in
                    var enrichedSession = enriched
                    if !providerIdpId.isEmpty { enrichedSession.idpId = providerIdpId }
                    DispatchQueue.main.async { completion(true, enrichedSession, "") }
                }
            case .failure(let error):
                DispatchQueue.main.async { completion(false, OPNAuthSession(), error.localizedDescription) }
            }
        }
    }

    private func completeRefreshWithSession(_ session: OPNAuthSession, completion: @escaping OPNAuthCallback) {
        ensureClientToken(session) { [weak self] enriched in
            guard let self else { return }
            self.saveSession(enriched)
            DispatchQueue.main.async { completion(true, enriched, "") }
        }
    }

    private func ensureClientToken(_ session: OPNAuthSession, completion: @escaping @Sendable (OPNAuthSession) -> Void) {
        guard session.isAuthenticated, session.isAccessTokenValid, shouldRefreshClientToken(session) else {
            completion(session)
            return
        }
        fetchClientToken(accessToken: session.accessToken) { success, clientToken, expiresInText in
            var enriched = session
            if success, !clientToken.isEmpty {
                let expiresIn = Int64(expiresInText) ?? 86400
                enriched.clientToken = clientToken
                enriched.clientTokenExpiry = OPNAuthSession.currentEpochMs() + expiresIn * 1000
                enriched.clientTokenExpiryLength = expiresIn * 1000
            }
            completion(enriched)
        }
    }

    private func shouldRefreshClientToken(_ session: OPNAuthSession) -> Bool {
        if session.clientToken.isEmpty || session.clientTokenExpiry == 0 { return true }
        let remainingMs = session.clientTokenExpiry - OPNAuthSession.currentEpochMs()
        if session.clientTokenExpiryLength > 0 {
            return remainingMs < (session.clientTokenExpiryLength * Self.clientTokenRefreshWindowPercent) / 100
        }
        return remainingMs < Self.clientTokenRefreshWindowMs
    }

    private func mergeRefreshedSession(saved: OPNAuthSession, refreshed: OPNAuthSession) -> OPNAuthSession {
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
        return merged
    }

    private func performTokenRequest(body: String, completion: @escaping @Sendable (Result<NSDictionary, Error>) -> Void) {
        guard let url = URL(string: Self.oAuthTokenURL) else {
            completion(.failure(ServiceError("Invalid token URL")))
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://nvfile", forHTTPHeaderField: "Origin")
        request.setValue("https://nvfile/", forHTTPHeaderField: "Referer")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body.data(using: .utf8)
        performJSONRequest(request, completion: completion)
    }

    private func performJSONRequest(_ request: URLRequest, completion: @escaping @Sendable (Result<NSDictionary, Error>) -> Void) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200, let data else {
                DispatchQueue.main.async { completion(.failure(ServiceError("HTTP \(http?.statusCode ?? 0)"))) }
                return
            }
            guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? NSDictionary else {
                DispatchQueue.main.async { completion(.failure(ServiceError("Invalid JSON response"))) }
                return
            }
            DispatchQueue.main.async { completion(.success(json)) }
        }.resume()
    }

    private func startOAuthCallbackListener(
        port: Int,
        expectedState: String,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else {
                completion(.failure(ServiceError("Failed to create OAuth callback listener")))
                return
            }
            var reuse = Int32(1)
            setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(port).bigEndian
            let bindResult = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0, listen(socketDescriptor, 1) == 0 else {
                close(socketDescriptor)
                completion(.failure(ServiceError("Failed to bind OAuth callback listener")))
                return
            }
            let clientSocket = accept(socketDescriptor, nil, nil)
            close(socketDescriptor)
            guard clientSocket >= 0 else {
                completion(.failure(ServiceError("Failed to accept OAuth callback")))
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let byteCount = recv(clientSocket, &buffer, buffer.count - 1, 0)
            let body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>OpenNOW Sign In</title></head><body style=\"background:#050807;color:#f1fff7;font:16px -apple-system,BlinkMacSystemFont,sans-serif;display:grid;place-items:center;min-height:100vh;margin:0\"><main><h1>Sign in complete</h1><p>You can close this window and return to OpenNOW.</p></main><script>setTimeout(function(){window.close()},1200)</script></body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            _ = response.withCString { send(clientSocket, $0, strlen($0), 0) }
            close(clientSocket)

            guard byteCount > 0 else {
                completion(.failure(ServiceError("Empty OAuth callback request")))
                return
            }
            let request = String(decoding: buffer.prefix(byteCount), as: UTF8.self)
            guard let pathStart = request.range(of: "GET ")?.upperBound,
                  let pathEnd = request[pathStart...].firstIndex(of: " ") else {
                completion(.failure(ServiceError("Invalid OAuth callback request")))
                return
            }
            let path = String(request[pathStart..<pathEnd])
            let query = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
            let params = Self.parseQueryString(query)
            guard let code = params["code"] as? String, !code.isEmpty else {
                let error = params["error_description"] as? String ?? params["error"] as? String ?? "Unknown OAuth error"
                completion(.failure(ServiceError(error)))
                return
            }
            guard params["state"] as? String == expectedState else {
                completion(.failure(ServiceError("State mismatch - possible CSRF")))
                return
            }
            completion(.success(code))
        }
    }

    private func findAvailablePort() -> Int {
        for port in [2259, 6460, 7119, 8870, 9096] {
            let probeSocket = socket(AF_INET, SOCK_STREAM, 0)
            if probeSocket >= 0 {
                var address = sockaddr_in()
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
                address.sin_port = in_port_t(port).bigEndian
                let hasListener = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(probeSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                    }
                }
                close(probeSocket)
                if hasListener { continue }
            }
            let testSocket = socket(AF_INET, SOCK_STREAM, 0)
            if testSocket < 0 { continue }
            var reuse = Int32(1)
            setsockopt(testSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
            address.sin_port = in_port_t(port).bigEndian
            let canBind = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(testSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            close(testSocket)
            if canBind { return port }
        }
        return 0
    }

    private func generatePKCEState() -> OAuthState {
        let verifier = generateRandomString(length: 64)
        return OAuthState(
            codeVerifier: verifier,
            codeChallenge: base64URLEncodedSHA256(verifier),
            state: generateRandomString(length: 32),
            nonce: generateRandomString(length: 32)
        )
    }

    private func generateRandomString(length: Int) -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in characters.randomElement() })
    }

    private func base64URLEncodedSHA256(_ value: String) -> String {
        Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateOpenNOWDeviceId() -> String {
        let hostname = Host.current().localizedName ?? "unknown"
        let user = ProcessInfo.processInfo.environment["USER"] ?? "unknown"
        return SHA256.hash(data: Data("\(hostname):\(user):opennow-stable".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func authUserDefaults() -> UserDefaults {
        if let suiteName = ProcessInfo.processInfo.environment["OPN_AUTH_USER_DEFAULTS_SUITE"], !suiteName.isEmpty {
            return UserDefaults(suiteName: suiteName) ?? .standard
        }
        return .standard
    }

    private func applicationSupportBasePath() -> String? {
        if let overridePath = ProcessInfo.processInfo.environment["OPN_AUTH_APPLICATION_SUPPORT_DIR"], !overridePath.isEmpty {
            return overridePath
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
    }

    private func sessionStorageDirectory() -> String? {
        guard let basePath = applicationSupportBasePath(), !basePath.isEmpty else { return nil }
        let directory = (basePath as NSString).appendingPathComponent("OpenNOW")
        if !FileManager.default.fileExists(atPath: directory) {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return directory
    }

    private func legacySessionFilePath() -> String? {
        guard let basePath = applicationSupportBasePath(), !basePath.isEmpty else { return nil }
        return ((basePath as NSString).appendingPathComponent("com.nvidia.geforcenow") as NSString).appendingPathComponent("session.plist")
    }

    private func sessionFilePath() -> String? {
        sessionStorageDirectory().map { ($0 as NSString).appendingPathComponent("session.plist") }
    }

    private func accountsFilePath() -> String? {
        sessionStorageDirectory().map { ($0 as NSString).appendingPathComponent("accounts.plist") }
    }

    private func sessionFilePathForRead() -> String? {
        if let path = sessionFilePath(), FileManager.default.fileExists(atPath: path) { return path }
        if let path = legacySessionFilePath(), FileManager.default.fileExists(atPath: path) { return path }
        return sessionFilePath()
    }

    private func loadLegacySingleSession() -> OPNAuthSession {
        guard let path = sessionFilePathForRead(), let dictionary = loadPropertyListDictionary(path: path) else { return OPNAuthSession() }
        return session(from: dictionary)
    }

    private func loadAccountDictionaries(activeUserId: UnsafeMutablePointer<String?>?) -> [NSDictionary] {
        let store = accountsFilePath().flatMap(loadPropertyListDictionary)
        activeUserId?.pointee = store?["active_user_id"] as? String
        return store?["accounts"] as? [NSDictionary] ?? []
    }

    private func saveAccountDictionaries(_ accounts: [NSDictionary], activeUserId: String?) {
        guard let path = accountsFilePath() else { return }
        let store = NSMutableDictionary()
        store["accounts"] = accounts
        if let activeUserId, !activeUserId.isEmpty { store["active_user_id"] = activeUserId }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: store, format: .xml, options: 0) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    private func loadPropertyListDictionary(path: String) -> NSDictionary? {
        guard FileManager.default.fileExists(atPath: path), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? NSDictionary
    }

    private func sessionIdentity(from session: OPNAuthSession) -> String? {
        [session.userId, session.email, session.displayName, session.accessToken].first { !$0.isEmpty }
    }

    private func sessionIdentity(from dictionary: NSDictionary) -> String? {
        ["user_id", "email", "display_name", "access_token"].compactMap { dictionary[$0] as? String }.first { !$0.isEmpty }
    }

    private func dictionary(from session: OPNAuthSession) -> NSDictionary {
        let dictionary = NSMutableDictionary()
        put(session.accessToken, key: "access_token", into: dictionary)
        put(session.idToken, key: "id_token", into: dictionary)
        put(session.refreshToken, key: "refresh_token", into: dictionary)
        put(session.clientToken, key: "client_token", into: dictionary)
        put(session.userId, key: "user_id", into: dictionary)
        put(session.displayName, key: "display_name", into: dictionary)
        put(session.email, key: "email", into: dictionary)
        put(session.membershipTier, key: "membership_tier", into: dictionary)
        put(session.idpId, key: "idp_id", into: dictionary)
        dictionary["expires_at"] = session.expiresAt
        dictionary["access_token_expiry"] = session.accessTokenExpiry
        dictionary["client_token_expiry"] = session.clientTokenExpiry
        dictionary["client_token_expiry_length"] = session.clientTokenExpiryLength
        dictionary["id_token_expiry"] = session.idTokenExpiry
        return dictionary
    }

    private func session(from dictionary: NSDictionary) -> OPNAuthSession {
        guard let accessToken = dictionary["access_token"] as? String, !accessToken.isEmpty else { return OPNAuthSession() }
        var session = OPNAuthSession()
        session.accessToken = accessToken
        session.idToken = dictionary["id_token"] as? String ?? ""
        session.refreshToken = dictionary["refresh_token"] as? String ?? ""
        session.clientToken = dictionary["client_token"] as? String ?? ""
        session.userId = dictionary["user_id"] as? String ?? ""
        session.displayName = dictionary["display_name"] as? String ?? ""
        session.email = dictionary["email"] as? String ?? ""
        session.membershipTier = dictionary["membership_tier"] as? String ?? "Free"
        session.idpId = dictionary["idp_id"] as? String ?? Self.defaultIdpId
        session.expiresAt = Self.int64Value(dictionary["expires_at"]) ?? 0
        session.accessTokenExpiry = Self.int64Value(dictionary["access_token_expiry"]) ?? 0
        session.clientTokenExpiry = Self.int64Value(dictionary["client_token_expiry"]) ?? 0
        session.clientTokenExpiryLength = Self.int64Value(dictionary["client_token_expiry_length"]) ?? 0
        session.idTokenExpiry = Self.int64Value(dictionary["id_token_expiry"]) ?? 0
        session.isAuthenticated = true
        return session
    }

    private func put(_ value: String, key: String, into dictionary: NSMutableDictionary) {
        if !value.isEmpty { dictionary[key] = value }
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private static func idTokenExpiry(_ idToken: String) -> Int64 {
        guard let exp = jwtClaims(idToken)["exp"] as? NSNumber else { return 0 }
        return exp.int64Value * 1000
    }

    private static func jwtClaims(_ idToken: String) -> NSDictionary {
        let parts = idToken.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return [:] }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            return [:]
        }
        return claims
    }

    private struct OAuthState: Sendable {
        let codeVerifier: String
        let codeChallenge: String
        let state: String
        let nonce: String
    }

    private struct ServiceError: LocalizedError, Sendable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

@objcMembers
@objc(OPNAuthSessionObject)
final class OPNAuthSessionObject: NSObject {
    var accessToken: String
    var idToken: String
    var refreshToken: String
    var userId: String
    var displayName: String
    var email: String
    var membershipTier: String
    var idpId: String
    var expiresAt: Int64
    var isAuthenticated: Bool
    var clientToken: String
    var clientTokenExpiry: Int64
    var clientTokenExpiryLength: Int64
    var idTokenExpiry: Int64
    var accessTokenExpiry: Int64

    override init() {
        accessToken = ""
        idToken = ""
        refreshToken = ""
        userId = ""
        displayName = ""
        email = ""
        membershipTier = ""
        idpId = ""
        expiresAt = 0
        isAuthenticated = false
        clientToken = ""
        clientTokenExpiry = 0
        clientTokenExpiryLength = 0
        idTokenExpiry = 0
        accessTokenExpiry = 0
    }

    init(session: OPNAuthSession) {
        accessToken = session.accessToken
        idToken = session.idToken
        refreshToken = session.refreshToken
        userId = session.userId
        displayName = session.displayName
        email = session.email
        membershipTier = session.membershipTier
        idpId = session.idpId
        expiresAt = session.expiresAt
        isAuthenticated = session.isAuthenticated
        clientToken = session.clientToken
        clientTokenExpiry = session.clientTokenExpiry
        clientTokenExpiryLength = session.clientTokenExpiryLength
        idTokenExpiry = session.idTokenExpiry
        accessTokenExpiry = session.accessTokenExpiry
    }

    var swiftValue: OPNAuthSession {
        var session = OPNAuthSession()
        session.accessToken = accessToken
        session.idToken = idToken
        session.refreshToken = refreshToken
        session.userId = userId
        session.displayName = displayName
        session.email = email
        session.membershipTier = membershipTier
        session.idpId = idpId
        session.expiresAt = expiresAt
        session.isAuthenticated = isAuthenticated
        session.clientToken = clientToken
        session.clientTokenExpiry = clientTokenExpiry
        session.clientTokenExpiryLength = clientTokenExpiryLength
        session.idTokenExpiry = idTokenExpiry
        session.accessTokenExpiry = accessTokenExpiry
        return session
    }
}

@objc(OPNAuthServiceDirect)
final class OPNAuthServiceDirect: NSObject, @unchecked Sendable {
    @objc(shared)
    static let shared = OPNAuthServiceDirect()

    @objc(startOAuthLoginWithProviderIdpId:completion:)
    func startOAuthLogin(providerIdpId: String, completion: @escaping @Sendable (Bool, OPNAuthSessionObject, String) -> Void) {
        OPNAuthService.shared.startOAuthLogin(providerIdpId: providerIdpId) { success, session, error in
            completion(success, OPNAuthSessionObject(session: session), error)
        }
    }

    @objc(refreshSessionForce:completion:)
    func refreshSession(force: Bool, completion: @escaping @Sendable (Bool, OPNAuthSessionObject, String) -> Void) {
        OPNAuthService.shared.refreshSession(completion: { success, session, error in
            completion(success, OPNAuthSessionObject(session: session), error)
        }, forceRefresh: force)
    }

    @objc(fetchStarFleetUserInfoWithAccessToken:completion:)
    func fetchStarFleetUserInfo(accessToken: String, completion: @escaping @Sendable (Bool, NSDictionary?, String) -> Void) {
        OPNAuthService.shared.fetchStarFleetUserInfo(accessToken: accessToken, completion: completion)
    }

    @objc(fetchClientTokenWithAccessToken:completion:)
    func fetchClientToken(accessToken: String, completion: @escaping @Sendable (Bool, String, String) -> Void) {
        OPNAuthService.shared.fetchClientToken(accessToken: accessToken, completion: completion)
    }

    @objc(serverLogoutWithIdToken:locale:completion:)
    func serverLogout(idToken: String, locale: String, completion: @escaping @Sendable (Bool, String) -> Void) {
        OPNAuthService.shared.serverLogout(idToken: idToken, locale: locale, completion: completion)
    }

    @objc(saveSession:)
    func saveSession(_ session: OPNAuthSessionObject) {
        OPNAuthService.shared.saveSession(session.swiftValue)
    }

    @objc(loadSavedSession)
    func loadSavedSession() -> OPNAuthSessionObject {
        OPNAuthSessionObject(session: OPNAuthService.shared.loadSavedSession())
    }

    @objc(loadSavedSessions)
    func loadSavedSessions() -> [OPNAuthSessionObject] {
        OPNAuthService.shared.loadSavedSessions().map(OPNAuthSessionObject.init(session:))
    }

    @objc(loadSavedSessionForUserId:)
    func loadSavedSession(userId: String) -> OPNAuthSessionObject {
        OPNAuthSessionObject(session: OPNAuthService.shared.loadSavedSession(forUserId: userId))
    }

    @objc(setActiveSessionUserId:)
    func setActiveSessionUserId(_ userId: String) {
        OPNAuthService.shared.setActiveSessionUserId(userId)
    }

    @objc(removeSavedSessionForUserId:)
    func removeSavedSession(userId: String) {
        OPNAuthService.shared.removeSavedSession(userId: userId)
    }

    @objc(clearSession)
    func clearSession() {
        OPNAuthService.shared.clearSession()
    }

    @objc(getStayLoggedIn)
    func getStayLoggedIn() -> Bool {
        OPNAuthService.shared.getStayLoggedIn()
    }

    @objc(setStayLoggedIn:)
    func setStayLoggedIn(_ value: Bool) {
        OPNAuthService.shared.setStayLoggedIn(value)
    }

    @objc(parseOAuthSession:)
    static func parseOAuthSession(_ json: NSDictionary) -> OPNAuthSessionObject {
        OPNAuthSessionObject(session: OPNAuthService.parseOAuthSession(json: json))
    }

    @objc(parseQueryString:)
    static func parseQueryString(_ query: String?) -> NSDictionary {
        OPNAuthService.parseQueryString(query)
    }

    @objc(getPersistentDeviceUUID)
    static func getPersistentDeviceUUID() -> String {
        OPNAuthService.getPersistentDeviceUUID()
    }
}
