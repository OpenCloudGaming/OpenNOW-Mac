import Foundation
import SwiftData

@Model
final class LoginAccount {
    @Attribute(.unique) var email: String
    var displayName: String
    var providerIdpId: String
    var providerName: String
    var membershipTier: String
    var authorizationState: String
    var authStatus: String
    var userId: String = ""
    var externalUserId: String = ""
    var preferredRegion: String
    var createdAt: Date
    var lastLoginAt: Date
    var rememberSession: Bool
    var isActive: Bool

    init(
        email: String,
        displayName: String,
        providerIdpId: String,
        providerName: String,
        membershipTier: String = "Free",
        authorizationState: String = "AUTHORIZED",
        authStatus: String = "LOGGED_IN",
        userId: String = "",
        externalUserId: String = "",
        preferredRegion: String = "Auto",
        createdAt: Date = Date(),
        lastLoginAt: Date = Date(),
        rememberSession: Bool = true,
        isActive: Bool = true
    ) {
        self.email = email
        self.displayName = displayName
        self.providerIdpId = providerIdpId
        self.providerName = providerName
        self.membershipTier = membershipTier
        self.authorizationState = authorizationState
        self.authStatus = authStatus
        self.userId = userId
        self.externalUserId = externalUserId
        self.preferredRegion = preferredRegion
        self.createdAt = createdAt
        self.lastLoginAt = lastLoginAt
        self.rememberSession = rememberSession
        self.isActive = isActive
    }
}

/// Session metadata is persisted by SwiftData; the four bearer tokens are not. They live in the
/// keychain under `keychainIdentity`, because the SwiftData store is an unencrypted SQLite file that
/// any process running as this user can read — and the refresh token in it is a long-lived key to
/// the whole account. The token properties below stay stored-property-shaped so call sites read and
/// write them normally, but every access goes through the keychain.
@Model
final class LoginSession {
    @Attribute(.unique) var id: String
    var accountEmail: String
    var authMethod: String
    /// Columns retained only to drain pre-keychain installs on first read. Never written again.
    @Attribute(originalName: "accessToken") private var legacyAccessToken: String = ""
    @Attribute(originalName: "clientToken") private var legacyClientToken: String = ""
    @Attribute(originalName: "idToken") private var legacyIdToken: String = ""
    @Attribute(originalName: "refreshToken") private var legacyRefreshToken: String = ""
    var userId: String = ""
    var idpId: String = ""
    var deviceId: String
    var issuedAt: Date
    var expiresAt: Date
    var clientTokenExpiresAt: Date
    var isActive: Bool
    var canContinueOffline: Bool

    /// Avoids a keychain round trip per property read; `accessToken` is touched in list predicates.
    @Transient private var cachedTokens: GFNTokenStore.Tokens?

    init(
        id: String = UUID().uuidString,
        accountEmail: String,
        authMethod: String,
        accessToken: String,
        clientToken: String,
        idToken: String,
        refreshToken: String = "",
        userId: String = "",
        idpId: String = "",
        deviceId: String,
        issuedAt: Date = Date(),
        expiresAt: Date,
        clientTokenExpiresAt: Date,
        isActive: Bool = true,
        canContinueOffline: Bool = true
    ) {
        self.id = id
        self.accountEmail = accountEmail
        self.authMethod = authMethod
        self.userId = userId
        self.idpId = idpId
        self.deviceId = deviceId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.clientTokenExpiresAt = clientTokenExpiresAt
        self.isActive = isActive
        self.canContinueOffline = canContinueOffline
        storeTokens(GFNTokenStore.Tokens(
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refreshToken,
            clientToken: clientToken
        ))
    }

    var isExpired: Bool {
        expiresAt <= Date()
    }

    var accessToken: String {
        get { tokens.accessToken }
        set { updateTokens { $0.accessToken = newValue } }
    }

    var clientToken: String {
        get { tokens.clientToken }
        set { updateTokens { $0.clientToken = newValue } }
    }

