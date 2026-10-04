//  The stable identity of a saved account.
//
//  Email and display name are attributes, not keys: a vendor can rename an account, and two
//  providers can hand back the same address for two different accounts. Keying ownership, caches or
//  credentials on either would silently re-point a running game at another row the moment one of
//  them changed. An `OPNAccountID` is instead the pair the vendor actually identifies the account
//  by - the provider's idp id and the vendor subject carried in the token - with an explicit,
//  non-colliding fallback for a record that predates the subject being stored.

import Foundation

/// Which account a game session, a cache entry or a credential namespace belongs to.
///
/// The string form is what gets persisted, so it is versioned by its own discriminator: a record
/// migrated from an incomplete legacy row keeps a `localOnly` identity that can never be confused
/// with a verified one for the same provider.
struct OPNAccountID: Hashable, Sendable, CustomStringConvertible {
    /// What the identity was derived from.
    enum Basis: String, Sendable {
        /// The vendor subject is known. This is the identity a token for the account carries, so it
        /// survives a rename, a re-sign-in and a second device.
        case vendorSubject
        /// No vendor subject was ever stored for this record. The identity is local to this Mac and
        /// is replaced the first time a sign-in supplies the subject.
        case localOnly
    }

    let providerIdpId: String
    let subject: String
    let basis: Basis

    var isVerified: Bool { basis == .vendorSubject }

    var rawValue: String { "\(basis.rawValue)|\(providerIdpId)|\(subject)" }

    var description: String { rawValue }

    /// Fails rather than inventing an identity. A row with neither a vendor subject nor a local
    /// fallback has nothing that can key ownership, and a shared placeholder would make two
    /// unrelated accounts the same owner - which is the failure this type exists to prevent.
    init?(providerIdpId: String, vendorSubject: String, localFallbackSubject: String = "") {
        let provider = providerIdpId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !provider.isEmpty else { return nil }
        let subject = vendorSubject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !subject.isEmpty {
            self.providerIdpId = provider
            self.subject = subject
            basis = .vendorSubject
            return
        }
        let fallback = localFallbackSubject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !fallback.isEmpty else { return nil }
        self.providerIdpId = provider
        self.subject = fallback
        basis = .localOnly
    }

    /// Reads back a persisted identity. Rejects anything the current version did not write, so a
    /// future format change degrades to "resolve it again" rather than to a wrong owner.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let basis = Basis(rawValue: parts[0]), !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        providerIdpId = parts[1]
        subject = parts[2]
        self.basis = basis
    }
}
