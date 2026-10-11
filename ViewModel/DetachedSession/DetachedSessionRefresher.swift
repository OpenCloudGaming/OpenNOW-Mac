//  Refreshes a saved account's tokens without making it the active account.
//
//  `LoginViewModel` refreshes through one auth service whose session is the active account's, and
//  re-activates the account it restores. A detached window's account is not the active one, so it
//  gets a service of its own and writes the refreshed tokens back to that account's stored session
//  only, leaving every `isActive` flag where it was.

import Foundation
import SwiftData

@MainActor
struct DetachedSessionRefresher {
    let modelContext: ModelContext

    func refresh(account: LoginAccount, session storedSession: LoginSession) async -> Bool {
        guard !storedSession.accessToken.isEmpty else { return false }
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
        let service = JarvisAuthService(transport: JarvisURLSessionTransport())
        do {
            await service.setSession(jarvisSession)
            let refreshed = try await service.refreshSession(force: !jarvisSession.isIdTokenValid)
            store(refreshed, in: storedSession)
            OPNLog.info(.auth, "Detached session refreshed account=\(account.email)")
            return true
        } catch {
            OPNLog.warning(.auth, "Detached session refresh failed account=\(account.email) error=\(error.localizedDescription)")
            return storedSession.canContinueOffline && !storedSession.isExpired
        }
    }

    private func store(_ refreshed: JarvisSession, in storedSession: LoginSession) {
        let now = Date()
        let expiry = Date(timeIntervalSince1970: TimeInterval(refreshed.expiresAt > 0 ? refreshed.expiresAt : Int64(now.addingTimeInterval(86_400).timeIntervalSince1970)))
        let clientExpiry = refreshed.clientTokenExpiry > 0 ? Date(timeIntervalSince1970: TimeInterval(refreshed.clientTokenExpiry) / 1000.0) : expiry
        storedSession.updateAuthentication(
            accountEmail: storedSession.accountEmail,
            authMethod: storedSession.authMethod,
            accessToken: refreshed.accessToken,
            clientToken: refreshed.clientToken,
            idToken: refreshed.idToken,
            refreshToken: refreshed.refreshToken,
            userId: refreshed.userId.isEmpty ? storedSession.userId : refreshed.userId,
            idpId: storedSession.idpId,
            deviceId: storedSession.deviceId,
            issuedAt: now,
            expiresAt: expiry,
            clientTokenExpiresAt: clientExpiry,
            isActive: storedSession.isActive,
            canContinueOffline: storedSession.canContinueOffline
        )
        do {
            try modelContext.save()
        } catch {
            OPNLog.warning(.auth, "Detached session refresh could not be saved: \(error.localizedDescription)")
        }
    }
}
