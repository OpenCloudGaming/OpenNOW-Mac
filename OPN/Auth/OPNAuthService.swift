import AppKit
import CryptoKit
import Darwin
import Foundation

public typealias OPNAuthCallback = @MainActor @Sendable (_ success: Bool, _ session: OPNAuthSession, _ error: String) -> Void
typealias OPNSimpleCallback = @MainActor @Sendable (_ success: Bool, _ error: String) -> Void
public typealias OPNDeviceCodeChallengeCallback = @MainActor @Sendable (_ challenge: OPNDeviceCodeLoginChallenge) -> Void

public struct OPNDeviceCodeLoginChallenge: Equatable, Sendable {
    public let userCode: String
    public let verificationURI: String
    public let verificationURIComplete: String
    public let expiresAt: Date
    public let interval: TimeInterval

    public init(response: StarfleetDeviceAuthorizationResponse) {
        self.userCode = response.userCode
        self.verificationURI = response.verificationURI
        self.verificationURIComplete = response.verificationURIComplete
        self.expiresAt = response.expiresAt
        self.interval = TimeInterval(response.interval)
    }

    public var verificationURL: URL? {
        URL(string: verificationURIComplete.isEmpty ? verificationURI : verificationURIComplete)
    }
}

public final class OPNAuthService: @unchecked Sendable {
    public static let shared = OPNAuthService()
    private static let jarvisConfiguration = JarvisOAuthConfiguration.gfnPC
    static let jarvisAuthStatusDidChangeNotification = Notification.Name("OpenNOW.JarvisAuthStatusDidChange")

    static let oAuthAuthorizeURL = jarvisConfiguration.authorizeURLString
    static let oAuthTokenURL = jarvisConfiguration.tokenURLString
    static let oAuthClientId = jarvisConfiguration.clientId
    static let oAuthRedirectURI = jarvisConfiguration.redirectURI
    static let oAuthScope = jarvisConfiguration.scope
    public static let defaultIdpId = jarvisConfiguration.defaultIdpId
    static let defaultUserAgent = jarvisConfiguration.userAgent
    static let oAuthLogoutURL = jarvisConfiguration.logoutURLString

    private static let uuidLock = NSLock()
    nonisolated(unsafe) private static var cachedUUID = ""
    private let telemetry: JarvisTelemetry = OPNJarvisSentryTelemetry.shared
    let jarvisAuthService: JarvisAuthService<JarvisURLSessionTransport>
    let starfleetService: StarfleetService<StarfleetURLSessionTransport>
    private let statusObservationTask: Task<Void, Never>

