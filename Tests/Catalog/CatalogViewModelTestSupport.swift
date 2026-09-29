//  A signed-in, empty catalog model for tests that exercise behavior past construction, plus the
//  fixtures the maintenance-watch suites share.

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

/// A single-variant title the vendor has taken down for maintenance.
@MainActor
func makeMaintenanceGameForTesting(id: String, title: String) -> OPNCatalogGameObject {
    var variant = OPNGameVariant(id: "\(id)-v", appStore: "STEAM")
    variant.catalogStatus = "SERVER_MAINTENANCE"
    variant.catalogStateDetailsSubType = "GFN_DEVELOPER_MAINTENANCE"
    var info = OPNGameInfo()
    info.id = id
    info.title = title
    info.variants = [variant]
    return OPNCatalogGameObject(game: info)
}

/// One watch as the store holds it: still waiting on maintenance, nothing announced yet.
func makeMaintenanceWatchForTesting(identity: String, title: String = "Game") -> CatalogMaintenanceWatch {
    CatalogMaintenanceWatch(
        identity: identity,
        appId: "app-\(identity)",
        title: title,
        startedAt: Date(timeIntervalSince1970: 0),
        observedAvailability: .maintenance,
        lastNotifiedEdge: nil
    )
}