    var idToken: String {
        get { tokens.idToken }
        set { updateTokens { $0.idToken = newValue } }
    }

    var refreshToken: String {
        get { tokens.refreshToken }
        set { updateTokens { $0.refreshToken = newValue } }
    }

    func updateAuthentication(
        accountEmail: String,
        authMethod: String,
        accessToken: String,
        clientToken: String,
        idToken: String,
        refreshToken: String,
        userId: String,
        idpId: String,
        deviceId: String,
        issuedAt: Date,
        expiresAt: Date,
        clientTokenExpiresAt: Date,
        isActive: Bool,
        canContinueOffline: Bool
    ) {
        self.accountEmail = accountEmail
        self.authMethod = authMethod
        self.userId = userId
        self.idpId = idpId
        self.deviceId = deviceId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.clientTokenExpiresAt = clientTokenExpiresAt
        self.isActive = isActive
        self.canContinueOffline = canContinueOffline
        storeTokens(GFNTokenStore.Tokens(
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refreshToken,
            clientToken: clientToken
        ))
    }

    /// Drops the session's tokens from the keychain. Called on sign-out and when an account is
    /// forgotten: a signed-out session must not leave a usable refresh token behind.
    func purgeTokens() {
        storeTokens(GFNTokenStore.Tokens(accessToken: "", idToken: "", refreshToken: "", clientToken: ""))
    }

    private var keychainIdentity: String { "session." + id }

    private var tokens: GFNTokenStore.Tokens {
        if let cachedTokens { return cachedTokens }
        if let stored = GFNTokenStore.load(forIdentity: keychainIdentity) {
            cachedTokens = stored
            return stored
        }
        // Pre-keychain install: move the plaintext columns into the keychain, then blank them.
        let drained = GFNTokenStore.Tokens(
            accessToken: legacyAccessToken,
            idToken: legacyIdToken,
            refreshToken: legacyRefreshToken,
            clientToken: legacyClientToken
        )
        if !drained.isEmpty { storeTokens(drained) }
        cachedTokens = drained
        return drained
    }

    private func updateTokens(_ mutate: (inout GFNTokenStore.Tokens) -> Void) {
        var updated = tokens
        mutate(&updated)
        storeTokens(updated)
    }

    private func storeTokens(_ tokens: GFNTokenStore.Tokens) {
        cachedTokens = tokens
        legacyAccessToken = ""
        legacyClientToken = ""
        legacyIdToken = ""
        legacyRefreshToken = ""
        if tokens.isEmpty {
            GFNTokenStore.delete(forIdentity: keychainIdentity)
        } else {
            GFNTokenStore.save(tokens, forIdentity: keychainIdentity)
        }
    }
}

@Model
final class LoginDeviceRegistration {
    @Attribute(.unique) var id: String
    var deviceId: String
    var displayName: String
    var pendingOAuthState: String = ""
    var pendingOAuthCodeVerifier: String = ""
    var pendingOAuthProviderIdpId: String = ""
    var pendingOAuthRedirectURI: String = ""
    var createdAt: Date
    var lastUsedAt: Date

    init(
        id: String = "primary",
        deviceId: String = UUID().uuidString,
        displayName: String? = nil,
        pendingOAuthState: String = "",
        pendingOAuthCodeVerifier: String = "",
        pendingOAuthProviderIdpId: String = "",
        pendingOAuthRedirectURI: String = "",
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.deviceId = deviceId
        let hostName = ProcessInfo.processInfo.hostName
        self.displayName = displayName ?? (!hostName.isEmpty ? hostName : "OpenNOW Mac")
        self.pendingOAuthState = pendingOAuthState
        self.pendingOAuthCodeVerifier = pendingOAuthCodeVerifier
        self.pendingOAuthProviderIdpId = pendingOAuthProviderIdpId
        self.pendingOAuthRedirectURI = pendingOAuthRedirectURI
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}
