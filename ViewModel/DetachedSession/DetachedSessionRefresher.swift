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
    private let refreshSession: @Sendable (JarvisSession) async throws -> JarvisSession

    init(
        modelContext: ModelContext,
        refreshSession: @escaping @Sendable (JarvisSession) async throws -> JarvisSession = { session in
            let service = JarvisAuthService(transport: JarvisURLSessionTransport(), session: session)
            return try await service.refreshSession(force: !session.isIdTokenValid)
        }
    ) {
        self.modelContext = modelContext
        self.refreshSession = refreshSession
    }

    func refresh(account: LoginAccount, session storedSession: LoginSession) async -> Bool {
        guard contains(account: account, session: storedSession) else { return false }
        let ownership = RefreshOwnership(account: account, session: storedSession)
        guard isCurrent(ownership, account: account, session: storedSession) else { return false }
        var jarvisSession = JarvisSession(
            accessToken: storedSession.accessToken,
            idToken: storedSession.idToken,
            refreshToken: storedSession.refreshToken,
            userId: storedSession.userId.isEmpty ? account.userId : storedSession.userId,
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
            let refreshed = try await refreshSession(jarvisSession)
            guard !Task.isCancelled, isCurrent(ownership, account: account, session: storedSession) else { return false }
            guard !refreshed.accessToken.isEmpty,
                  jarvisSession.userId.isEmpty || refreshed.userId.isEmpty || refreshed.userId == jarvisSession.userId else { return false }
            try store(refreshed, in: storedSession)
            OPNLog.info(.auth, "Detached session refreshed account=\(ownership.email)")
            return true
        } catch {
            OPNLog.warning(.auth, "Detached session refresh failed account=\(ownership.email) error=\(error.localizedDescription)")
            guard !Task.isCancelled, isCurrent(ownership, account: account, session: storedSession),
                  (error as? JarvisAuthError)?.category != .authorization else { return false }
            return storedSession.canContinueOffline && !storedSession.isExpired
        }
    }

    private func contains(account: LoginAccount, session: LoginSession) -> Bool {
        guard !modelContext.deletedModelsArray.contains(where: { $0 === account || $0 === session }),
              let accounts = try? modelContext.fetch(FetchDescriptor<LoginAccount>()),
              let sessions = try? modelContext.fetch(FetchDescriptor<LoginSession>()) else { return false }
        return accounts.contains { $0 === account } && sessions.contains { $0 === session }
    }

    private func isCurrent(_ ownership: RefreshOwnership, account: LoginAccount, session: LoginSession) -> Bool {
        guard !ownership.accessToken.isEmpty,
              !modelContext.deletedModelsArray.contains(where: {
                  $0.persistentModelID == ownership.accountIdentifier || $0.persistentModelID == ownership.sessionIdentifier
              }) else { return false }
        let email = ownership.email
        let sessionID = ownership.sessionID
        guard let currentAccount = try? modelContext.fetch(FetchDescriptor<LoginAccount>(predicate: #Predicate { $0.email == email })).first,
              let currentSession = try? modelContext.fetch(FetchDescriptor<LoginSession>(predicate: #Predicate { $0.id == sessionID })).first,
              currentAccount === account, currentSession === session else { return false }
        return currentAccount.persistentModelID == ownership.accountIdentifier
            && currentSession.persistentModelID == ownership.sessionIdentifier
            && currentAccount.stableAccountID == ownership.accountID
            && currentAccount.userId == ownership.accountUserID
            && currentAccount.providerIdpId == ownership.providerID
            && currentSession.accountEmail == email
            && currentSession.userId == ownership.userID
            && currentSession.idpId == ownership.sessionProviderID
            && currentSession.issuedAt == ownership.issuedAt
            && currentSession.accessToken == ownership.accessToken
            && currentSession.idToken == ownership.idToken
            && currentSession.refreshToken == ownership.refreshToken
            && currentSession.clientToken == ownership.clientToken
    }

    private func store(_ refreshed: JarvisSession, in storedSession: LoginSession) throws {
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
        try modelContext.save()
    }

    private struct RefreshOwnership {
        let accountIdentifier: PersistentIdentifier
        let sessionIdentifier: PersistentIdentifier
        let accountID: String
        let accountUserID: String
        let providerID: String
        let email: String
        let sessionID: String
        let userID: String
        let sessionProviderID: String
        let issuedAt: Date
        let accessToken: String
        let idToken: String
        let refreshToken: String
        let clientToken: String

        init(account: LoginAccount, session: LoginSession) {
            accountIdentifier = account.persistentModelID
            sessionIdentifier = session.persistentModelID
            accountID = account.stableAccountID
            accountUserID = account.userId
            providerID = account.providerIdpId
            email = account.email
            sessionID = session.id
            userID = session.userId
            sessionProviderID = session.idpId
            issuedAt = session.issuedAt
            accessToken = session.accessToken
            idToken = session.idToken
            refreshToken = session.refreshToken
            clientToken = session.clientToken
        }
    }
}
