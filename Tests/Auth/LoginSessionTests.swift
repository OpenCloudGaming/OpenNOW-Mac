import Foundation
import Foundation
import Testing
@testable import MacForceNow

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
}
