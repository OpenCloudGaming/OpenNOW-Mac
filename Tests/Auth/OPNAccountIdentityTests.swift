import Foundation
import Testing
@testable import OpenNOW

/// The identity is the key ownership is recorded under, so the two ways it can be wrong are the two
/// things worth asserting: two accounts that share an attribute must not collide, and a record that
/// never stored the vendor subject must not claim to be the account that did.
@Test func verifiedIdentityIsTheProviderAndTheVendorSubject() throws {
    let identity = try #require(OPNAccountID(providerIdpId: "NVIDIA", vendorSubject: "User-1"))

    #expect(identity.basis == .vendorSubject)
    #expect(identity.isVerified)
    #expect(identity.providerIdpId == "nvidia")
    #expect(identity.subject == "user-1")
}

@Test func identityFallsBackToALocalSubjectOnlyWhenNoVendorSubjectExists() throws {
    let local = try #require(OPNAccountID(providerIdpId: "nvidia", vendorSubject: "", localFallbackSubject: "Player@Example.com"))

    #expect(local.basis == .localOnly)
    #expect(!local.isVerified)
    #expect(local.subject == "player@example.com")
    #expect(local != OPNAccountID(providerIdpId: "nvidia", vendorSubject: "player@example.com"))
}

@Test func identityRefusesToInventAKeyWhenThereIsNothingToDeriveItFrom() {
    #expect(OPNAccountID(providerIdpId: "", vendorSubject: "user-1") == nil)
    #expect(OPNAccountID(providerIdpId: "nvidia", vendorSubject: "", localFallbackSubject: "   ") == nil)
}

/// The same address under two providers is two accounts, not one. Keying on the email would merge
/// them and hand one provider's running game the other provider's credentials.
@Test func theSameAddressUnderTwoProvidersIsTwoIdentities() throws {
    let jarvis = try #require(OPNAccountID(providerIdpId: "nvidia", vendorSubject: "player@example.com"))
    let starfleet = try #require(OPNAccountID(providerIdpId: "starfleet", vendorSubject: "player@example.com"))

    #expect(jarvis != starfleet)
}

@Test func persistedIdentityRoundTrips() throws {
    let verified = try #require(OPNAccountID(providerIdpId: "nvidia", vendorSubject: "user-1"))
    let local = try #require(OPNAccountID(providerIdpId: "nvidia", vendorSubject: "", localFallbackSubject: "player@example.com"))

    #expect(OPNAccountID(rawValue: verified.rawValue) == verified)
    #expect(OPNAccountID(rawValue: local.rawValue) == local)
}

@Test func persistedIdentityRejectsAnythingThisVersionDidNotWrite() {
    #expect(OPNAccountID(rawValue: "") == nil)
    #expect(OPNAccountID(rawValue: "nvidia|user-1") == nil)
    #expect(OPNAccountID(rawValue: "vendorSubject||user-1") == nil)
    #expect(OPNAccountID(rawValue: "vendorSubject|nvidia|") == nil)
    #expect(OPNAccountID(rawValue: "futureBasis|nvidia|user-1") == nil)
}

/// A stored identity is never re-derived over, so a row keeps the key its ownership was recorded
/// under even if the attributes it was derived from change afterwards.
@Test func aStoredIdentitySurvivesAnAttributeChange() throws {
    let account = LoginAccount(
        email: "player@example.com",
        displayName: "Player",
        providerIdpId: "nvidia",
        providerName: "NVIDIA",
        userId: "user-1"
    )
    let original = try #require(account.resolveStableAccountID())

    account.userId = "user-2"

    #expect(account.resolveStableAccountID() == original)
}
