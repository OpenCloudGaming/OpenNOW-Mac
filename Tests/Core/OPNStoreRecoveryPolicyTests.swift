import Testing
@testable import OpenNOW

/// The SwiftData store recovery must never cost a reader their saved sessions to a configuration bug.
@Suite struct OPNStoreRecoveryPolicyTests {
    @Test func aConfigurationErrorIsNeverQuarantined() {
        let description = "A Core Data error occurred. CloudKit integration requires that all attributes be optional."
        #expect(OPNStoreRecoveryPolicy.decision(storeExists: true, errorDescription: description) == .leaveInPlace)
    }

    @Test func anUnreadableStoreIsQuarantined() {
        #expect(OPNStoreRecoveryPolicy.decision(storeExists: true, errorDescription: "The persistent store is unreadable.") == .quarantine)
    }

    @Test func aMissingStoreIsNeverQuarantined() {
        #expect(OPNStoreRecoveryPolicy.decision(storeExists: false, errorDescription: "The store is corrupt.") == .leaveInPlace)
    }

    @Test func anUnrecognisedErrorIsLeftInPlace() {
        #expect(OPNStoreRecoveryPolicy.decision(storeExists: true, errorDescription: "Something unexpected happened.") == .leaveInPlace)
    }
}
