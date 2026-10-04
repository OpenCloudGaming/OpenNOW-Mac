//  The stable identity of a saved account: the provider's idp id plus the vendor subject, with a
//  non-colliding fallback for a legacy row that never stored the subject.

import Foundation

/// Which account a game session, a cache entry or a credential namespace belongs to.
struct OPNAccountID: Hashable, Sendable, CustomStringConvertible {
    /// What the identity was derived from. Email and display name are attributes, not keys: a vendor
    /// can rename an account, and two providers can hand back the same address.
    enum Basis: String, Sendable {
        /// The vendor subject is known, so this identity survives a rename and a second device.
        case vendorSubject
        /// No subject was ever stored: local to this Mac until a sign-in supplies one.
        case localOnly
    }

    let providerIdpId: String
    let subject: String
    let basis: Basis

    var isVerified: Bool { basis == .vendorSubject }

    var rawValue: String { "\(basis.rawValue)|\(providerIdpId)|\(subject)" }

    var description: String { rawValue }

    /// Fails rather than inventing an identity: a shared placeholder would make two unrelated
    /// accounts the same owner.
    init?(providerIdpId: String, vendorSubject: String, localFallbackSubject: String = "") {
        let provider = providerIdpId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !provider.isEmpty else { return nil }
        let subject = vendorSubject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard subject.isEmpty else {
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

    /// Rejects anything this version did not write, so an old format degrades to "resolve again"
    /// rather than to a wrong owner.
    init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let basis = Basis(rawValue: parts[0]), !parts[1].isEmpty, !parts[2].isEmpty else { return nil }
        providerIdpId = parts[1]
        subject = parts[2]
        self.basis = basis
    }
}
