//  The decouple: a game belongs to the account that started it, not to the catalog that is browsing.
//  Each test rebuilds the model the way `LoginView` does, and asserts what survives that.

import Foundation
import Testing
@testable import OpenNOW

@MainActor
private struct DecoupledFixture {
    let registry = OPNGameSessionRegistry()
    let results = OPNGameSessionResultStore()
    let accountA: LoginAccount
    let accountB: LoginAccount
    let sessionA: LoginSession
    let sessionB: LoginSession
    let catalogA: CatalogViewModel

    init() {
        accountA = makeLoginAccountForTesting(email: "a@example.com", displayName: "Account A", userId: "user-a")
        accountB = makeLoginAccountForTesting(email: "b@example.com", displayName: "Account B", userId: "user-b", isActive: false)
        sessionA = makeLoginSessionForTesting(accountEmail: accountA.email, id: "session-a", userId: "user-a")
        sessionB = makeLoginSessionForTesting(accountEmail: accountB.email, id: "session-b", userId: "user-b")
        catalogA = makeCatalogViewModelForTesting(account: accountA, sessionRegistry: registry, sessionResultStore: results)
    }

    /// The catalog `LoginView` builds for the newly selected account. Same registry, same result
    /// store - a browsing switch replaces the model, nothing else.
    func remount(for account: LoginAccount) -> CatalogViewModel {
        makeCatalogViewModelForTesting(account: account, sessionRegistry: registry, sessionResultStore: results)
    }

    func tearDown() {
        sessionA.purgeTokens()
        sessionB.purgeTokens()
    }

    var accountAID: OPNAccountID {
        accountA.storedAccountID ?? OPNAccountID(providerIdpId: "idp", vendorSubject: "user-a")!
    }
}

private let runningConfiguration = StreamLaunchConfiguration(
    title: "Cyberpunk 2077",
    applicationID: "1093630001",
    accessToken: "token-a",
    accountLinked: true,
    selectedStore: "steam"
)

/// The browsing switch: a new catalog for the newly selected account, while A's game keeps running
/// under A's credentials, in its own window, on its own configuration.
@MainActor
@Test func aRunningGameSurvivesTheCatalogThatStartedItBeingRemounted() throws {
    let fixture = DecoupledFixture()
    defer { fixture.tearDown() }
    let game = try #require(makeOwnedGameSessionForTesting(fixture.catalogA))
    game.configuration = runningConfiguration

    let catalogB = fixture.remount(for: fixture.accountB)

    #expect(fixture.registry.current === game)
    #expect(fixture.registry.isOwned(by: fixture.accountAID))
    #expect(game.configuration == runningConfiguration)
    #expect(game.isRunning)
    // B's page knows nothing about A's game, and A's page still does.
    #expect(catalogB.gameSession == nil)
    #expect(!catalogB.isStreamRunning)
    #expect(fixture.catalogA.gameSession === game)
    #expect(fixture.catalogA.isStreamRunning)
    // And the credentials A's game runs on are still protected from a sign-out.
    #expect(OPNAccountMutationGuard.blockReason(for: fixture.accountAID, registry: fixture.registry) == OPNAccountMutationGuard.activeGameSessionMessage)
}

/// An accepted launch intent is the application's, not the page's. Switching away and back finds it
/// still in flight, with the same owner and the same overlay.
@MainActor
@Test func anAcceptedLaunchIntentSurvivesABrowsingSwitch() throws {
    let fixture = DecoupledFixture()
    defer { fixture.tearDown() }
    let game = try #require(makeOwnedGameSessionForTesting(fixture.catalogA))
    game.phase = .checkingSession
    game.launchFlowTitle = "Cyberpunk 2077"
    game.launchFlowMessage = "Checking for active GeForce NOW sessions..."

    let catalogB = fixture.remount(for: fixture.accountB)
    #expect(catalogB.gameSession == nil)
    #expect(!catalogB.isLaunchFlowVisible)

    let catalogAAgain = fixture.remount(for: fixture.accountA)
    #expect(catalogAAgain.gameSession === game)
    #expect(catalogAAgain.isLaunchFlowVisible)
    #expect(catalogAAgain.launchFlowState == .checkingSession)
    #expect(catalogAAgain.launchFlowTitle == "Cyberpunk 2077")
    #expect(fixture.registry.isOwned(by: fixture.accountAID))
}

/// One local stream at a time, decided before anything is allocated or replaced. A second launch -
/// from either account - is refused and the game already running is untouched.
@MainActor
@Test func aSecondLaunchIsRefusedWithoutEndingTheRunningGame() throws {
    let fixture = DecoupledFixture()
    defer { fixture.tearDown() }
    let game = try #require(makeOwnedGameSessionForTesting(fixture.catalogA))
    game.configuration = runningConfiguration

    let catalogB = fixture.remount(for: fixture.accountB)
    catalogB.beginVendorLaunch(game: makeMaintenanceGameForTesting(id: "id-1", title: "Manor Lords"))

    #expect(fixture.registry.current === game)
    #expect(game.configuration == runningConfiguration)
    #expect(catalogB.activeStreamConfiguration == nil)
    #expect(catalogB.launchErrorMessage == "Account A is already running a game. Switch to Account A to end it before starting another.")

    // The same account launching again is refused too: the running game is not replaced by itself.
    fixture.catalogA.beginVendorLaunch(game: makeMaintenanceGameForTesting(id: "id-2", title: "Manor Lords"))
    #expect(fixture.registry.current === game)
    #expect(fixture.catalogA.launchErrorMessage == "This account is already running a game. End it from the banner at the top of the page before starting another.")
}

