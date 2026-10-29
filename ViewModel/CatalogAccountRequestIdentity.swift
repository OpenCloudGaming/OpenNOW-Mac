import Foundation
import SwiftData

struct CatalogAccountRequestIdentity: Equatable, Sendable {
    private let accountEmail: String
    private let accountID: String
    private let accountUserID: String
    private let accountProviderID: String
    private let lastLoginAt: Date
    private let sessionID: String
    private let sessionEmail: String
    private let userID: String
    private let providerID: String
    private let accessToken: String
    private let idToken: String
    private let refreshToken: String
    private let issuedAt: Date
    private let isAccountStored: Bool
    private let isSessionStored: Bool

    @MainActor
    init(account: LoginAccount, session: LoginSession) {
        accountEmail = account.email
        accountID = account.stableAccountID
        accountUserID = account.userId
        accountProviderID = account.providerIdpId
        lastLoginAt = account.lastLoginAt
        sessionID = session.id
        sessionEmail = session.accountEmail
        userID = session.userId
        providerID = session.idpId
        accessToken = session.accessToken
        idToken = session.idToken
        refreshToken = session.refreshToken
        issuedAt = session.issuedAt
        isAccountStored = account.modelContext != nil
        isSessionStored = session.modelContext != nil
    }

    @MainActor
    func isCurrent(account: LoginAccount, session: LoginSession) -> Bool {
        guard !account.isDeleted, !session.isDeleted,
              !isAccountStored || account.modelContext != nil,
              !isSessionStored || session.modelContext != nil,
              account.email == session.accountEmail,
              !session.accessToken.isEmpty || !session.idToken.isEmpty else { return false }
        return self == Self(account: account, session: session)
    }
}
