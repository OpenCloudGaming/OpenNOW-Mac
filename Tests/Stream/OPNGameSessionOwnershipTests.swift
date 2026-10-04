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

    #expect(registry.hasSessions)
    #expect(registry.isOwned(by: accountID))
    #expect(registry.session(ownedBy: accountID) === owned)

    registry.end(owned)

    #expect(!registry.hasSessions)
    #expect(!registry.isOwned(by: accountID))
}

/// One game per account, admitted here. A second game for the same account is refused rather than
/// replacing the one already running; a different account is admitted alongside it.
@MainActor
@Test func aSecondGameForOneAccountIsRefusedWhileThatAccountHasOne() throws {
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
    let firstID = try #require(first.storedAccountID)

    // The same account again is refused, and the game already running is untouched.
    #expect(beginSession(in: registry, account: first, session: firstSession) == nil)
    #expect(registry.session(ownedBy: firstID) === owned)

    // Another account is admitted beside it.
    #expect(beginSession(in: registry, account: second, session: secondSession) != nil)
    #expect(registry.sessions.count == 2)

    // And the first account gets its slot back when its own game ends.
    registry.end(owned)
    #expect(registry.session(ownedBy: firstID) == nil)
    #expect(beginSession(in: registry, account: first, session: firstSession) != nil)
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

/// A legacy row moves from its local-only identity to its vendor subject the first time a sign-in
/// supplies one, and the game it started moves with it.
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
@Test func theGuardExplainsWhyAnOwnerIsProtected() throws {
    let registry = OPNGameSessionRegistry()
    let account = makeLoginAccountForTesting(email: "a@example.com", userId: "user-a")
    let session = makeLoginSessionForTesting(accountEmail: account.email)
    defer { session.purgeTokens() }
    _ = try #require(beginSession(in: registry, account: account, session: session))

    #expect(OPNAccountMutationGuard.blockReason(for: account.storedAccountID, registry: registry) == OPNAccountMutationGuard.activeGameSessionMessage)
    #expect(OPNAccountMutationGuard.blockReason(for: nil, registry: registry) == nil)
}
