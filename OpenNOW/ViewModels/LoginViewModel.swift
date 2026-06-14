//  LoginViewModel.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import Combine
import CryptoKit
import Foundation
import Jarvis
import NesAuth
import SwiftData
import SwiftUI

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var email = ""
    @Published var oauthCallbackText = ""
    @Published var selectedProvider = LoginProvider.nvidia
    @Published var rememberSession = true
    @Published var acceptedTerms = false
    @Published var isShowingAccountPicker = false
    @Published var validationMessage = ""
    @Published var successMessage = ""
    @Published var isLaunchingOAuth = false
    @Published var isAuthenticating = false
    @Published var requestedFocus: LoginField?
    @Published var currentAuthorizationURL = ""

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
        ensureDeviceRegistration()
        prefillLastAccount()
    }

    func toggleAccountPicker() {
        withAnimation(.snappy) {
            isShowingAccountPicker.toggle()
        }
    }

    func selectRememberedAccount(_ account: LoginAccount) {
        email = account.email
        selectedProvider = LoginProvider(idpId: account.providerIdpId) ?? .nvidia
        rememberSession = account.rememberSession
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

    func activateAccount(_ account: LoginAccount) {
        Task { await restoreAccountSession(account) }
    }

    func signOut() {
        Task { await signOutCurrentSession() }
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

        guard acceptedTerms else {
            validationMessage = "Accept NVIDIA account terms and local session storage before continuing."
            return
        }

        isLaunchingOAuth = true
        defer { isLaunchingOAuth = false }

        let verifier = Self.randomOAuthString(length: 64)
        let state = JarvisOAuthState(
            codeVerifier: verifier,
            codeChallenge: Self.codeChallenge(for: verifier),
            state: Self.randomOAuthString(length: 32),
            nonce: Self.randomOAuthString(length: 32)
        )
        let redirectURI = JarvisOAuthConfiguration.gfnPC.redirectURI
        let locale = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")

        do {
            let request = try await jarvisAuthService.createOAuthLoginRequest(
                deviceId: primaryDevice.deviceId,
                redirectURI: redirectURI,
                locale: locale,
                oauthState: state,
                providerIdpId: selectedProvider.idpId,
                useAppURL: true
            )
            primaryDevice.pendingOAuthState = state.state
            primaryDevice.pendingOAuthCodeVerifier = verifier
            primaryDevice.pendingOAuthProviderIdpId = selectedProvider.idpId
            primaryDevice.pendingOAuthRedirectURI = redirectURI
            primaryDevice.lastUsedAt = Date()
            currentAuthorizationURL = request.url.absoluteString
            trySave()
            _ = await jarvisAuthService.sameTabAuthStarted()
            NSWorkspace.shared.open(request.url)
            validationMessage = "Finish NVIDIA sign-in in the browser. OpenNOW will continue automatically when the callback returns."
        } catch {
            validationMessage = Self.userFacingError(error)
        }
    }

    private func completeOAuth(callbackText: String) async {
        validationMessage = ""
        successMessage = ""

        let device = primaryDevice
        guard !device.pendingOAuthState.isEmpty, !device.pendingOAuthCodeVerifier.isEmpty else {
            validationMessage = "Start browser sign-in before completing authorization."
            return
        }

        guard let query = Self.callbackQuery(from: callbackText.trimmed) else {
            validationMessage = "Paste the full callback URL or authorization query from NVIDIA."
            requestedFocus = .callback
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

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
            successMessage = "NVIDIA account connected. Client token and session metadata are ready."
        } catch {
            _ = await jarvisAuthService.finishLogin(success: false)
            validationMessage = Self.userFacingError(error)
            requestedFocus = .callback
        }
    }

    private func restoreAccountSession(_ account: LoginAccount) async {
        validationMessage = ""
        successMessage = ""
        email = account.email
        selectedProvider = LoginProvider(idpId: account.providerIdpId) ?? .nvidia
        rememberSession = account.rememberSession

        guard let storedSession = sessions.first(where: { $0.accountEmail == account.email && !$0.accessToken.isEmpty }) else {
            validationMessage = "No saved session exists for this account. Sign in with NVIDIA again."
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
            await jarvisAuthService.setSession(jarvisSession)
            let refreshed = try await jarvisAuthService.refreshSession(force: false)
            persistSignedInSession(session: refreshed, userInfo: nil, authMethod: Jarvis.Operation.getSessionToken.rawValue)
            successMessage = "Session refreshed for \(account.displayName)."
        } catch {
            if storedSession.canContinueOffline && !storedSession.isExpired {
                markActive(accountEmail: account.email)
                trySave()
                successMessage = "Using saved offline session for \(account.displayName)."
            } else {
                validationMessage = "Saved session expired. Sign in with NVIDIA again."
            }
        }
    }

    private func signOutCurrentSession() async {
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
    }

    private func persistSignedInSession(session: JarvisSession, userInfo: JarvisUserInfo?, authMethod: String) {
        guard let modelContext else {
            validationMessage = "SwiftData context is unavailable."
            return
        }

        let now = Date()
        let normalizedEmail = Self.normalizedEmail(session: session, userInfo: userInfo, fallbackEmail: email)
        let displayName = Self.displayName(session: session, userInfo: userInfo, email: normalizedEmail)
        let providerIdpId = session.idpId.isEmpty ? selectedProvider.idpId : session.idpId

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
                providerName: selectedProvider.title
            )
            modelContext.insert(account)
            accounts.insert(account, at: 0)
        }

        let authorization = NesAuthorizationPolicy().result(authType: JarvisAuthType.jwtGFN.rawValue)
        account.displayName = displayName
        account.providerIdpId = providerIdpId
        account.providerName = LoginProvider(idpId: providerIdpId)?.title ?? selectedProvider.title
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
        let storedSession = LoginSession(
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
        modelContext.insert(storedSession)
        sessions.insert(storedSession, at: 0)
        primaryDevice.lastUsedAt = now
        trySave()
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
    }

    private func prefillLastAccount() {
        guard email.isEmpty, let account = accounts.first else { return }
        email = account.email
        selectedProvider = LoginProvider(idpId: account.providerIdpId) ?? .nvidia
        rememberSession = account.rememberSession
    }

    private func trySave() {
        do {
            try modelContext?.save()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private static func normalizedEmail(session: JarvisSession, userInfo: JarvisUserInfo?, fallbackEmail: String) -> String {
        let candidate = userInfo?.email.trimmed ?? session.email.trimmed
        let fallback = fallbackEmail.trimmed
        let value = candidate.isEmpty ? fallback : candidate
        if !value.isEmpty { return value.lowercased() }
        if !session.userId.isEmpty { return "\(session.userId.lowercased())@nvidia.local" }
        return "nvidia-user@opennow.local"
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

enum LoginProvider: String, CaseIterable, Identifiable {
    case nvidia
    case xbox
    case ubisoft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nvidia: "NVIDIA"
        case .xbox: "Xbox"
        case .ubisoft: "Ubisoft"
        }
    }

    var idpId: String {
        switch self {
        case .nvidia: Jarvis.defaultIdpId
        case .xbox: "xbox-live"
        case .ubisoft: "ubisoft-connect"
        }
    }

    init?(idpId: String) {
        guard let provider = Self.allCases.first(where: { $0.idpId == idpId }) else { return nil }
        self = provider
    }
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
