//  LoginViewModel.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftData
import SwiftUI

private final class LoginWeakObject<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var email = ""
    @Published var oauthCallbackText = ""
    @Published var providers = [LoginProvider.nvidia]
    @Published var selectedProvider = LoginProvider.nvidia
    @Published var rememberSession = true
    @Published var acceptedTerms = false
    @Published var isShowingTermsOfUse = false
    @Published var isShowingAccountPicker = false
    @Published var validationMessage = ""
    @Published var successMessage = ""
    @Published var isLoadingProviders = false
    @Published var isLaunchingOAuth = false
    @Published var isAuthenticating = false
    @Published var requestedFocus: LoginField?
    @Published var currentAuthorizationURL = ""
    @Published var pendingGameShortcut: GFNGameShortcut?

    private let authService = OPNAuthService.shared
    private let jarvisAuthService = JarvisAuthService(transport: JarvisURLSessionTransport())
    private var modelContext: ModelContext?
    private var accounts: [LoginAccount] = []
    private var sessions: [LoginSession] = []
    private var devices: [LoginDeviceRegistration] = []

    var authStatusSummary: String {
        if isAuthenticating { return JarvisAuthStatus.pendingLogin.rawValue.replacingOccurrences(of: "_", with: " ") }
        if activeSession != nil { return JarvisAuthStatus.loggedIn.rawValue.replacingOccurrences(of: "_", with: " ") }
        if hasPendingOAuth { return JarvisAuthStatus.pendingLogin.rawValue.replacingOccurrences(of: "_", with: " ") }
        return JarvisAuthStatus.notLoggedIn.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    var nesAuthorizationSummary: String {
        activeAccount?.authorizationState ?? NesAuth.AuthorizationState.pending.rawValue
    }

    var activeSession: LoginSession? {
        sessions.first { session in
            session.isActive && (!session.isExpired || session.canContinueOffline)
        }
    }

    var activeAccount: LoginAccount? {
        guard let activeSession else { return nil }
        return accounts.first { $0.email == activeSession.accountEmail }
    }

    var primaryDevice: LoginDeviceRegistration {
        devices.first ?? LoginDeviceRegistration()
    }

    var hasPendingOAuth: Bool {
        !primaryDevice.pendingOAuthState.isEmpty && !primaryDevice.pendingOAuthCodeVerifier.isEmpty
    }

    var canLaunchOAuth: Bool {
        acceptedTerms && !isLaunchingOAuth && !isAuthenticating
    }

    var canCompleteOAuth: Bool {
        hasPendingOAuth && !oauthCallbackText.trimmed.isEmpty && !isAuthenticating
    }

    func update(modelContext: ModelContext, accounts: [LoginAccount], sessions: [LoginSession], devices: [LoginDeviceRegistration]) {
        self.modelContext = modelContext
        self.accounts = accounts
        self.sessions = sessions
        self.devices = devices
    }

    func bootstrap() {
        OpenNOWLog.info(.auth, "Login bootstrap started accounts=\(accounts.count) sessions=\(sessions.count) devices=\(devices.count)")
        ensureDeviceRegistration()
        prefillLastAccount()
        refreshLoginProviders()
        acceptedTerms = UserDefaults.standard.bool(forKey: Self.termsAcceptedKey)
        OpenNOWLog.info(.auth, "Login bootstrap completed hasActiveSession=\(activeSession != nil) hasPendingOAuth=\(hasPendingOAuth)")
    }

    private static let termsAcceptedKey = "OpenNOW.Login.GFNTermsAccepted"

    func presentTermsOfUseIfNeeded() {
        guard !acceptedTerms else { return }
        isShowingTermsOfUse = true
    }

    func acceptTermsOfUse() {
        acceptedTerms = true
        UserDefaults.standard.set(true, forKey: Self.termsAcceptedKey)
        isShowingTermsOfUse = false
        launchOAuth()
    }

    func declineTermsOfUse() {
        acceptedTerms = false
        UserDefaults.standard.removeObject(forKey: Self.termsAcceptedKey)
        isShowingTermsOfUse = false
        validationMessage = "You must accept the GeForce NOW Terms of Use to continue."
    }

    func toggleAccountPicker() {
        withAnimation(.snappy) {
            isShowingAccountPicker.toggle()
        }
    }

    func selectRememberedAccount(_ account: LoginAccount) {
        email = account.email
        selectedProvider = providerOption(idpId: account.providerIdpId, fallbackName: account.providerName)
        rememberSession = account.rememberSession
    }

    func selectProvider(_ provider: LoginProvider) {
        selectedProvider = provider
    }

    func launchOAuth() {
        Task { await beginOAuth() }
    }

    func completeOAuthWithCallbackText() {
        Task { await completeOAuth(callbackText: oauthCallbackText) }
    }

    func handleOAuthCallback(_ url: URL) {
        guard url.scheme == "com.nvidia.geforcenow" || url.scheme == "opennow" else { return }
        Task { await completeOAuth(callbackText: url.absoluteString) }
    }

    func handleOpenedFile(_ url: URL) {
        OpenNOWLog.info(.shortcut, "LoginViewModel received opened file: \(url.path)")
        guard url.pathExtension.caseInsensitiveCompare("gfnpc") == .orderedSame else {
            OpenNOWLog.info(.shortcut, "Ignoring non-gfnpc opened file: \(url.pathExtension)")
            return
        }
        do {
            pendingGameShortcut = try GFNGameShortcut(fileURL: url)
            if let shortcut = pendingGameShortcut {
                OpenNOWLog.info(.shortcut, "Parsed gfnpc shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) parentGameId=\(shortcut.parentGameId) title=\(shortcut.lookupTitle)")
            }
            if activeSession == nil {
                OpenNOWLog.info(.shortcut, "Shortcut parsed but no active session is available")
                validationMessage = "Sign in to launch \(pendingGameShortcut?.lookupTitle.isEmpty == false ? pendingGameShortcut?.lookupTitle ?? "this game" : "this game") from its GeForce NOW shortcut."
            } else {
                OpenNOWLog.info(.shortcut, "Shortcut queued for active catalog session")
            }
        } catch {
            OpenNOWLog.error(.shortcut, "Failed to parse gfnpc shortcut: \(error.localizedDescription)")
            validationMessage = error.localizedDescription
        }
    }

    func activateAccount(_ account: LoginAccount) {
        Task { await restoreAccountSession(account) }
    }

    func signOut() {
        Task { await signOutCurrentSession() }
    }

    func refreshActiveSession() {
        guard let activeAccount else { return }
        Task { await restoreAccountSession(activeAccount) }
    }

    func forgetAccount(_ account: LoginAccount) {
        guard let modelContext else { return }
        for session in sessions where session.accountEmail == account.email {
            modelContext.delete(session)
        }
        modelContext.delete(account)
        trySave()
    }

    private func beginOAuth() async {
        validationMessage = ""
        successMessage = ""
        let loginProvider = selectedProvider
        OpenNOWLog.info(.auth, "Beginning OAuth launch provider=\(loginProvider.idpId)")

        guard acceptedTerms else {
            OpenNOWLog.warning(.auth, "OAuth launch blocked because terms were not accepted")
            validationMessage = "Accept account terms and local session storage before continuing."
            return
        }

        isLaunchingOAuth = true
        validationMessage = "Finish \(loginProvider.title) sign-in in the browser. OpenNOW will continue automatically."

        authService.startOAuthLogin(providerIdpId: loginProvider.idpId) { [weak self] success, session, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectedProvider = loginProvider
                self.isLaunchingOAuth = false
                self.currentAuthorizationURL = ""
                self.clearPendingOAuthState()
                self.oauthCallbackText = ""

                guard success else {
                    self.validationMessage = error.isEmpty ? "\(loginProvider.title) sign-in failed." : error
                    OpenNOWLog.error(.auth, "OAuth start failed provider=\(loginProvider.idpId) error=\(self.validationMessage)")
                    return
                }

                await self.jarvisAuthService.setSession(session)
                self.persistSignedInSession(session: session, userInfo: nil, authMethod: Jarvis.Operation.getSessionToken.rawValue)
                self.validationMessage = ""
                self.successMessage = "\(loginProvider.title) account connected. Client token and session metadata are ready."
                OpenNOWLog.info(.auth, "OAuth start completed provider=\(loginProvider.idpId)")
            }
        }
    }

    private func completeOAuth(callbackText: String) async {
        validationMessage = ""
        successMessage = ""

        let device = primaryDevice
        guard !device.pendingOAuthState.isEmpty, !device.pendingOAuthCodeVerifier.isEmpty else {
            OpenNOWLog.warning(.auth, "OAuth callback ignored because pending state is missing")
            validationMessage = "Start browser sign-in before completing authorization."
            return
        }

        guard let query = Self.callbackQuery(from: callbackText.trimmed) else {
            OpenNOWLog.warning(.auth, "OAuth callback rejected because callback text could not be parsed")
            validationMessage = "Paste the full callback URL or authorization query from the browser."
            requestedFocus = .callback
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        OpenNOWLog.info(.auth, "Completing OAuth callback provider=\(device.pendingOAuthProviderIdpId.isEmpty ? selectedProvider.idpId : device.pendingOAuthProviderIdpId)")

        do {
            let callback = try await jarvisAuthService.parseCallback(query: query, expectedState: device.pendingOAuthState)
            let providerIdpId = device.pendingOAuthProviderIdpId.isEmpty ? selectedProvider.idpId : device.pendingOAuthProviderIdpId
            let redirectURI = device.pendingOAuthRedirectURI.isEmpty ? JarvisOAuthConfiguration.gfnPC.redirectURI : device.pendingOAuthRedirectURI
            let session = try await jarvisAuthService.exchangeAuthorizationCode(
                authCode: callback.code,
                redirectURI: redirectURI,
                codeVerifier: device.pendingOAuthCodeVerifier,
                providerIdpId: providerIdpId
            )
            let userInfo = try await jarvisAuthService.getCurrentUser(forceRefresh: false)
            persistSignedInSession(session: session, userInfo: userInfo, authMethod: Jarvis.Operation.getSessionToken.rawValue)
            clearPendingOAuthState()
            oauthCallbackText = ""
            currentAuthorizationURL = ""
            trySave()
            _ = await jarvisAuthService.finishLogin(success: true)
            let providerTitle = providerOption(idpId: providerIdpId, fallbackName: selectedProvider.title).title
            successMessage = "\(providerTitle) account connected. Client token and session metadata are ready."
            OpenNOWLog.info(.auth, "OAuth callback completed userId=\(session.userId) provider=\(providerIdpId)")
        } catch {
            _ = await jarvisAuthService.finishLogin(success: false)
            validationMessage = Self.userFacingError(error)
            requestedFocus = .callback
            OpenNOWLog.error(.auth, "OAuth callback failed: \(validationMessage)")
        }
    }

    private func restoreAccountSession(_ account: LoginAccount) async {
        validationMessage = ""
        successMessage = ""
        email = account.email
        selectedProvider = providerOption(idpId: account.providerIdpId, fallbackName: account.providerName)
        rememberSession = account.rememberSession

        guard let storedSession = sessions.first(where: { $0.accountEmail == account.email && !$0.accessToken.isEmpty }) else {
            OpenNOWLog.warning(.auth, "Session restore failed because no saved session exists for account=\(account.email)")
            validationMessage = "No saved session exists for this account. Sign in again."
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        var jarvisSession = JarvisSession(
            accessToken: storedSession.accessToken,
            idToken: storedSession.idToken,
            refreshToken: storedSession.refreshToken,
            userId: storedSession.userId,
            displayName: account.displayName,
            email: account.email,
            membershipTier: account.membershipTier,
            idpId: storedSession.idpId.isEmpty ? account.providerIdpId : storedSession.idpId,
            expiresAt: Int64(storedSession.expiresAt.timeIntervalSince1970),
            isAuthenticated: true,
            clientToken: storedSession.clientToken,
            clientTokenExpiry: Int64(storedSession.clientTokenExpiresAt.timeIntervalSince1970 * 1000.0),
            clientTokenExpiryLength: 0,
            accessTokenExpiry: Int64(storedSession.expiresAt.timeIntervalSince1970 * 1000.0)
        )
        if jarvisSession.idTokenExpiry == 0 {
            jarvisSession.idTokenExpiry = JarvisSessionParser.idTokenExpiry(storedSession.idToken)
        }

        do {
            OpenNOWLog.info(.auth, "Refreshing saved session account=\(account.email)")
            await jarvisAuthService.setSession(jarvisSession)
            let refreshed = try await jarvisAuthService.refreshSession(force: !jarvisSession.isIdTokenValid)
            persistSignedInSession(session: refreshed, userInfo: nil, authMethod: Jarvis.Operation.getSessionToken.rawValue)
            successMessage = "Session refreshed for \(account.displayName)."
            OpenNOWLog.info(.auth, "Session refreshed account=\(account.email)")
        } catch {
            if storedSession.canContinueOffline && !storedSession.isExpired {
                markActive(accountEmail: account.email)
                trySave()
                successMessage = "Using saved offline session for \(account.displayName)."
                OpenNOWLog.warning(.auth, "Using offline saved session account=\(account.email) refreshError=\(error.localizedDescription)")
            } else {
                validationMessage = "Saved session expired. Sign in again."
                OpenNOWLog.warning(.auth, "Session restore failed account=\(account.email) error=\(error.localizedDescription)")
            }
        }
    }

    private func signOutCurrentSession() async {
        OpenNOWLog.info(.auth, "Signing out current session")
        for account in accounts {
            account.isActive = false
            account.authStatus = JarvisAuthStatus.notLoggedIn.rawValue
        }
        for session in sessions {
            session.isActive = false
        }
        clearPendingOAuthState()
        currentAuthorizationURL = ""
        oauthCallbackText = ""
        trySave()
        await jarvisAuthService.clearSession()
        successMessage = "Signed out."
        OpenNOWLog.info(.auth, "Sign out completed")
    }

    private func persistSignedInSession(session: JarvisSession, userInfo: JarvisUserInfo?, authMethod: String) {
        guard let modelContext else {
            validationMessage = "SwiftData context is unavailable."
            OpenNOWLog.error(.auth, "Cannot persist signed-in session because SwiftData context is unavailable")
            return
        }

        let now = Date()
        let normalizedEmail = Self.normalizedEmail(session: session, userInfo: userInfo, fallbackEmail: email)
        let displayName = Self.displayName(session: session, userInfo: userInfo, email: normalizedEmail)
        let providerIdpId = session.idpId.isEmpty ? selectedProvider.idpId : session.idpId
        let resolvedProvider = providerOption(idpId: providerIdpId, fallbackName: selectedProvider.title)
        let existingSession = sessions.first { $0.accountEmail == normalizedEmail && $0.isActive } ?? sessions.first { $0.accountEmail == normalizedEmail }

        for account in accounts { account.isActive = false }
        for storedSession in sessions { storedSession.isActive = false }

        let account: LoginAccount
        if let existingAccount = accounts.first(where: { $0.email == normalizedEmail }) {
            account = existingAccount
        } else {
            account = LoginAccount(
                email: normalizedEmail,
                displayName: displayName,
                providerIdpId: providerIdpId,
                providerName: resolvedProvider.title
            )
            modelContext.insert(account)
            accounts.insert(account, at: 0)
        }

        let authorization = NesAuthorizationPolicy().result(authType: JarvisAuthType.jwtGFN.rawValue)
        account.displayName = displayName
        account.providerIdpId = providerIdpId
        account.providerName = resolvedProvider.title
        account.membershipTier = session.membershipTier.isEmpty ? "Free" : session.membershipTier
        account.authorizationState = authorization.state.rawValue
        account.authStatus = JarvisAuthStatus.loggedIn.rawValue
        account.userId = session.userId
        account.externalUserId = userInfo?.externalId ?? session.userId
        account.lastLoginAt = now
        account.rememberSession = rememberSession
        account.isActive = true

        let expiry = Date(timeIntervalSince1970: TimeInterval(session.expiresAt > 0 ? session.expiresAt : Int64(now.addingTimeInterval(86_400).timeIntervalSince1970)))
        let clientExpiry = session.clientTokenExpiry > 0 ? Date(timeIntervalSince1970: TimeInterval(session.clientTokenExpiry) / 1000.0) : expiry
        let storedSession = existingSession ?? LoginSession(
            accountEmail: normalizedEmail,
            authMethod: authMethod,
            accessToken: session.accessToken,
            clientToken: session.clientToken,
            idToken: session.idToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            idpId: providerIdpId,
            deviceId: primaryDevice.deviceId,
            issuedAt: now,
            expiresAt: expiry,
            clientTokenExpiresAt: clientExpiry,
            isActive: true,
            canContinueOffline: rememberSession
        )
        storedSession.updateAuthentication(
            accountEmail: normalizedEmail,
            authMethod: authMethod,
            accessToken: session.accessToken,
            clientToken: session.clientToken,
            idToken: session.idToken,
            refreshToken: session.refreshToken,
            userId: session.userId,
            idpId: providerIdpId,
            deviceId: primaryDevice.deviceId,
            issuedAt: now,
            expiresAt: expiry,
            clientTokenExpiresAt: clientExpiry,
            isActive: true,
            canContinueOffline: rememberSession
        )
        if existingSession == nil {
            modelContext.insert(storedSession)
            sessions.insert(storedSession, at: 0)
        } else if let index = sessions.firstIndex(where: { $0.id == storedSession.id }), index > 0 {
            sessions.remove(at: index)
            sessions.insert(storedSession, at: 0)
        }
        primaryDevice.lastUsedAt = now
        trySave()
        OpenNOWLog.info(.auth, "Persisted signed-in session account=\(normalizedEmail) provider=\(providerIdpId) canContinueOffline=\(rememberSession)")
    }

    private func markActive(accountEmail: String) {
        for account in accounts {
            account.isActive = account.email == accountEmail
            account.authStatus = account.isActive ? JarvisAuthStatus.loggedIn.rawValue : JarvisAuthStatus.notLoggedIn.rawValue
        }
        for session in sessions {
            session.isActive = session.accountEmail == accountEmail
        }
    }

    private func clearPendingOAuthState() {
        primaryDevice.pendingOAuthState = ""
        primaryDevice.pendingOAuthCodeVerifier = ""
        primaryDevice.pendingOAuthProviderIdpId = ""
        primaryDevice.pendingOAuthRedirectURI = ""
    }

    private func ensureDeviceRegistration() {
        guard devices.isEmpty, let modelContext else { return }
        let device = LoginDeviceRegistration()
        modelContext.insert(device)
        devices = [device]
        trySave()
        OpenNOWLog.info(.auth, "Created login device registration deviceId=\(device.deviceId)")
    }

    private func prefillLastAccount() {
        guard email.isEmpty, let account = accounts.first else { return }
        email = account.email
        selectedProvider = providerOption(idpId: account.providerIdpId, fallbackName: account.providerName)
        rememberSession = account.rememberSession
    }

    private func refreshLoginProviders() {
        guard !isLoadingProviders else { return }
        isLoadingProviders = true
        let requestedProviderIdpId = selectedProvider.idpId
        let selfBox = LoginWeakObject(self)
        OPNGameServiceSwiftAdapter.fetchGameProviderInfo(idpId: requestedProviderIdpId) { success, info, _, error in
            Task { @MainActor in
                guard let self = selfBox.value else { return }
                self.isLoadingProviders = false
                guard success else {
                    OpenNOWLog.warning(.auth, "Provider discovery failed: \(error)")
                    return
                }
                self.applyProviderInfo(info)
            }
        }
    }

    private func applyProviderInfo(_ info: OPNGameProviderInfo) {
        let discoveredProviders = Self.providerOptions(from: info)
        guard !discoveredProviders.isEmpty else { return }

        let previousProviderIdpId = selectedProvider.idpId
        providers = discoveredProviders
        if let existingProvider = providerOptionIfAvailable(idpId: previousProviderIdpId) {
            selectedProvider = existingProvider
        } else if let preferredProvider = Self.preferredProvider(in: discoveredProviders, info: info) {
            selectedProvider = preferredProvider
        } else {
            selectedProvider = discoveredProviders[0]
        }
    }

    private func providerOption(idpId: String, fallbackName: String = "") -> LoginProvider {
        if let provider = providerOptionIfAvailable(idpId: idpId) { return provider }
        if idpId.isEmpty || idpId == Jarvis.defaultIdpId { return .nvidia }
        let title = fallbackName.trimmed.isEmpty ? "Provider" : fallbackName.trimmed
        return LoginProvider(idpId: idpId, title: title, loginProvider: title, loginProviderCode: title, streamingServiceUrl: "")
    }

    private func providerOptionIfAvailable(idpId: String) -> LoginProvider? {
        guard !idpId.isEmpty else { return nil }
        return providers.first { $0.idpId == idpId }
    }

    private static func providerOptions(from info: OPNGameProviderInfo) -> [LoginProvider] {
        var seenIdpIds = Set<String>()
        let options = info.endpoints.compactMap { endpoint -> LoginProvider? in
            guard !endpoint.idpId.isEmpty, seenIdpIds.insert(endpoint.idpId).inserted else { return nil }
            return LoginProvider(endpoint: endpoint)
        }
        return options.isEmpty ? [.nvidia] : options
    }

    private static func preferredProvider(in providers: [LoginProvider], info: OPNGameProviderInfo) -> LoginProvider? {
        if info.loginPreferredProviders.count == 1,
           let provider = provider(matching: info.loginPreferredProviders[0], in: providers) {
            return provider
        }
        if let provider = provider(matching: info.loggedInProvider, in: providers) { return provider }
        if let provider = provider(matching: info.defaultProvider, in: providers) { return provider }
        return nil
    }

    private static func provider(matching vendorName: String, in providers: [LoginProvider]) -> LoginProvider? {
        let normalized = vendorName.trimmed.lowercased()
        guard !normalized.isEmpty else { return nil }
        return providers.first { provider in
            provider.loginProvider.lowercased() == normalized ||
            provider.loginProviderCode.lowercased() == normalized ||
            provider.title.lowercased() == normalized
        }
    }

    private func trySave() {
        do {
            try modelContext?.save()
        } catch {
            validationMessage = error.localizedDescription
            OpenNOWLog.error(.app, "SwiftData save failed: \(error.localizedDescription)")
        }
    }

    private static func normalizedEmail(session: JarvisSession, userInfo: JarvisUserInfo?, fallbackEmail: String) -> String {
        let candidate = userInfo?.email.trimmed ?? session.email.trimmed
        let fallback = fallbackEmail.trimmed
        let value = candidate.isEmpty ? fallback : candidate
        if !value.isEmpty { return value.lowercased() }
        if !session.userId.isEmpty { return "\(session.userId.lowercased())@opennow.local" }
        return "opennow-user@opennow.local"
    }

    private static func displayName(session: JarvisSession, userInfo: JarvisUserInfo?, email: String) -> String {
        let candidates = [userInfo?.displayName, userInfo?.preferredUsername, session.displayName]
        if let value = candidates.compactMap({ $0?.trimmed }).first(where: { !$0.isEmpty }) { return value }
        return email.split(separator: "@").first.map { String($0).capitalized } ?? "Player"
    }

    private static func callbackQuery(from text: String) -> String? {
        if let url = URL(string: text), let query = url.query, !query.isEmpty { return query }
        if text.contains("code=") || text.contains("error=") { return text.hasPrefix("?") ? String(text.dropFirst()) : text }
        return nil
    }

    private static func userFacingError(_ error: Error) -> String {
        if let jarvisError = error as? JarvisAuthError { return jarvisError.localizedDescription }
        return error.localizedDescription
    }

    private static func randomOAuthString(length: Int) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct LoginProvider: Identifiable, Hashable, Sendable {
    let idpId: String
    let title: String
    let loginProvider: String
    let loginProviderCode: String
    let streamingServiceUrl: String

    var id: String { idpId }

    init(idpId: String, title: String, loginProvider: String, loginProviderCode: String, streamingServiceUrl: String) {
        self.idpId = idpId
        self.title = title.trimmed.isEmpty ? loginProvider : title.trimmed
        self.loginProvider = loginProvider.trimmed.isEmpty ? self.title : loginProvider.trimmed
        self.loginProviderCode = loginProviderCode.trimmed.isEmpty ? self.loginProvider : loginProviderCode.trimmed
        self.streamingServiceUrl = streamingServiceUrl.trimmed
    }

    init(endpoint: OPNGameProviderEndpoint) {
        self.init(
            idpId: endpoint.idpId,
            title: endpoint.loginProviderDisplayName,
            loginProvider: endpoint.loginProvider,
            loginProviderCode: endpoint.loginProviderCode,
            streamingServiceUrl: endpoint.streamingServiceUrl
        )
    }

    static let nvidia = LoginProvider(
        idpId: Jarvis.defaultIdpId,
        title: "NVIDIA",
        loginProvider: "NVIDIA",
        loginProviderCode: "NVIDIA",
        streamingServiceUrl: "https://prod.cloudmatchbeta.nvidiagrid.net/"
    )
}

enum LoginField: Hashable {
    case email
    case callback
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
