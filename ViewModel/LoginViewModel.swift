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
    /// Which sign-in flow is paused on the terms-of-use gate, resumed once the user accepts.
    private var pendingTermsLaunch: TermsGatedLaunch?
    @Published var requestedFocus: LoginField?
    @Published var currentAuthorizationURL = ""
    @Published var pendingGameShortcut: GFNGameShortcut?
    @Published var deviceCodeUserCode = ""
    @Published var deviceCodeVerificationURI = ""
    @Published var isRequestingDeviceCode = false
    /// Accounts whose keychain tokens are gone — signed out, or forgotten mid-flight. Their rows
    /// stay in the account list forever, so the UI needs this to tell them from switchable ones.
    @Published private(set) var signedOutAccountEmails: Set<String> = []
    /// Set when the login wall has to take over while a session is still active: either a switch
    /// hit an account with no saved session, or another account is being added. Neither touches
    /// the session that is signed in — cancelling returns straight to it.
    @Published private(set) var signInRequest: LoginSignInRequest?
    /// The saved-account chooser, raised either by the startup preference or by "Switch account…".
    /// One value and one panel, because both are the same question asked at different moments.
    /// Driven by the operations in `LoginAccountChooser.swift`.
    @Published var accountChooserReason: AccountChooserReason?
    /// Shown after a switch that left another account's game running, so the reader can tell the
    /// game survived it. Cleared by its own timeout or by the reader dismissing it.
    @Published var accountSwitchNotice: String?

    let authService: any LoginAuthServing
    let providerInfoService: any GameProviderInfoServing
    let jarvisAuthService = JarvisAuthService(transport: JarvisURLSessionTransport())
    /// Application-owned session ownership, so sign-out and removal can refuse to pull the
    /// credentials out from under a game this account is running.
    let sessionRegistry: OPNGameSessionRegistry

    init(authService: any LoginAuthServing = OPNAuthService.shared, providerInfoService: any GameProviderInfoServing = OPNGameService.shared, sessionRegistry: OPNGameSessionRegistry = .shared) {
        self.authService = authService
        self.providerInfoService = providerInfoService
        self.sessionRegistry = sessionRegistry
    }
    var modelContext: ModelContext?
    var accounts: [LoginAccount] = []
    var sessions: [LoginSession] = []
    var devices: [LoginDeviceRegistration] = []
    /// The notice's own timeout, so a second switch replaces the first notice rather than racing it.
    var accountSwitchNoticeTask: Task<Void, Never>?

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
        OPNLog.info(.auth, "Login bootstrap started accounts=\(accounts.count) sessions=\(sessions.count) devices=\(devices.count)")
        ensureDeviceRegistration()
        backfillAccountIdentities()
        prefillLastAccount()
        acceptedTerms = OPNAppPreferenceStorage.standard.bool(forKey: Self.termsAcceptedKey)
        restoreSavedSessionFromKeychain()
        // The sign-in picker is this list's only reader, and a restored session never shows it.
        if activeSession == nil { refreshLoginProviders() }
        // Last, and only when the reader asked to be asked: nothing above this line changes because
        // the chooser is going to be shown.
        presentAccountChooserForStartupIfNeeded()
        OPNLog.info(.auth, "Login bootstrap completed hasActiveSession=\(activeSession != nil) hasPendingOAuth=\(hasPendingOAuth) chooser=\(accountChooserReason != nil)")
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
        let pending = pendingTermsLaunch
        pendingTermsLaunch = nil
        switch pending {
        case .deviceCode:
            launchDeviceCodeOAuth()
        case .oauth, nil:
            launchOAuth()
        }
    }

    func declineTermsOfUse() {
        acceptedTerms = false
        OPNAppPreferenceStorage.standard.removeObject(forKey: Self.termsAcceptedKey)
        isShowingTermsOfUse = false
        pendingTermsLaunch = nil
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

    func launchOAuthThroughTermsGate() {
        guard acceptedTerms else {
            pendingTermsLaunch = .oauth
            presentTermsOfUseIfNeeded()
            return
        }
        launchOAuth()
    }

    func launchDeviceCodeThroughTermsGate() {
        guard acceptedTerms else {
            pendingTermsLaunch = .deviceCode
            presentTermsOfUseIfNeeded()
            return
        }
        launchDeviceCodeOAuth()
    }

    func cancelPendingLogin() {
        guard isLaunchingOAuth || isAuthenticating else { return }
        loginLaunchGeneration += 1
        // Invalidate the in-flight request at its source too: the generation check in the completion
        // runs after a request that may still persist credentials, so cancellation has to reach the
        // service before that persistence.
        authService.invalidatePendingAuthentication()
        isLaunchingOAuth = false
        isAuthenticating = false
        isRequestingDeviceCode = false
        deviceCodeUserCode = ""
        deviceCodeVerificationURI = ""
        validationMessage = "Sign-in cancelled. Choose GET IN to try again."
        OPNLog.info(.auth, "User cancelled pending sign-in")
    }

    func completeOAuthWithCallbackText() {
        Task { await completeOAuth(callbackText: oauthCallbackText) }
    }

    func handleOAuthCallback(_ url: URL) {
        guard url.scheme == "com.nvidia.geforcenow" || url.scheme == "opennow" else { return }
        Task { await completeOAuth(callbackText: url.absoluteString) }
    }

    func handleOpenedFile(_ url: URL) {
        OPNLog.info(.shortcut, "LoginViewModel received opened file: \(url.path)")
        guard GFNGameShortcut.isShortcutFile(url) else {
            OPNLog.info(.shortcut, "Ignoring unsupported opened file: \(url.pathExtension)")
            return
        }
        do {
            pendingGameShortcut = try GFNGameShortcut(fileURL: url)
            if let shortcut = pendingGameShortcut {
                OPNLog.info(.shortcut, "Parsed game shortcut cmsId=\(shortcut.cmsId) shortName=\(shortcut.shortName) parentGameId=\(shortcut.parentGameId) title=\(shortcut.lookupTitle)")
            }
            if activeSession == nil {
                OPNLog.info(.shortcut, "Shortcut parsed but no active session is available")
                validationMessage = "Sign in to launch \(pendingGameShortcut?.lookupTitle.isEmpty == false ? pendingGameShortcut?.lookupTitle ?? "this game" : "this game") from its shortcut."
            } else {
                OPNLog.info(.shortcut, "Shortcut queued for active catalog session")
            }
        } catch {
            OPNLog.error(.shortcut, "Failed to parse game shortcut: \(error.localizedDescription)")
            validationMessage = error.localizedDescription
        }
    }

    func activateAccount(_ account: LoginAccount) {
        dismissAccountChooser()
        // Signing out purges the tokens but keeps the account row, so a listed account is not
        // necessarily a restorable one. Send those to the login wall instead of failing silently.
        guard hasUsableSession(for: account) else {
            beginReauthentication(for: account)
            return
        }
        Task {
            guard await restoreAccountSession(account) else { return }
            announceRunningGameContinues(with: account)
        }
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
        refreshLoginProviders()
        successMessage = ""
        validationMessage = "\(account.displayName) is signed out. Sign in again to switch to it."
        signInRequest = .reauthenticate(email: account.email)
        OPNLog.info(.auth, "Account switch needs re-authentication account=\(account.email)")
    }

    /// The login wall's saved-account row. A restorable account is restored; one whose tokens are
    /// gone starts a fresh sign-in.
    ///
    /// This is deliberately not `activateAccount`: that fallback exists to *send* the user to the
    /// login wall from the catalog, and the row is already there, so reusing it changes state and
    /// starts nothing — a button labelled SIGN IN AGAIN that reads as dead.
    func activateSavedAccount(_ account: LoginAccount) {
        dismissAccountChooser()
        guard hasUsableSession(for: account) else {
            beginSignInAgain(for: account)
            return
        }
        Task {
            guard await restoreAccountSession(account) else { return }
            announceRunningGameContinues(with: account)
        }
    }

    /// Picks the account's provider and starts the browser leg, which is what its row promises.
    func beginSignInAgain(for account: LoginAccount) {
        selectRememberedAccount(account)
        refreshLoginProviders()
        successMessage = ""
        validationMessage = ""
        // Keep a switch banner pointed at the account actually being signed in. Do not invent one
        // when nothing is signed in — there would be no account to return to and nothing to cancel.
        if signInRequest != nil { signInRequest = .reauthenticate(email: account.email) }
        OPNLog.info(.auth, "Signing in again account=\(account.email) provider=\(account.providerIdpId)")
        launchOAuthThroughTermsGate()
    }

    /// Signs in an additional account. The account that is signed in keeps its tokens, so it stays
    /// in the list and switchable once the new one is added.
    func beginAddAccount() {
        dismissAccountChooser()
        email = ""
        selectedProvider = providers.first ?? LoginProvider.nvidia
        rememberSession = true
        successMessage = ""
        validationMessage = ""
        signInRequest = .addAccount
        refreshLoginProviders()
        OPNLog.info(.auth, "Add-account sign-in requested accounts=\(accounts.count)")
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

    func signOut(_ account: LoginAccount) {
        Task { await signOutAccount(account) }
    }

    func refreshActiveSession() async -> Bool {
        guard let activeAccount else { return false }
        return await restoreAccountSession(activeAccount)
    }

    /// Gives every stored row its stable identity, and upgrades a `localOnly` one the first time a
    /// sign-in has supplied the vendor subject. An upgrade carries any session ownership the old key
    /// held, or the game would look like it belonged to an account that no longer resolves.
    func backfillAccountIdentities() {
        guard modelContext != nil else { return }
        var changed = false
        for account in accounts {
            let stored = OPNAccountID(rawValue: account.stableAccountID)
            let resolved = OPNAccountID(providerIdpId: account.providerIdpId, vendorSubject: account.userId, localFallbackSubject: account.email)
            guard let resolved else { continue }
            guard let stored else {
                account.stableAccountID = resolved.rawValue
                changed = true
                continue
            }
            guard stored.basis == .localOnly, resolved.basis == .vendorSubject else { continue }
            account.stableAccountID = resolved.rawValue
            sessionRegistry.rekeyOwnership(from: stored, to: resolved)
            changed = true
        }
        if changed { trySave() }
    }

    func forgetAccount(_ account: LoginAccount) {
        guard let modelContext else { return }
        // Refused before anything is read or deleted: removing the row purges the keychain copy the
        // running game is authenticating with, and the row itself is what a later sign-in would
        // re-key ownership against.
        if let reason = OPNAccountMutationGuard.blockReason(for: account.resolveStableAccountID(), registry: sessionRegistry) {
            validationMessage = reason
            OPNLog.warning(.auth, "Account removal refused because the account owns an active game session account=\(account.email)")
            return
        }
        let email = account.email
        // Read before the delete below: a deleted model must not be touched again.
        let userId = account.userId
        for session in sessions where session.accountEmail == email {
            // Deleting the row alone would orphan the keychain item it points at.
            session.purgeTokens()
            modelContext.delete(session)
        }
        modelContext.delete(account)
        trySave()
        // The auth service holds a second copy of this account's tokens under its own profile
        // identity, which deleting the rows above does not reach.
        authService.endSavedSession(userId: userId, email: email)
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
        OPNLog.info(.auth, "Created login device registration deviceId=\(device.deviceId)")
    }

    private func prefillLastAccount() {
        guard email.isEmpty, let account = accounts.first else { return }
        email = account.email
        selectedProvider = providerOption(idpId: account.providerIdpId, fallbackName: account.providerName)
        rememberSession = account.rememberSession
    }

    func trySave() {
        do {
            try modelContext?.save()
        } catch {
            validationMessage = error.localizedDescription
            OPNLog.error(.app, "SwiftData save failed: \(error.localizedDescription)")
            AuthDiagnosticLog.shared.record("store.save.failed error=\(error.localizedDescription)")
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
        if let jarvisError = error as? JarvisAuthError { return signInGuidance(for: jarvisError.localizedDescription) }
        return signInGuidance(for: error.localizedDescription)
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

/// Why the saved-account chooser is up. The panel is the same either way; the reason is what its
/// cancel means and what the log line records.
enum AccountChooserReason: String, Equatable {
    /// A fresh launch asking, because the reader asked to be asked.
    case startup
    /// The profile menu's "Switch account…".
    case switchAccount
}

/// A sign-in flow awaiting the terms-of-use gate before it can run.
private enum TermsGatedLaunch {
    case oauth
    case deviceCode
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
