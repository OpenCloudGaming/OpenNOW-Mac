import Foundation

/// Decides whether a failed SwiftData store open should quarantine its files. Only an error that
/// names an unreadable store is quarantined. A configuration error must never cost the reader their
/// saved sessions, so anything unrecognised is left in place and the app falls back to memory.
enum OPNStoreRecoveryPolicy {
    enum Decision: Equatable {
        case quarantine
        case leaveInPlace
    }

    /// The phrases a genuinely unreadable store reports. Matching one is what separates a store that
    /// must be moved aside from a configuration failure that must be preserved.
    private static let unreadableStoreSignatures = [
        "unreadable",
        "corrupt",
        "incompatible",
        "migration",
        "persistent store",
    ]

    static func decision(storeExists: Bool, errorDescription: String) -> Decision {
        guard storeExists else { return .leaveInPlace }
        guard isUnreadableStoreFailure(errorDescription) else { return .leaveInPlace }
        return .quarantine
    }

    private static func isUnreadableStoreFailure(_ errorDescription: String) -> Bool {
        let lowered = errorDescription.lowercased()
        return unreadableStoreSignatures.contains { lowered.contains($0) }
    }
}