    private init() {
        let jarvisService = JarvisAuthService(
            configuration: Self.jarvisConfiguration,
            retryPolicy: .gfnPC,
            transport: JarvisURLSessionTransport(),
            telemetry: OPNJarvisSentryTelemetry.shared,
            sessionStore: OPNJarvisSessionStore.shared,
            persistenceMode: .manual
        )
        let starfleetService = StarfleetService(
            configuration: .gfnPC,
            refreshPolicy: .gfnPC,
            retryPolicy: .gfnPC,
            transport: StarfleetURLSessionTransport(),
            telemetry: OPNStarfleetSentryTelemetry.shared
        )
        self.jarvisAuthService = jarvisService
        self.starfleetService = starfleetService
        self.statusObservationTask = Task { [jarvisService] in
            let stream = await jarvisService.monitorLoginStatus()
            for await status in stream {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Self.jarvisAuthStatusDidChangeNotification,
                        object: nil,
                        userInfo: ["status": status.rawValue]
                    )
                }
            }
        }
    }

    public func startOAuthLogin(completion: @escaping OPNAuthCallback) {
        startOAuthLogin(providerIdpId: Self.defaultIdpId, completion: completion)
    }

    public func startOAuthLogin(providerIdpId: String, completion: @escaping OPNAuthCallback) {
        let port = findAvailablePort()
        guard port > 0 else {
            Task { @MainActor in completion(false, OPNAuthSession(), "No available port for OAuth callback") }
            return
        }

        let pkce = generatePKCEState()
        let deviceId = generateOpenNOWDeviceId()
        let redirectUri = "http://localhost:\(port)"
        let selectedProviderIdpId = providerIdpId.isEmpty ? Self.defaultIdpId : providerIdpId
        let locale = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        telemetry.recordBreadcrumb("Jarvis OAuth login starting", attributes: ["provider_idp_id": selectedProviderIdpId])

        Task { [weak self] in
            guard let self else { return }
            do {
                _ = await self.jarvisAuthService.sameTabAuthStarted()
                let loginRequest = try await self.jarvisAuthService.createOAuthLoginRequest(
                    deviceId: deviceId,
                    redirectURI: redirectUri,
                    locale: locale,
                    oauthState: pkce,
                    providerIdpId: selectedProviderIdpId
                )
                self.startOAuthCallbackListener(port: port) { [weak self] result in
                    self?.handleOAuthCallback(result,
                                              pkce: pkce,
                                              redirectUri: redirectUri,
                                              providerIdpId: selectedProviderIdpId,
                                              completion: completion)
                } readyHandler: {
                    Task { @MainActor in
                        self.telemetry.recordBreadcrumb("Jarvis OAuth browser opened", attributes: ["provider_idp_id": selectedProviderIdpId])
                        NSWorkspace.shared.open(loginRequest.url)
                    }
                }
            } catch {
                _ = await self.jarvisAuthService.finishLogin(success: false)
                self.telemetry.recordError(error, operation: .getLoginToken, attributes: ["phase": "authorization_url"])
                Task { @MainActor in completion(false, OPNAuthSession(), error.localizedDescription) }
            }
        }
    }

    /// The loopback listener's answer: either the authorization code to exchange, or the reason
    /// the browser leg failed.
    func handleOAuthCallback(_ result: Result<String, Error>,
                                     pkce: JarvisOAuthState,
                                     redirectUri: String,
                                     providerIdpId: String,
                                     completion: @escaping OPNAuthCallback) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let query = try result.get()
                let callback = try await self.jarvisAuthService.parseCallback(query: query, expectedState: pkce.state)
                self.doOAuthTokenExchange(
                    authCode: callback.code,
                    codeVerifier: pkce.codeVerifier,
                    redirectUri: redirectUri,
                    providerIdpId: providerIdpId,
                    completion: completion
                )
            } catch {
                _ = await self.jarvisAuthService.finishLogin(success: false)
                self.telemetry.recordError(error, operation: .getLoginToken, attributes: ["phase": "callback"])
                Task { @MainActor in completion(false, OPNAuthSession(), error.localizedDescription) }
            }
        }
    }

    public func startStarfleetDeviceCodeLogin(providerIdpId: String = OPNAuthService.defaultIdpId, challengeHandler: @escaping OPNDeviceCodeChallengeCallback, completion: @escaping OPNAuthCallback) {
        let selectedProviderIdpId = providerIdpId.isEmpty ? Self.defaultIdpId : providerIdpId
        let deviceId = generateOpenNOWDeviceId()
        let displayName = Host.current().localizedName ?? "OpenNOW Mac"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = await self.jarvisAuthService.sameTabAuthStarted()
                let response = try await self.starfleetService.requestDeviceAuthorization(deviceId: deviceId, displayName: displayName, providerIdpId: selectedProviderIdpId)
                let challenge = OPNDeviceCodeLoginChallenge(response: response)
                await MainActor.run {
                    challengeHandler(challenge)
                    if let verificationURL = challenge.verificationURL {
                        NSWorkspace.shared.open(verificationURL)
                    }
                }
                let session = Self.opnSession(from: try await self.starfleetService.pollDeviceAuthorization(deviceCode: response.deviceCode, interval: challenge.interval, timeout: max(1, response.expiresAt.timeIntervalSinceNow)))
                await self.jarvisAuthService.setSession(session)
                self.saveSession(session)
                _ = await self.jarvisAuthService.finishLogin(success: true)
                Task { @MainActor in completion(true, session, "") }
            } catch {
                _ = await self.jarvisAuthService.finishLogin(success: false)
                await self.handleStarfleetFailure(error)
                Task { @MainActor in completion(false, OPNAuthSession(), error.localizedDescription) }
            }
        }
    }

    func refreshSession(completion: @escaping OPNAuthCallback, forceRefresh: Bool = false) {
        let session = loadSavedSession()
        guard session.isAuthenticated else {
            Task { @MainActor in completion(false, OPNAuthSession(), "No saved session available") }
            return
        }

        Task { [weak self] in
            guard let self else { return }
            await self.syncBackendSessions(session)
            do {
                let refreshed = Self.opnSession(from: try await self.starfleetService.refreshSession(force: forceRefresh || !session.isIdTokenValid))
                await self.jarvisAuthService.setSession(refreshed)
                self.saveSession(refreshed)
                Task { @MainActor in completion(true, refreshed, "") }
            } catch {
                await self.handleStarfleetFailure(error)
                Task { @MainActor in completion(false, session, error.localizedDescription) }
            }
        }
    }

    public func refreshSession(forceRefresh: Bool) async throws -> OPNAuthSession {
        try await withCheckedThrowingContinuation { continuation in
            refreshSession(completion: { success, session, message in
                if success {
                    continuation.resume(returning: session)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "OpenNOW.OPNAuthService",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Session refresh failed." : message]
                    ))
                }
            }, forceRefresh: forceRefresh)
        }
    }

    func monitorLoginStatus(replayCurrent: Bool = true) async -> AsyncStream<JarvisAuthStatus> {
        await jarvisAuthService.monitorLoginStatus(replayCurrent: replayCurrent)
    }

    func fetchStarFleetUserInfo(accessToken: String, completion: @escaping @Sendable (Bool, NSDictionary?, String) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let userInfo = try await self.starfleetService.fetchUserInfo(accessToken: accessToken)
                let dictionary = self.dictionary(from: userInfo)
                Task { @MainActor in completion(true, dictionary, "") }
            } catch {
                await self.handleStarfleetFailure(error)
                Task { @MainActor in completion(false, nil, error.localizedDescription) }
            }
        }
    }

    func fetchClientToken(accessToken: String, completion: @escaping @Sendable (Bool, String, String) -> Void) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.starfleetService.fetchClientToken(accessToken: accessToken)
                Task { @MainActor in completion(true, result.clientToken, result.expiresIn) }
            } catch {
                await self.handleStarfleetFailure(error)
                Task { @MainActor in completion(false, "", error.localizedDescription) }
            }
        }
    }

    func serverLogout(idToken: String, locale: String, completion: @escaping OPNSimpleCallback) {
        guard !idToken.isEmpty else {
            clearSession()
            Task { @MainActor in completion(true, "") }
            return
        }
        let resolvedLocale = locale.isEmpty ? Locale.current.identifier.replacingOccurrences(of: "-", with: "_") : locale
        guard let url = StarfleetOAuthRequestFactory.logoutURL(idToken: idToken, locale: resolvedLocale, postLogoutRedirectURI: Self.oAuthRedirectURI, configuration: .gfnPC) else {
            clearSession()
            Task { @MainActor in completion(false, "Invalid logout URL") }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        let networkStart = OPNNetworkLog.start(&request, operation: "auth.serverLogout")
        let tracedRequest = request
        URLSession.shared.dataTask(with: tracedRequest) { data, response, error in
            OPNNetworkLog.finish(tracedRequest, operation: "auth.serverLogout", startedAt: networkStart, data: data, response: response, error: error)
            Task { @MainActor in
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
            cachedUUID = legacy
            return legacy
        }
        let uuid = UUID().uuidString
        defaults.set(uuid, forKey: key)
        cachedUUID = uuid
        return uuid
    }

    func saveSession(_ session: OPNAuthSession) {
        saveSession(session, replacingIdentity: nil)
    }

    func saveSession(_ session: OPNAuthSession, replacingIdentity: String?) {
        guard session.isAuthenticated, !session.accessToken.isEmpty else { return }

        Task { [jarvisAuthService, starfleetService] in
            await jarvisAuthService.setSession(session)
            await starfleetService.setSession(Self.starfleetSession(from: session))
        }

        let existing = loadAccountDictionaries(activeUserId: nil)
        // With no profile fields to key on, stay on the identity this account already has —
        // re-keying on every refresh would leave an orphaned account and keychain item behind each
        // time. The active id is only reused once it is confirmed to name a real account, so a
        // stale access token left there by an older build can never become the identity.
        let activeIdentity = Self.authUserDefaults().string(forKey: "OPN_ActiveUserId")
        let reusableIdentity = existing.compactMap(sessionIdentity).first { $0 == activeIdentity }
        let identity = sessionIdentity(from: session)
            ?? replacingIdentity
            ?? reusableIdentity
            ?? Self.newAnonymousIdentity()
        guard !identity.isEmpty else { return }

        var accounts = existing.filter {
            let existingIdentity = sessionIdentity(from: $0)
            return existingIdentity != identity && existingIdentity != replacingIdentity
        }
        accounts.insert(dictionary(from: session, identity: identity), at: 0)
        saveAccountDictionaries(accounts, activeUserId: identity)

        let defaults = Self.authUserDefaults()
        defaults.set(true, forKey: "OPN_HasSavedSession")
        defaults.set(identity, forKey: "OPN_ActiveUserId")
    }
}
