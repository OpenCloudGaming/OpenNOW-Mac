import Foundation
import Testing
@testable import OpenNOW

private func owner(_ subject: String) throws -> OPNAccountID {
    try #require(OPNAccountID(providerIdpId: "nvidia", vendorSubject: subject))
}

/// Occupies the registry with a session owned by `account`, without starting a launch: the launch
/// itself would reach the vendor, and none of these tests are about the launch.
@MainActor
private func beginSession(
    in registry: OPNGameSessionRegistry,
    account: LoginAccount,
    session: LoginSession,
    results: OPNGameSessionResultStore = OPNGameSessionResultStore()
) -> OPNGameSession? {
    registry.begin(
        account: account,
        session: session,
        gameService: OPNGameService.shared,
        launchBridge: OPNGameLaunchBridge.shared,
        discordPresence: DiscordRichPresence.shared,
        streamProfile: OPNStreamPreferenceProfile(),
        results: results
    )
}

@MainActor
@Test func aClaimedSessionIsOwnedUntilItIsReleased() throws {
    let registry = OPNGameSessionRegistry()
    let account = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
    let session = makeLoginSessionForTesting(accountEmail: account.email)
    defer { session.purgeTokens() }

    let owned = try #require(beginSession(in: registry, account: account, session: session))
    let accountID = try #require(account.storedAccountID)

    #expect(registry.isOccupied)
    #expect(registry.isOwned(by: accountID))
    #expect(registry.session(ownedBy: accountID) === owned)

    registry.end(owned)

    #expect(!registry.isOccupied)
    #expect(!registry.isOwned(by: accountID))
}

/// One local stream, admitted here. A second launch is refused rather than replacing the game
/// already running - which is the whole point of deciding admission before the window is replaced.
@MainActor
@Test func aSecondLaunchIsRefusedWhileTheSlotIsTaken() throws {
    let registry = OPNGameSessionRegistry()
    let first = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
    let firstSession = makeLoginSessionForTesting(accountEmail: first.email)
    let second = makeLoginAccountForTesting(email: "b@example.com", userId: "user-b")
    let secondSession = makeLoginSessionForTesting(accountEmail: second.email)
    defer {
        firstSession.purgeTokens()
        secondSession.purgeTokens()
    }

    let owned = try #require(beginSession(in: registry, account: first, session: firstSession))
    #expect(beginSession(in: registry, account: second, session: secondSession) == nil)

    // The game already running is untouched, and the slot frees up when it ends.
    let firstID = try #require(first.storedAccountID)
    #expect(registry.session(ownedBy: firstID) === owned)
    registry.end(owned)
    #expect(beginSession(in: registry, account: second, session: secondSession) != nil)
}

/// Ownership is per account. One account's game must not make another account's sign-out look
/// unsafe, or the whole feature becomes a reason nobody can manage their accounts.
@MainActor
@Test func ownershipOfOneAccountLeavesTheOthersFree() throws {
    let registry = OPNGameSessionRegistry()
    let account = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
    let session = makeLoginSessionForTesting(accountEmail: account.email)
    defer { session.purgeTokens() }
    _ = try #require(beginSession(in: registry, account: account, session: session))

    let ownerID = try #require(account.storedAccountID)
    let other = try owner("user-b")

    #expect(registry.isOwned(by: ownerID))
    #expect(!registry.isOwned(by: other))
    #expect(OPNAccountMutationGuard.blockReason(for: other, registry: registry) == nil)
}

/// A legacy row starts on a local-only identity and moves to its vendor subject the first time a
/// sign-in supplies one. The game it started has to move with it, or the account it actually
/// belongs to would look free to sign out of.
@MainActor
@Test func upgradingAnIdentityCarriesTheOwnershipClaimedUnderTheOldOne() throws {
    let registry = OPNGameSessionRegistry()
    let account = makeLoginAccountForTesting(email: "player@example.com")
    account.stableAccountID = ""
    let legacy = try #require(account.resolveStableAccountID())
    #expect(legacy.basis == .localOnly)
    let session = makeLoginSessionForTesting(accountEmail: account.email)
    defer { session.purgeTokens() }
    let owned = try #require(beginSession(in: registry, account: account, session: session))

    let verified = try owner("user-1")
    registry.rekeyOwnership(from: legacy, to: verified)

    #expect(!registry.isOwned(by: legacy))
    #expect(registry.isOwned(by: verified))
    #expect(registry.session(ownedBy: verified) === owned)
}

@MainActor
@Test func theGuardNamesTheReasonAnOwnerCannotBeSignedOutOrRemoved() throws {
    let registry = OPNGameSessionRegistry()
    let account = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
    let session = makeLoginSessionForTesting(accountEmail: account.email)
    defer { session.purgeTokens() }
    _ = try #require(beginSession(in: registry, account: account, session: session))

    #expect(OPNAccountMutationGuard.blockReason(for: try #require(account.storedAccountID), registry: registry) == OPNAccountMutationGuard.activeGameSessionMessage)
    #expect(OPNAccountMutationGuard.blockReason(for: nil, registry: registry) == nil)
}
