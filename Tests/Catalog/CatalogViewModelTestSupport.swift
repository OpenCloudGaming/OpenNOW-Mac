//  A signed-in, empty catalog model for tests that exercise behavior past construction.
//

import Foundation
@testable import OpenNOW

@MainActor
func makeCatalogViewModelForTesting(
    onSwitchAccount: @escaping (LoginAccount) -> Void = { _ in },
    onAddAccount: @escaping () -> Void = {}
) -> CatalogViewModel {
    let account = LoginAccount(email: "a@b.c", displayName: "A", providerIdpId: "idp", providerName: "p")
    let session = LoginSession(
        accountEmail: "a@b.c",
        authMethod: "test",
        accessToken: "t",
        clientToken: "c",
        idToken: "i",
        refreshToken: "r",
        deviceId: "d",
        expiresAt: Date().addingTimeInterval(3600),
        clientTokenExpiresAt: Date().addingTimeInterval(3600)
    )
    return CatalogViewModel(account: account, session: session, onSwitchAccount: onSwitchAccount, onAddAccount: onAddAccount, onRefreshAuth: { true })
}
