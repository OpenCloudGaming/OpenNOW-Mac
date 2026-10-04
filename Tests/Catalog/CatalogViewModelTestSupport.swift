import Foundation
@testable import OpenNOW

@MainActor
func makeCatalogViewModelForTesting(
    account: LoginAccount = makeLoginAccountForTesting(),
    sessionRegistry: OPNGameSessionRegistry = .shared,
    sessionResultStore: OPNGameSessionResultStore = .shared,
    onSwitchAccount: @escaping (LoginAccount) -> Void = { _ in },
    onAddAccount: @escaping () -> Void = {}
) -> CatalogViewModel {
    let session = LoginSession(
        accountEmail: account.email,
        authMethod: "test",
        accessToken: "t",
        clientToken: "c",
        idToken: "i",
        refreshToken: "r",
        deviceId: "d",
        expiresAt: Date().addingTimeInterval(3600),
        clientTokenExpiresAt: Date().addingTimeInterval(3600)
    )
    return CatalogViewModel(
        account: account,
        session: session,
        sessionRegistry: sessionRegistry,
        sessionResultStore: sessionResultStore,
        onSwitchAccount: onSwitchAccount,
        onAddAccount: onAddAccount,
        onRefreshAuth: { true }
    )
}

/// A stored session for an account, with no keychain writes of its own: the token cache is filled
/// in place, and `purgeTokens` in a test's teardown is what clears the identity it points at.
@MainActor
func makeLoginSessionForTesting(
    accountEmail: String,
    id: String = UUID().uuidString,
    userId: String = "",
    idpId: String = "idp"
) -> LoginSession {
    LoginSession(
        id: id,
        accountEmail: accountEmail,
        authMethod: "test",
        accessToken: "access-\(id)",
        clientToken: "client-\(id)",
        idToken: "id-\(id)",
        refreshToken: "refresh-\(id)",
        userId: userId,
        idpId: idpId,
        deviceId: "d",
        expiresAt: Date().addingTimeInterval(3600),
        clientTokenExpiresAt: Date().addingTimeInterval(3600)
    )
}

/// A saved account with a stable identity, for tests that need more than one of them.
@MainActor
func makeLoginAccountForTesting(
    email: String = "a@b.c",
    displayName: String = "A",
    userId: String = "",
    isActive: Bool = true
) -> LoginAccount {
    LoginAccount(
        email: email,
        displayName: displayName,
        providerIdpId: "idp",
        providerName: "p",
        userId: userId,
        isActive: isActive
    )
}

/// Occupies the registry with a session owned by the model's account, without starting a launch: the
/// tests drive the session's own state transitions instead, which is what the views read.
@MainActor
func makeOwnedGameSessionForTesting(_ model: CatalogViewModel) -> OPNGameSession? {
    model.sessionRegistry.begin(
        account: model.account,
        session: model.session,
        gameService: OPNGameService.shared,
        launchBridge: OPNGameLaunchBridge.shared,
        discordPresence: DiscordRichPresence.shared,
        streamProfile: model.streamProfile,
        results: model.sessionResultStore
    )
}

/// A finished-session result for the model's own account, as the application-owned session would
/// publish it. Adopting it is where the catalog writes history, playtime and the summary.
@MainActor
func makeSessionResultForTesting(
    accountID: OPNAccountID,
    configuration: StreamLaunchConfiguration?,
    launchedGame: OPNCatalogGameObject? = nil,
    success: Bool,
    message: String = "",
    report: StreamReport? = nil,
    wasCancelled: Bool = false
) -> OPNGameSessionResult {
    OPNGameSessionResult(
        accountID: accountID,
        configuration: configuration,
        launchedGame: launchedGame,
        success: success,
        message: message,
        report: report,
        wasCancelled: wasCancelled
    )
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
