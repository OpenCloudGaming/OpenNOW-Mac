//  Keychain housekeeping and recovery for stored sessions.
//

import Foundation

extension LoginViewModel {
    /// A lost SwiftData row must not force a password while the auth service still holds the
    /// credential under the profile identity; rebuild the row and let the refresh path renew it.
    func restoreSavedSessionFromKeychain() {
        guard activeSession == nil, modelContext != nil else { return }
        let candidates = accounts.sorted { $0.lastLoginAt > $1.lastLoginAt }
        for account in candidates {
            let hasUsableSession = sessions.contains { $0.accountEmail == account.email && !$0.accessToken.isEmpty }
            guard !hasUsableSession else { continue }
            let identities = [account.userId, account.email].filter { !$0.isEmpty }
            guard let tokens = identities
                .compactMap({ GFNTokenStore.load(forIdentity: $0) })
                .first(where: { !$0.isEmpty }) else { continue }
            let idTokenExpiry = JarvisSessionParser.idTokenExpiry(tokens.idToken)
            let expiresAt = idTokenExpiry > 0
                ? idTokenExpiry
                : Int64(Date().addingTimeInterval(86_400).timeIntervalSince1970)
            let restored = JarvisSession(
                accessToken: tokens.accessToken,
                idToken: tokens.idToken,
                refreshToken: tokens.refreshToken,
                userId: account.userId,
                displayName: account.displayName,
                email: account.email,
                membershipTier: account.membershipTier,
                idpId: account.providerIdpId,
                expiresAt: expiresAt,
                isAuthenticated: true,
                clientToken: tokens.clientToken,
                clientTokenExpiry: 0,
                clientTokenExpiryLength: 0,
                idTokenExpiry: idTokenExpiry,
                accessTokenExpiry: 0
            )
            rememberSession = account.rememberSession
            persistSignedInSession(session: restored, userInfo: nil, authMethod: "keychain-restore")
            OPNLog.info(.auth, "Restored saved session from keychain account=\(account.email)")
            AuthDiagnosticLog.shared.record("session.restore account=\(account.email) source=keychain")
            return
        }
    }
}
