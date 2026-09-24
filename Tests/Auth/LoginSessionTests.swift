import Foundation
import Foundation
import Testing
@testable import OpenNOW

@Test func loginSessionAuthenticationUpdatePreservesIdentifier() {
    let session = LoginSession(
        id: "stable-session-id",
        accountEmail: "old@example.com",
        authMethod: "old-method",
        accessToken: "old-access",
        clientToken: "old-client",
        idToken: "old-id",
        refreshToken: "old-refresh",
        userId: "old-user",
        idpId: "old-idp",
        deviceId: "old-device",
        issuedAt: Date(timeIntervalSince1970: 10),
        expiresAt: Date(timeIntervalSince1970: 20),
        clientTokenExpiresAt: Date(timeIntervalSince1970: 30),
        isActive: false,
        canContinueOffline: false
    )

    session.updateAuthentication(
        accountEmail: "new@example.com",
        authMethod: "new-method",
        accessToken: "new-access",
        clientToken: "new-client",
        idToken: "new-id",
        refreshToken: "new-refresh",
        userId: "new-user",
        idpId: "new-idp",
        deviceId: "new-device",
        issuedAt: Date(timeIntervalSince1970: 100),
        expiresAt: Date(timeIntervalSince1970: 200),
        clientTokenExpiresAt: Date(timeIntervalSince1970: 300),
        isActive: true,
        canContinueOffline: true
    )

    #expect(session.id == "stable-session-id")
    #expect(session.accountEmail == "new@example.com")
    #expect(session.authMethod == "new-method")
    #expect(session.accessToken == "new-access")
    #expect(session.clientToken == "new-client")
    #expect(session.idToken == "new-id")
    #expect(session.refreshToken == "new-refresh")
    #expect(session.userId == "new-user")
    #expect(session.idpId == "new-idp")
    #expect(session.deviceId == "new-device")
    #expect(session.issuedAt == Date(timeIntervalSince1970: 100))
    #expect(session.expiresAt == Date(timeIntervalSince1970: 200))
    #expect(session.clientTokenExpiresAt == Date(timeIntervalSince1970: 300))
    #expect(session.isActive)
    #expect(session.canContinueOffline)

    session.purgeTokens()
}

/// The SwiftData store is an unencrypted SQLite file any process running as this user can read, so
/// the tokens live in the keychain instead — keyed by the session id, under the `session.` prefix.
/// Constructing the model must not write to the keychain: a session that is built and then
/// discarded (a superseded row, a failed insert) would otherwise leak an item nothing can reach.
@Test func constructingALoginSessionDoesNotWriteToTheKeychain() {
    let identity = "session.construction-does-not-persist"
    GFNTokenStore.delete(forIdentity: identity)

    let session = LoginSession(
        id: "construction-does-not-persist",
        accountEmail: "user@example.com",
        authMethod: "getSessionToken",
        accessToken: "access-value",
        clientToken: "client-value",
        idToken: "id-value",
        refreshToken: "refresh-value",
        deviceId: "device",
        expiresAt: Date(timeIntervalSince1970: 20),
        clientTokenExpiresAt: Date(timeIntervalSince1970: 30)
    )

    #expect(GFNTokenStore.load(forIdentity: identity) == nil)
    #expect(session.accessToken == "access-value")

    session.updateAuthentication(
        accountEmail: "user@example.com",
        authMethod: "getSessionToken",
        accessToken: "access-value",
        clientToken: "client-value",
        idToken: "id-value",
        refreshToken: "refresh-value",
        userId: "user",
        idpId: "idp",
        deviceId: "device",
        issuedAt: Date(timeIntervalSince1970: 10),
        expiresAt: Date(timeIntervalSince1970: 20),
        clientTokenExpiresAt: Date(timeIntervalSince1970: 30),
        isActive: true,
        canContinueOffline: true
    )

    let stored = GFNTokenStore.load(forIdentity: identity)
    #expect(stored?.accessToken == "access-value")
    #expect(stored?.refreshToken == "refresh-value")
    #expect(stored?.idToken == "id-value")
    #expect(stored?.clientToken == "client-value")

    // Signing out must leave nothing replayable behind — the refresh token above outlives the
    // access token by far, so clearing only the active flag would not be a sign-out at all.
    session.purgeTokens()
    #expect(GFNTokenStore.load(forIdentity: identity) == nil)
    #expect(session.accessToken.isEmpty)
    #expect(session.refreshToken.isEmpty)
}

/// `deleteAll` purges a signed-out account's tokens. A service-only delete left items behind, so
/// it must remove every account in the service, not just one. Uses a private service so it cannot
/// race the other keychain tests, which Swift Testing runs in parallel.
@Test func deleteAllRemovesEveryAccountInTheService() {
    let serviceName = "OpenNOW.GFN.tests.delete-all.\(UUID().uuidString)"
    let tokens = GFNTokenStore.Tokens(accessToken: "a", idToken: "i", refreshToken: "r", clientToken: "c")
    GFNTokenStore.save(tokens, forIdentity: "session.one", service: serviceName)
    GFNTokenStore.save(tokens, forIdentity: "profile-two", service: serviceName)

    GFNTokenStore.deleteAll(service: serviceName)

    #expect(GFNTokenStore.load(forIdentity: "session.one", service: serviceName) == nil)
    #expect(GFNTokenStore.load(forIdentity: "profile-two", service: serviceName) == nil)
}
