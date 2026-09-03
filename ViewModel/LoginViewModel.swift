import Combine
import CryptoKit
import Foundation
import SwiftData

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var email = ""
    @Published var oauthCallbackText = ""
    @Published var providers = [LoginProvider.nvidia]
    @Published var selectedProvider = LoginProvider.nvidia
    @Published var rememberSession = true
    @Published var acceptedTerms = false
    @Published var isShowingTermsOfUse = false
    @Published var validationMessage = ""
    @Published var successMessage = ""
    @Published var isLoadingProviders = false
    @Published var isLaunchingOAuth = false
    @Published var isAuthenticating = false
    var loginLaunchGeneration = 0
    @Published var requestedFocus: LoginField?
    @Published var currentAuthorizationURL = ""
    @Published var pendingGameShortcut: GFNGameShortcut?
    @Published var deviceCodeUserCode = ""
    @Published var deviceCodeVerificationURI = ""
    /// Accounts whose keychain tokens are gone — signed out, or forgotten mid-flight. Their rows
    /// stay in the account list forever, so the UI needs this to tell them from switchable ones.
    @Published private(set) var signedOutAccountEmails: Set<String> = []
    /// Set when the login wall has to take over while a session is still active: either a switch
    /// hit an account with no saved session, or another account is being added. Neither touches
    /// the session that is signed in — cancelling returns straight to it.
    @Published private(set) var signInRequest: LoginSignInRequest?

    let authService: any LoginAuthServing
    private let providerInfoService: any GameProviderInfoServing
    let jarvisAuthService = JarvisAuthService(transport: JarvisURLSessionTransport())

    init(authService: any LoginAuthServing = OPNAuthService.shared, providerInfoService: any GameProviderInfoServing = OPNGameService.shared) {
        self.authService = authService
        self.providerInfoService = providerInfoService
    }
    var modelContext: ModelContext?
    var accounts: [LoginAccount] = []
    var sessions: [LoginSession] = []
    var devices: [LoginDeviceRegistration] = []

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
        refreshSignedOutAccounts()
    }

    func bootstrap() {
        OpenNOWLog.info(.auth, "Login bootstrap started accounts=\(accounts.count) sessions=\(sessions.count) devices=\(devices.count)")
        ensureDeviceRegistration()
        prefillLastAccount()
        refreshLoginProviders()
        acceptedTerms = OPNAppPreferenceStorage.standard.bool(forKey: Self.termsAcceptedKey)
        OpenNOWLog.info(.auth, "Login bootstrap completed hasActiveSession=\(activeSession != nil) hasPendingOAuth=\(hasPendingOAuth)")
    }

    private static let termsAcceptedKey = "OpenNOW.Login.GFNTermsAccepted"

    func presentTermsOfUseIfNeeded() {
        guard !acceptedTerms else { return }
        isShowingTermsOfUse = true
    }

    func acceptTermsOfUse() {
        acceptedTerms = true
        OPNAppPreferenceStorage.standard.set(true, forKey: Self.termsAcceptedKey)
        isShowingTermsOfUse = false
        launchOAuth()
    }

    func declineTermsOfUse() {
        acceptedTerms = false
        OPNAppPreferenceStorage.standard.removeObject(forKey: Self.termsAcceptedKey)
        isShowingTermsOfUse = false
        validationMessage = "You must accept the GeForce NOW Terms of Use to continue."
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

    func launchDeviceCodeOAuth() {
        Task { await beginDeviceCodeOAuth() }
    }

    func cancelPendingLogin() {
        guard isLaunchingOAuth || isAuthenticating else { return }
        loginLaunchGeneration += 1
        isLaunchingOAuth = false
        isAuthenticating = false
        deviceCodeUserCode = ""
        deviceCodeVerificationURI = ""
        validationMessage = "Sign-in cancelled. Choose GET IN to try again."
        OpenNOWLog.info(.auth, "User cancelled pending sign-in")
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
        // Signing out purges the tokens but keeps the account row, so a listed account is not
        // necessarily a restorable one. Send those to the login wall instead of failing silently.
        guard hasUsableSession(for: account) else {
            beginReauthentication(for: account)
            return
        }
        Task { _ = await restoreAccountSession(account) }
    }

    func hasUsableSession(for account: LoginAccount) -> Bool {
        sessions.contains { $0.accountEmail == account.email && !$0.accessToken.isEmpty }
    }

    func refreshSignedOutAccounts() {
        signedOutAccountEmails = Set(accounts.filter { !hasUsableSession(for: $0) }.map(\.email))
    }

    var reauthAccountEmail: String? {
        guard case .reauthenticate(let email) = signInRequest else { return nil }
        return email
    }

    var reauthAccount: LoginAccount? {
        guard let reauthAccountEmail else { return nil }
        return accounts.first { $0.email == reauthAccountEmail }
    }

    var isAddingAccount: Bool { signInRequest == .addAccount }

    /// Another account is still signed in, so cancelling the re-sign-in has a session to return to.
    var canCancelReauthentication: Bool { activeSession != nil }

    func beginReauthentication(for account: LoginAccount) {
        selectRememberedAccount(account)
        successMessage = ""
        validationMessage = "\(account.displayName) is signed out. Sign in again to switch to it."
        signInRequest = .reauthenticate(email: account.email)
        OpenNOWLog.info(.auth, "Account switch needs re-authentication account=\(account.email)")
    }

    /// Signs in an additional account. The account that is signed in keeps its tokens, so it stays
    /// in the list and switchable once the new one is added.
    func beginAddAccount() {
        email = ""
        selectedProvider = providers.first ?? LoginProvider.nvidia
        rememberSession = true
        successMessage = ""
        validationMessage = ""
        signInRequest = .addAccount
        OpenNOWLog.info(.auth, "Add-account sign-in requested accounts=\(accounts.count)")
    }

    func cancelReauthentication() {
        guard signInRequest != nil else { return }
        signInRequest = nil
        validationMessage = ""
        successMessage = ""
    }

    func signOut() {
        Task { await signOutCurrentSession() }
    }

    func refreshActiveSession() async -> Bool {
        guard let activeAccount else { return false }
        return await restoreAccountSession(activeAccount)
    }

    func forgetAccount(_ account: LoginAccount) {
        guard let modelContext else { return }
        let email = account.email
        for session in sessions where session.accountEmail == email {
            // Deleting the row alone would orphan the keychain item it points at.
            session.purgeTokens()
            modelContext.delete(session)
        }
        modelContext.delete(account)
        trySave()
        // Drop the deleted models here too: the @Query refresh that would do it is asynchronous,
        // and anything reading these arrays before it lands would touch a deleted object.
        accounts.removeAll { $0.email == email }
        sessions.removeAll { $0.accountEmail == email }
        if reauthAccountEmail == email { signInRequest = nil }
        refreshSignedOutAccounts()
    }

    func markActive(accountEmail: String) {
        for account in accounts {
            account.isActive = account.email == accountEmail
            account.authStatus = account.isActive ? JarvisAuthStatus.loggedIn.rawValue : JarvisAuthStatus.notLoggedIn.rawValue
        }
        for session in sessions {
            session.isActive = session.accountEmail == accountEmail
        }
    }

    func clearPendingOAuthState() {
        primaryDevice.pendingOAuthState = ""
        primaryDevice.pendingOAuthCodeVerifier = ""
        primaryDevice.pendingOAuthProviderIdpId = ""
        primaryDevice.pendingOAuthRedirectURI = ""
        deviceCodeUserCode = ""
        deviceCodeVerificationURI = ""
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
        providerInfoService.fetchProviderInfo(idpId: requestedProviderIdpId) { [weak self] success, info, _, error in
            guard let self else { return }
            self.isLoadingProviders = false
            guard success else {
                OpenNOWLog.warning(.auth, "Provider discovery failed: \(error)")
                return
            }
            self.applyProviderInfo(info)
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

    func providerOption(idpId: String, fallbackName: String = "") -> LoginProvider {
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

    func trySave() {
        do {
            try modelContext?.save()
        } catch {
            validationMessage = error.localizedDescription
            OpenNOWLog.error(.app, "SwiftData save failed: \(error.localizedDescription)")
        }
    }

    static func normalizedEmail(session: JarvisSession, userInfo: JarvisUserInfo?, fallbackEmail: String) -> String {
        let candidate = userInfo?.email.trimmed ?? session.email.trimmed
        let fallback = fallbackEmail.trimmed
        let value = candidate.isEmpty ? fallback : candidate
        if !value.isEmpty { return value.lowercased() }
        if !session.userId.isEmpty { return "\(session.userId.lowercased())@opennow.local" }
        return "opennow-user@opennow.local"
    }

    static func displayName(session: JarvisSession, userInfo: JarvisUserInfo?, email: String) -> String {
        let candidates = [userInfo?.displayName, userInfo?.preferredUsername, session.displayName]
        if let value = candidates.compactMap({ $0?.trimmed }).first(where: { !$0.isEmpty }) { return value }
        return email.split(separator: "@").first.map { String($0).capitalized } ?? "Player"
    }

    static func callbackQuery(from text: String) -> String? {
        if let url = URL(string: text), let query = url.query, !query.isEmpty { return query }
        if text.contains("code=") || text.contains("error=") { return text.hasPrefix("?") ? String(text.dropFirst()) : text }
        return nil
    }

    static func userFacingError(_ error: Error) -> String {
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

/// Why the login wall is showing while a session may still be active.
enum LoginSignInRequest: Equatable {
    case reauthenticate(email: String)
    case addAccount
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
