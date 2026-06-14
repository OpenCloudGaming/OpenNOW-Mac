//
//  ContentView.swift
//  OpenNOW
//
//  Created by Jayian on 6/14/26.
//

import AppKit
import CryptoKit
import Jarvis
import NesAuth
import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LoginAccount.lastLoginAt, order: .reverse) private var accounts: [LoginAccount]
    @Query(sort: \LoginSession.issuedAt, order: .reverse) private var sessions: [LoginSession]
    @Query private var devices: [LoginDeviceRegistration]

    @State private var email = ""
    @State private var password = ""
    @State private var selectedProvider = LoginProvider.nvidia
    @State private var rememberSession = true
    @State private var acceptedTerms = false
    @State private var isShowingAccountPicker = false
    @State private var validationMessage = ""
    @State private var successMessage = ""
    @State private var isLaunchingOAuth = false

    @FocusState private var focusedField: LoginField?

    private var activeSession: LoginSession? {
        sessions.first { session in
            session.isActive && (!session.isExpired || session.canContinueOffline)
        }
    }

    private var activeAccount: LoginAccount? {
        guard let activeSession else { return nil }
        return accounts.first { $0.email == activeSession.accountEmail }
    }

    var body: some View {
        ZStack {
            LoginBackdrop()
            if let activeAccount, let activeSession {
                SignedInDashboard(
                    account: activeAccount,
                    session: activeSession,
                    accounts: accounts,
                    onSwitch: activateAccount,
                    onSignOut: signOut,
                    onForget: forgetAccount
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                loginWindow
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .task {
            ensureDeviceRegistration()
            prefillLastAccount()
        }
        .animation(.snappy(duration: 0.28), value: activeSession?.id)
    }

    private var loginWindow: some View {
        HStack(spacing: 0) {
            marketingPane
            formPane
        }
        .frame(maxWidth: 1040, maxHeight: 660)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.36), radius: 36, x: 0, y: 24)
        .padding(28)
    }

    private var marketingPane: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 52, height: 52)
                    .background(Color.openNowGreen, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenNOW")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Cloud play, native control")
                        .foregroundStyle(.white.opacity(0.58))
                        .font(.callout)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 14) {
                Text("Sign in to your streaming command center.")
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text("Jarvis OAuth metadata, NES authorization state, and local account continuity are persisted through SwiftData so the frontend can survive restarts cleanly.")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineSpacing(3)
            }

            HStack(spacing: 12) {
                LoginStatCard(title: "Auth", value: JarvisAuthStatus.notLoggedIn.rawValue.replacingOccurrences(of: "_", with: " "))
                LoginStatCard(title: "NES", value: NesAuth.AuthorizationState.authorized.rawValue)
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 12) {
                LoginChecklistItem(icon: "lock.shield.fill", title: "No password persistence", detail: "Credentials are validated for the UI flow and discarded immediately.")
                LoginChecklistItem(icon: "externaldrive.connected.to.line.below.fill", title: "SwiftData sessions", detail: "Remembered accounts, device IDs, and active sessions live in the model container.")
                LoginChecklistItem(icon: "safari.fill", title: "OAuth ready", detail: "The provider button launches a Jarvis-compatible authorization URL.")
            }
        }
        .foregroundStyle(.white)
        .padding(42)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .bottomTrailing) {
                LinearGradient(colors: [.black.opacity(0.84), .black.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Color.openNowGreen.opacity(0.18))
                    .frame(width: 280, height: 280)
                    .blur(radius: 34)
                    .offset(x: 86, y: 76)
                AngularGradient(colors: [.clear, .openNowGreen.opacity(0.28), .clear, .mint.opacity(0.18), .clear], center: .center)
                    .frame(width: 420, height: 420)
                    .blur(radius: 24)
                    .offset(x: 110, y: 90)
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 34, bottomLeadingRadius: 34, bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous))
    }

    private var formPane: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome back")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Choose a provider, continue with a remembered account, or launch browser OAuth.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            if !accounts.isEmpty {
                rememberedAccounts
            }

            VStack(spacing: 14) {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(LoginProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Email address", text: $email)
                    .textFieldStyle(LoginTextFieldStyle(isFocused: focusedField == .email))
                    .focused($focusedField, equals: .email)

                SecureField("Password", text: $password)
                    .textFieldStyle(LoginTextFieldStyle(isFocused: focusedField == .password))
                    .focused($focusedField, equals: .password)
                    .onSubmit(signInWithPassword)
            }

            VStack(spacing: 12) {
                Toggle("Remember this account on this Mac", isOn: $rememberSession)
                Toggle("I agree to the NVIDIA account terms and OpenNOW session storage", isOn: $acceptedTerms)
            }
            .toggleStyle(.checkbox)
            .font(.callout)

            VStack(spacing: 12) {
                Button(action: signInWithPassword) {
                    Label("Continue", systemImage: "arrow.right.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryLoginButtonStyle())
                .disabled(!canSubmitPassword)

                Button(action: launchOAuth) {
                    HStack {
                        if isLaunchingOAuth {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "safari.fill")
                        }
                        Text("Sign in with NVIDIA OAuth")
                        Spacer()
                        Image(systemName: "arrow.up.forward.app.fill")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryLoginButtonStyle())
                .disabled(isLaunchingOAuth || !acceptedTerms)
            }

            VStack(alignment: .leading, spacing: 8) {
                if !validationMessage.isEmpty {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if !successMessage.isEmpty {
                    Label(successMessage, systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.openNowGreen)
                }
            }
            .font(.callout)
            .frame(minHeight: 46, alignment: .topLeading)

            Spacer()

            HStack {
                Label(primaryDevice.displayName, systemImage: "macbook.and.iphone")
                Spacer()
                Text("Device ID saved in SwiftData")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(38)
        .frame(width: 430, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 34, topTrailingRadius: 34, style: .continuous))
    }

    private var rememberedAccounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remembered accounts")
                    .font(.headline)
                Spacer()
                Button(isShowingAccountPicker ? "Hide" : "Show") {
                    withAnimation(.snappy) {
                        isShowingAccountPicker.toggle()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.openNowGreen)
            }

            if isShowingAccountPicker {
                VStack(spacing: 8) {
                    ForEach(accounts.prefix(4)) { account in
                        Button {
                            email = account.email
                            selectedProvider = LoginProvider(idpId: account.providerIdpId) ?? .nvidia
                            rememberSession = account.rememberSession
                            focusedField = .password
                        } label: {
                            HStack(spacing: 12) {
                                AccountAvatar(name: account.displayName)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.displayName)
                                        .foregroundStyle(.primary)
                                    Text(account.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(account.membershipTier)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.openNowGreen.opacity(0.14), in: Capsule())
                            }
                            .padding(10)
                            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var canSubmitPassword: Bool {
        !email.trimmed.isEmpty && !password.isEmpty && acceptedTerms
    }

    private var primaryDevice: LoginDeviceRegistration {
        devices.first ?? LoginDeviceRegistration()
    }

    private func signInWithPassword() {
        validationMessage = ""
        successMessage = ""

        guard isValidEmail(email.trimmed) else {
            validationMessage = "Enter a valid email address."
            focusedField = .email
            return
        }
        guard password.count >= 8 else {
            validationMessage = "Password must be at least 8 characters."
            focusedField = .password
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

    private func launchOAuth() {
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

    private func persistSignedInSession(authMethod: String, accessTokenPrefix: String) {
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
        primaryDevice.lastUsedAt = now
        trySave()
    }

    private func activateAccount(_ account: LoginAccount) {
        email = account.email
        selectedProvider = LoginProvider(idpId: account.providerIdpId) ?? .nvidia
        acceptedTerms = true
        rememberSession = account.rememberSession
        persistSignedInSession(authMethod: "Remembered", accessTokenPrefix: "remembered")
    }

    private func signOut() {
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

    private func forgetAccount(_ account: LoginAccount) {
        for session in sessions where session.accountEmail == account.email {
            modelContext.delete(session)
        }
        modelContext.delete(account)
        trySave()
    }

    private func ensureDeviceRegistration() {
        guard devices.isEmpty else { return }
        modelContext.insert(LoginDeviceRegistration())
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
            try modelContext.save()
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

private struct SignedInDashboard: View {
    let account: LoginAccount
    let session: LoginSession
    let accounts: [LoginAccount]
    let onSwitch: (LoginAccount) -> Void
    let onSignOut: () -> Void
    let onForget: (LoginAccount) -> Void

    var body: some View {
        VStack(spacing: 22) {
            HStack {
                HStack(spacing: 16) {
                    AccountAvatar(name: account.displayName, size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ready to play")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("\(account.displayName) signed in with \(account.providerName)")
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Sign Out", action: onSignOut)
                    .buttonStyle(SecondaryLoginButtonStyle(compact: true))
            }

            HStack(spacing: 16) {
                SessionMetric(title: "Membership", value: account.membershipTier, symbol: "crown.fill")
                SessionMetric(title: "Auth", value: account.authStatus.replacingOccurrences(of: "_", with: " "), symbol: "checkmark.shield.fill")
                SessionMetric(title: "Client Token", value: session.clientTokenExpiresAt.formatted(date: .omitted, time: .shortened), symbol: "timer")
                SessionMetric(title: "Session", value: session.expiresAt.formatted(date: .abbreviated, time: .shortened), symbol: "calendar.badge.clock")
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Session details")
                        .font(.title2.bold())
                    DetailRow(label: "Email", value: account.email)
                    DetailRow(label: "Provider ID", value: account.providerIdpId)
                    DetailRow(label: "Device ID", value: session.deviceId)
                    DetailRow(label: "Auth method", value: session.authMethod)
                    DetailRow(label: "Offline continue", value: session.canContinueOffline ? "Enabled" : "Disabled")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

                VStack(alignment: .leading, spacing: 14) {
                    Text("Account switcher")
                        .font(.title2.bold())
                    ForEach(accounts) { switchAccount in
                        HStack(spacing: 12) {
                            AccountAvatar(name: switchAccount.displayName, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(switchAccount.displayName)
                                Text(switchAccount.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if switchAccount.email == account.email {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.openNowGreen)
                            } else {
                                Button("Use") { onSwitch(switchAccount) }
                                    .buttonStyle(.bordered)
                            }
                            Button(role: .destructive) {
                                onForget(switchAccount)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(12)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(24)
                .frame(width: 360, alignment: .topLeading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            }

            Spacer()
        }
        .padding(34)
        .frame(maxWidth: 1040, maxHeight: 660)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.32), radius: 34, x: 0, y: 22)
        .padding(28)
    }
}

private struct LoginBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.03, blue: 0.025), Color(red: 0.05, green: 0.07, blue: 0.06), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.openNowGreen.opacity(0.22), .clear], center: .topTrailing, startRadius: 20, endRadius: 560)
            RadialGradient(colors: [.cyan.opacity(0.14), .clear], center: .bottomLeading, startRadius: 20, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

private struct LoginStatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.48))
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct LoginChecklistItem: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Color.openNowGreen)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
            }
        }
    }
}

private struct SessionMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(Color.openNowGreen)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

private struct AccountAvatar: View {
    let name: String
    var size: CGFloat = 42

    private var initials: String {
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap { $0.first }
        let fallback = name.first.map(String.init) ?? "O"
        let value = letters.isEmpty ? fallback : String(letters)
        return value.uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(.black)
            .frame(width: size, height: size)
            .background(Color.openNowGreen, in: RoundedRectangle(cornerRadius: size * 0.32, style: .continuous))
    }
}

private struct LoginTextFieldStyle: TextFieldStyle {
    let isFocused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isFocused ? Color.openNowGreen : .white.opacity(0.10), lineWidth: isFocused ? 1.5 : 1)
            }
    }
}

private struct PrimaryLoginButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.vertical, 13)
            .background(configuration.isPressed ? Color.openNowGreen.opacity(0.76) : Color.openNowGreen, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

private struct SecondaryLoginButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .callout.weight(.semibold) : .headline)
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 14 : 16)
            .padding(.vertical, compact ? 8 : 12)
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: compact ? 12 : 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 12 : 15, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private enum LoginProvider: String, CaseIterable, Identifiable {
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

private enum LoginField: Hashable {
    case email
    case password
}

private extension Color {
    static let openNowGreen = Color(red: 0.46, green: 0.90, blue: 0.10)
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [LoginAccount.self, LoginSession.self, LoginDeviceRegistration.self], inMemory: true)
}
