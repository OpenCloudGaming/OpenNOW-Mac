//
//  LoginOAuthFlow.swift
//  OpenNOW
//
//  The sign-in flows: browser OAuth, the device-code flow, and restoring or ending a session.
//  Split out of LoginViewModel.swift.
//

import Combine
import CryptoKit
import Foundation
import SwiftData

extension LoginViewModel {
    func beginOAuth() async {
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

        let generation = loginLaunchGeneration
        authService.startOAuthLogin(providerIdpId: loginProvider.idpId) { [weak self] success, session, error in
            guard let self, generation == self.loginLaunchGeneration else { return }
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

            Task { @MainActor in
                await self.jarvisAuthService.setSession(session)
                self.persistSignedInSession(session: session, userInfo: nil, authMethod: Jarvis.Operation.getSessionToken.rawValue)
                self.validationMessage = ""
                self.successMessage = "\(loginProvider.title) account connected. Client token and session metadata are ready."
                OpenNOWLog.info(.auth, "OAuth start completed provider=\(loginProvider.idpId)")
            }
        }
    }

    func beginDeviceCodeOAuth() async {
        validationMessage = ""
        successMessage = ""
        deviceCodeUserCode = ""
        deviceCodeVerificationURI = ""
        let loginProvider = selectedProvider
        OpenNOWLog.info(.auth, "Beginning Starfleet device-code OAuth provider=\(loginProvider.idpId)")

        guard acceptedTerms else {
            OpenNOWLog.warning(.auth, "Device-code OAuth blocked because terms were not accepted")
            validationMessage = "Accept account terms and local session storage before continuing."
            return
        }

        isLaunchingOAuth = true
        validationMessage = "Enter the device code in your browser to connect \(loginProvider.title)."

        let generation = loginLaunchGeneration
        authService.startStarfleetDeviceCodeLogin(providerIdpId: loginProvider.idpId) { [weak self] challenge in
            guard let self, generation == self.loginLaunchGeneration else { return }
            self.isLaunchingOAuth = false
            self.deviceCodeUserCode = challenge.userCode
            self.deviceCodeVerificationURI = challenge.verificationURIComplete.isEmpty ? challenge.verificationURI : challenge.verificationURIComplete
            self.validationMessage = "Enter code \(challenge.userCode) at \(self.deviceCodeVerificationURI)."
        } completion: { [weak self] success, session, error in
            guard let self, generation == self.loginLaunchGeneration else { return }
            self.selectedProvider = loginProvider
            self.isLaunchingOAuth = false
            self.currentAuthorizationURL = ""
            self.clearPendingOAuthState()
            self.oauthCallbackText = ""

            guard success else {
                self.validationMessage = error.isEmpty ? "\(loginProvider.title) device-code sign-in failed." : error
                OpenNOWLog.error(.auth, "Device-code OAuth failed provider=\(loginProvider.idpId) error=\(self.validationMessage)")
                return
            }

            Task { @MainActor in
                await self.jarvisAuthService.setSession(session)
                self.persistSignedInSession(session: session, userInfo: nil, authMethod: "Starfleet_Device_Code")
                self.validationMessage = ""
                self.successMessage = "\(loginProvider.title) account connected with device code."
                self.deviceCodeUserCode = ""
                self.deviceCodeVerificationURI = ""
                OpenNOWLog.info(.auth, "Device-code OAuth completed provider=\(loginProvider.idpId)")
            }
        }
    }

    func completeOAuth(callbackText: String) async {
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

    @discardableResult
    func restoreAccountSession(_ account: LoginAccount) async -> Bool {
        validationMessage = ""
        successMessage = ""
        email = account.email
        selectedProvider = providerOption(idpId: account.providerIdpId, fallbackName: account.providerName)
        rememberSession = account.rememberSession

        guard let storedSession = sessions.first(where: { $0.accountEmail == account.email && !$0.accessToken.isEmpty }) else {
            OpenNOWLog.warning(.auth, "Session restore failed because no saved session exists for account=\(account.email)")
            validationMessage = "No saved session exists for this account. Sign in again."
            return false
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
            return true
        } catch {
            if storedSession.canContinueOffline && !storedSession.isExpired {
                markActive(accountEmail: account.email)
                trySave()
                refreshSignedOutAccounts()
                successMessage = "Using saved offline session for \(account.displayName)."
                OpenNOWLog.warning(.auth, "Using offline saved session account=\(account.email) refreshError=\(error.localizedDescription)")
                return true
            } else {
                validationMessage = "Saved session expired. Sign in again."
                OpenNOWLog.warning(.auth, "Session restore failed account=\(account.email) error=\(error.localizedDescription)")
                return false
            }
        }
    }

    func signOutCurrentSession() async {
        OpenNOWLog.info(.auth, "Signing out current session")
        let signedOutEmails = Set(accounts.filter(\.isActive).map(\.email))
        for account in accounts {
            account.isActive = false
            account.authStatus = JarvisAuthStatus.notLoggedIn.rawValue
        }
        for session in sessions {
            session.isActive = false
            // Signing out has to revoke the local grant, not just hide it: the refresh token
            // outlives the access token by far, so leaving it behind means sign-out never happened.
            // Other saved accounts keep their tokens — they were not the ones signed out.
            if signedOutEmails.contains(session.accountEmail) { session.purgeTokens() }
        }
        clearPendingOAuthState()
        currentAuthorizationURL = ""
        oauthCallbackText = ""
        trySave()
        cancelReauthentication()
        refreshSignedOutAccounts()
        await jarvisAuthService.clearSession()
        successMessage = "Signed out."
        OpenNOWLog.info(.auth, "Sign out completed")
    }
}