/// A launch that has not produced a stream yet blocks the slot too, and the refusal has to say so:
/// there is no END control for a game that has not started, only that account's own CANCEL.
@MainActor
@Test func aLaunchStillStartingBlocksASecondLaunchAndSaysSo() throws {
    let fixture = DecoupledFixture()
    defer { fixture.tearDown() }
    let game = try #require(makeOwnedGameSessionForTesting(fixture.catalogA))
    game.phase = .checkingSession

    let catalogB = fixture.remount(for: fixture.accountB)
    catalogB.beginVendorLaunch(game: makeMaintenanceGameForTesting(id: "id-1", title: "Manor Lords"))
    #expect(catalogB.launchErrorMessage == "Account A is already starting a game. Switch to Account A to finish or cancel it.")

    fixture.catalogA.beginVendorLaunch(game: makeMaintenanceGameForTesting(id: "id-2", title: "Manor Lords"))
    #expect(fixture.catalogA.launchErrorMessage == "This account is already starting a game. Cancel that launch before starting another.")
    #expect(fixture.registry.current === game)
}

/// Once the slot is free, the launch is admitted for whichever account is browsing now - and it is
/// that account's session from the start.
@MainActor
@Test func theSlotIsReusedByTheNewBrowsingAccountOnceTheGameEnds() throws {
    let fixture = DecoupledFixture()
    defer { fixture.tearDown() }
    let game = try #require(makeOwnedGameSessionForTesting(fixture.catalogA))
    game.configuration = runningConfiguration
    fixture.registry.end(game)

    let catalogB = fixture.remount(for: fixture.accountB)
    catalogB.beginVendorLaunch(game: makeMaintenanceGameForTesting(id: "id-1", title: "Manor Lords"))

    let started = try #require(fixture.registry.current)
    let accountBID = try #require(fixture.accountB.storedAccountID)
    #expect(started.accountID == accountBID)
    #expect(catalogB.gameSession === started)
    #expect(catalogB.launchErrorMessage.isEmpty)
}

/// A finished game writes its history, playtime and summary into its owner's page only. The account
/// being browsed at the time cannot be the one that receives them.
@MainActor
@Test func aFinishedGameNeverWritesToTheSelectedAccount() throws {
    let fixture = DecoupledFixture()
    defer { fixture.tearDown() }
    let catalogB = fixture.remount(for: fixture.accountB)
    catalogB.observeSessionResults()
    fixture.catalogA.observeSessionResults()
    let game = try #require(makeOwnedGameSessionForTesting(fixture.catalogA))

    game.configuration = runningConfiguration
    game.endStream(success: true, message: "", report: nil)

    #expect(!fixture.registry.isOccupied)
    #expect(catalogB.recentlyPlayed == .empty)
    #expect(catalogB.sessionInsights == nil)
    #expect(fixture.catalogA.recentlyPlayed.games.map(\.title) == ["Cyberpunk 2077"])
    #expect(fixture.catalogA.previousGameSession?.title == "Cyberpunk 2077")
}

/// A game that ends while its owner's catalog is not mounted is still recorded when that account is
/// opened again - the result waits under the owner's identity, not under "whatever is selected".
@MainActor
@Test func aResultWaitsForItsOwnerUntilThatAccountIsOpenedAgain() throws {
    let fixture = DecoupledFixture()
    defer { fixture.tearDown() }
    let game = try #require(makeOwnedGameSessionForTesting(fixture.catalogA))
    game.configuration = runningConfiguration
    game.endStream(success: true, message: "", report: nil)

    // B is browsing, so nothing has taken A's result yet.
    let catalogB = fixture.remount(for: fixture.accountB)
    catalogB.adoptPendingSessionResult()
    #expect(catalogB.recentlyPlayed == .empty)

    let catalogAAgain = fixture.remount(for: fixture.accountA)
    catalogAAgain.adoptPendingSessionResult()

    #expect(catalogAAgain.recentlyPlayed.games.map(\.title) == ["Cyberpunk 2077"])
    // Taken, not merely read: a later remount must not record it twice.
    let catalogAAgainLater = fixture.remount(for: fixture.accountA)
    catalogAAgainLater.adoptPendingSessionResult()
    #expect(catalogAAgainLater.recentlyPlayed == .empty)
}

/// A cancelled launch is not a game. It frees the slot and tells its owner, but records no history.
@MainActor
@Test func aCancelledLaunchRecordsNothingForItsOwner() throws {
    let fixture = DecoupledFixture()
    defer { fixture.tearDown() }
    let game = try #require(makeOwnedGameSessionForTesting(fixture.catalogA))
    game.configuration = runningConfiguration
    // Whatever an earlier run left in the shared preference store, this launch must not touch it.
    let previousSessionBefore = fixture.catalogA.previousGameSession

    game.cancelStreamLaunch()

    #expect(!fixture.registry.isOccupied)
    #expect(fixture.catalogA.gameSession == nil)
    fixture.catalogA.adoptPendingSessionResult()
    #expect(fixture.catalogA.recentlyPlayed == .empty)
    #expect(fixture.catalogA.previousGameSession == previousSessionBefore)
    #expect(fixture.catalogA.actionMessage == "Stream launch cancelled.")
}
