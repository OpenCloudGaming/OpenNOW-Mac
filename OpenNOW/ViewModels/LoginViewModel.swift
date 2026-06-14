//
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
    @Published var password = ""
    @Published var selectedProvider = LoginProvider.nvidia
    @Published var rememberSession = true
    @Published var acceptedTerms = false
    @Published var isShowingAccountPicker = false
    @Published var validationMessage = ""
    @Published var successMessage = ""
    @Published var isLaunchingOAuth = false
    @Published var requestedFocus: LoginField?

    private var modelContext: ModelContext?
    private var accounts: [LoginAccount] = []
    private var sessions: [LoginSession] = []
    private var devices: [LoginDeviceRegistration] = []

    var authStatusSummary: String {
        JarvisAuthStatus.notLoggedIn.rawValue.replacingOccurrences(of: "_", with: " ")
    }

    var nesAuthorizationSummary: String {
        NesAuth.AuthorizationState.authorized.rawValue
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

    var canSubmitPassword: Bool {
        !email.trimmed.isEmpty && !password.isEmpty && acceptedTerms
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
        requestedFocus = .password
    }

    func signInWithPassword() {
        validationMessage = ""
        successMessage = ""

        guard isValidEmail(email.trimmed) else {
            validationMessage = "Enter a valid email address."
            requestedFocus = .email
            return
        }
        guard password.count >= 8 else {
            validationMessage = "Password must be at least 8 characters."
            requestedFocus = .password
            return
        }
        guard acceptedTerms else {
            validationMessage = "Accept the account and storage terms to continue."
            return
        }

        persistSignedInSession(authMethod: "Password", accessTokenPrefix: "local")
        password = ""
        successMessage = "Signed in and stored in SwiftData."
    }

    func launchOAuth() {
        validationMessage = ""
        successMessage = ""

        guard acceptedTerms else {
            validationMessage = "Accept the account and storage terms before opening OAuth."
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
        let locale = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
        guard let url = JarvisOAuthRequestFactory.authorizationURL(
            deviceId: primaryDevice.deviceId,
            redirectURI: JarvisOAuthConfiguration.gfnPC.redirectURI,
            locale: locale,
            oauthState: state,
            providerIdpId: selectedProvider.idpId
        ) else {
            validationMessage = "Unable to build the Jarvis OAuth URL."
            return
        }

        primaryDevice.lastUsedAt = Date()
        trySave()
        NSWorkspace.shared.open(url)
        validationMessage = "OAuth opened in your browser. Complete sign-in there, then return to OpenNOW."
    }

    func activateAccount(_ account: LoginAccount) {
        email = account.email
        selectedProvider = LoginProvider(idpId: account.providerIdpId) ?? .nvidia
        acceptedTerms = true
        rememberSession = account.rememberSession
        persistSignedInSession(authMethod: "Remembered", accessTokenPrefix: "remembered")
    }

    func signOut() {
        for account in accounts {
            account.isActive = false
            account.authStatus = JarvisAuthStatus.notLoggedIn.rawValue
        }
        for session in sessions {
            session.isActive = false
        }
        trySave()
        successMessage = "Signed out."
    }

    func forgetAccount(_ account: LoginAccount) {
        guard let modelContext else { return }
        for session in sessions where session.accountEmail == account.email {
            modelContext.delete(session)
        }
        modelContext.delete(account)
        trySave()
    }

    private func persistSignedInSession(authMethod: String, accessTokenPrefix: String) {
        guard let modelContext else {
            validationMessage = "SwiftData context is unavailable."
            return
        }

        let now = Date()
        let normalizedEmail = email.trimmed.lowercased()
        let displayName = normalizedEmail.split(separator: "@").first.map { String($0).capitalized } ?? "Player"

        for account in accounts {
            account.isActive = false
        }
        for session in sessions {
            session.isActive = false
        }

        let account: LoginAccount
        if let existingAccount = accounts.first(where: { $0.email == normalizedEmail }) {
            account = existingAccount
        } else {
            account = LoginAccount(
                email: normalizedEmail,
                displayName: displayName,
                providerIdpId: selectedProvider.idpId,
                providerName: selectedProvider.title
            )
            modelContext.insert(account)
            accounts.insert(account, at: 0)
        }

        account.displayName = displayName
        account.providerIdpId = selectedProvider.idpId
        account.providerName = selectedProvider.title
        account.membershipTier = "Founders"
        account.authorizationState = NesAuth.AuthorizationState.authorized.rawValue
        account.authStatus = JarvisAuthStatus.loggedIn.rawValue
        account.lastLoginAt = now
        account.rememberSession = rememberSession
        account.isActive = true

        let expiry = Calendar.current.date(byAdding: .day, value: rememberSession ? 30 : 1, to: now) ?? now.addingTimeInterval(86_400)
        let clientExpiry = Calendar.current.date(byAdding: .hour, value: 12, to: now) ?? now.addingTimeInterval(43_200)
        let tokenSeed = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let session = LoginSession(
            accountEmail: normalizedEmail,
            authMethod: authMethod,
            accessToken: "\(accessTokenPrefix)-access-\(tokenSeed)",
            clientToken: "\(accessTokenPrefix)-client-\(tokenSeed)",
            idToken: "\(accessTokenPrefix)-id-\(tokenSeed)",
            deviceId: primaryDevice.deviceId,
            issuedAt: now,
            expiresAt: expiry,
            clientTokenExpiresAt: clientExpiry,
            isActive: true,
            canContinueOffline: rememberSession
        )
        modelContext.insert(session)
        sessions.insert(session, at: 0)
        primaryDevice.lastUsedAt = now
        trySave()
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

    private func isValidEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@")
        guard parts.count == 2 else { return false }
        return parts[0].count >= 1 && parts[1].contains(".")
    }

    private func trySave() {
        do {
            try modelContext?.save()
        } catch {
            validationMessage = error.localizedDescription
        }
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
    case password
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
