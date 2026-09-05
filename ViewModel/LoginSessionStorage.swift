//  Persisting a signed-in session: the account row, the session row and which of them is active.
//

import Combine
import CryptoKit
import Foundation
import SwiftData

extension LoginViewModel {
    func persistSignedInSession(session: JarvisSession, userInfo: JarvisUserInfo?, authMethod: String) {
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

        updateAccount(account,
                      session: session,
                      userInfo: userInfo,
                      displayName: displayName,
                      providerIdpId: providerIdpId,
                      providerName: resolvedProvider.title,
                      now: now)
        let expiry = Date(timeIntervalSince1970: TimeInterval(session.expiresAt > 0 ? session.expiresAt : Int64(now.addingTimeInterval(86_400).timeIntervalSince1970)))
        let clientExpiry = session.clientTokenExpiry > 0 ? Date(timeIntervalSince1970: TimeInterval(session.clientTokenExpiry) / 1000.0) : expiry
        storeSession(session,
                     existing: existingSession,
                     accountEmail: normalizedEmail,
                     authMethod: authMethod,
                     providerIdpId: providerIdpId,
                     now: now,
                     expiry: expiry,
                     clientExpiry: clientExpiry)
        primaryDevice.lastUsedAt = now
        trySave()
        cancelReauthentication()
        refreshSignedOutAccounts()
        OpenNOWLog.info(.auth, "Persisted signed-in session account=\(normalizedEmail) provider=\(providerIdpId) canContinueOffline=\(rememberSession)")
    }

    /// Applies what this sign-in says about the account itself.
    func updateAccount(_ account: LoginAccount,
                               session: JarvisSession,
                               userInfo: JarvisUserInfo?,
                               displayName: String,
                               providerIdpId: String,
                               providerName: String,
                               now: Date) {
        let authorization = NesAuthorizationPolicy().result(authType: JarvisAuthType.jwtGFN.rawValue)
        account.displayName = displayName
        account.providerIdpId = providerIdpId
        account.providerName = providerName
        account.membershipTier = session.membershipTier.isEmpty ? "Free" : session.membershipTier
        account.authorizationState = authorization.state.rawValue
        account.authStatus = JarvisAuthStatus.loggedIn.rawValue
        account.userId = session.userId
        account.externalUserId = userInfo?.externalId ?? session.userId
        account.lastLoginAt = now
        account.rememberSession = rememberSession
        account.isActive = true
    }

    /// Inserts or refreshes the stored session and moves it to the front of the list.
    func storeSession(_ session: JarvisSession,
                              existing existingSession: LoginSession?,
                              accountEmail normalizedEmail: String,
                              authMethod: String,
                              providerIdpId: String,
                              now: Date,
                              expiry: Date,
                              clientExpiry: Date) {
        guard let modelContext else { return }
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
    }
}
