import Foundation
import Testing
@testable import OpenNOW

private func owner(_ subject: String) throws -> OPNAccountID {
    try #require(OPNAccountID(providerIdpId: "nvidia", vendorSubject: subject))
}

@MainActor
@Test func aClaimedSessionIsOwnedUntilItIsReleased() throws {
    let registry = OPNGameSessionRegistry()
    let account = try owner("user-a")

    let id = registry.claim(accountID: account)

    #expect(registry.isOwned(by: account))
    #expect(registry.sessions.map(\.id) == [id])

    registry.release(id)

    #expect(!registry.isOwned(by: account))
    #expect(registry.sessions.isEmpty)
}

/// Ownership is per account. One account's game must not make another account's sign-out look
/// unsafe, or the whole feature becomes a reason nobody can manage their accounts.
@MainActor
@Test func ownershipOfOneAccountLeavesTheOthersFree() throws {
    let registry = OPNGameSessionRegistry()
    let ownerA = try owner("user-a")
    let other = try owner("user-b")

    registry.claim(accountID: ownerA)

    #expect(registry.isOwned(by: ownerA))
    #expect(!registry.isOwned(by: other))
    #expect(OPNAccountMutationGuard.blockReason(for: other, registry: registry) == nil)
}

/// Releasing one session leaves every other claim standing, so a teardown that reports the wrong
/// local session id cannot silently free an account that is still playing.
@MainActor
@Test func releasingOneSessionLeavesTheOthersClaimed() throws {
    let registry = OPNGameSessionRegistry()
    let ownerA = try owner("user-a")
    let first = registry.claim(accountID: ownerA)
    registry.claim(accountID: ownerA)

    registry.release(first)

    #expect(registry.isOwned(by: ownerA))
    #expect(registry.sessions.count == 1)
}

/// A legacy row starts on a local-only identity and moves to its vendor subject the first time a
/// sign-in supplies one. The game it started has to move with it, or the account it actually
/// belongs to would look free to sign out of.
@MainActor
@Test func upgradingAnIdentityCarriesTheOwnershipClaimedUnderTheOldOne() throws {
    let registry = OPNGameSessionRegistry()
    let legacy = try #require(OPNAccountID(providerIdpId: "nvidia", vendorSubject: "", localFallbackSubject: "player@example.com"))
    let verified = try owner("user-1")
    let id = registry.claim(accountID: legacy)

    registry.rekeyOwnership(from: legacy, to: verified)

    #expect(!registry.isOwned(by: legacy))
    #expect(registry.isOwned(by: verified))
    #expect(registry.sessions.map(\.id) == [id])
}

@MainActor
@Test func theGuardNamesTheReasonAnOwnerCannotBeSignedOutOrRemoved() throws {
    let registry = OPNGameSessionRegistry()
    let account = try owner("user-a")
    registry.claim(accountID: account)

    #expect(OPNAccountMutationGuard.blockReason(for: account, registry: registry) == OPNAccountMutationGuard.activeGameSessionMessage)
    #expect(OPNAccountMutationGuard.blockReason(for: nil, registry: registry) == nil)
}
