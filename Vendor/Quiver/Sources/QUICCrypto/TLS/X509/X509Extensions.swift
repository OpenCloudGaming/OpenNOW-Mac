/// X.509 Certificate Extensions (RFC 5280 Section 4.2)
///
/// This file provides convenience extensions for working with X.509 certificate extensions
/// using the swift-certificates library.

import Foundation
@preconcurrency import X509
import SwiftASN1

// MARK: - Extension Helpers for X509Certificate

extension X509Certificate {
    /// Gets the basic constraints extension
    public var basicConstraints: BasicConstraints? {
        try? certificate.extensions.basicConstraints
    }

    /// Gets the key usage extension
    public var keyUsage: X509.KeyUsage? {
        try? certificate.extensions.keyUsage
    }

    /// Gets the extended key usage extension
    public var extendedKeyUsage: ExtendedKeyUsage? {
        try? certificate.extensions.extendedKeyUsage
    }

    /// Gets the subject alternative names extension
    public var subjectAlternativeNames: SubjectAlternativeNames? {
        try? certificate.extensions.subjectAlternativeNames
    }

    /// Gets the authority key identifier extension
    public var authorityKeyIdentifier: AuthorityKeyIdentifier? {
        try? certificate.extensions.authorityKeyIdentifier
    }

    /// Gets the subject key identifier extension
    public var subjectKeyIdentifier: SubjectKeyIdentifier? {
        try? certificate.extensions.subjectKeyIdentifier
    }

    /// Gets the name constraints extension
    public var nameConstraints: X509.NameConstraints? {
        try? certificate.extensions.nameConstraints
    }
}

// MARK: - BasicConstraints Helpers

extension BasicConstraints {
    /// Whether this certificate is a CA
    public var isCA: Bool {
        switch self {
        case .isCertificateAuthority:
            return true
        case .notCertificateAuthority:
            return false
        }
    }

    /// Maximum path length constraint
    public var pathLenConstraint: Int? {
        switch self {
        case .isCertificateAuthority(let maxPathLength):
            return maxPathLength
        case .notCertificateAuthority:
            return nil
        }
    }
}

// MARK: - KeyUsage is already an OptionSet with properties like digitalSignature, keyCertSign, etc.

// MARK: - ExtendedKeyUsage Helpers

extension ExtendedKeyUsage {
    /// Checks if this EKU includes server authentication
    public var isServerAuth: Bool {
        contains(.serverAuth)
    }

    /// Checks if this EKU includes client authentication
    public var isClientAuth: Bool {
        contains(.clientAuth)
    }
}

// MARK: - SubjectAlternativeNames Helpers

extension SubjectAlternativeNames {
    /// Gets all DNS names from the SAN extension
    public var dnsNames: [String] {
        compactMap { name in
            switch name {
            case .dnsName(let dns):
                return dns
            default:
                return nil
            }
        }
    }

    /// Gets all email addresses from the SAN extension
    public var emailAddresses: [String] {
        compactMap { name in
            switch name {
            case .rfc822Name(let email):
                return email
            default:
                return nil
            }
        }
    }

    /// Gets all URIs from the SAN extension
    public var uris: [String] {
        compactMap { name in
            switch name {
            case .uniformResourceIdentifier(let uri):
                return uri
            default:
                return nil
            }
        }
    }
}

// MARK: - NameConstraints Helpers

extension X509.NameConstraints {
    /// Check if name constraints are empty
    public var isEmpty: Bool {
        permittedDNSDomains.isEmpty &&
        excludedDNSDomains.isEmpty &&
        permittedEmailAddresses.isEmpty &&
        excludedEmailAddresses.isEmpty &&
        permittedIPRanges.isEmpty &&
        excludedIPRanges.isEmpty &&
        permittedURIDomains.isEmpty &&
        forbiddenURIDomains.isEmpty
    }
}

// MARK: - Extension Value Access

extension X509Certificate {
    /// Represents a raw X.509 extension with OID and value
    public struct RawExtension: Sendable {
        /// The extension OID
        public let oid: ASN1ObjectIdentifier

        /// Whether this extension is critical
        public let critical: Bool

        /// The raw extension value (DER-encoded OCTET STRING contents)
        public let value: Data

        public init(oid: ASN1ObjectIdentifier, critical: Bool, value: Data) {
            self.oid = oid
            self.critical = critical
            self.value = value
        }
    }

    /// Gets the raw value of an extension by OID
    ///
    /// - Parameter oid: The OID to search for (e.g., "2.5.29.17" for Subject Alternative Name)
    /// - Returns: The raw extension value if found, nil otherwise
    public func extensionValue(for oid: String) -> Data? {
        guard let targetOID = try? ASN1ObjectIdentifier(dotRepresentation: oid) else {
            return nil
        }
        return extensionValue(for: targetOID)
    }

    /// Gets the raw value of an extension by OID
    ///
    /// - Parameter oid: The OID to search for
    /// - Returns: The raw extension value (contents of the OCTET STRING) if found, nil otherwise
    public func extensionValue(for oid: ASN1ObjectIdentifier) -> Data? {
        // Iterate through all extensions
        for ext in certificate.extensions {
            if ext.oid == oid {
                // Serialize the ASN1Any value
                var serializer = DER.Serializer()
                do {
                    try ext.value.serialize(into: &serializer)
                    let serialized = Data(serializer.serializedBytes)

                    // ASN1Any.serialize() adds a wrapper (tag + length).
                    // We need to skip this wrapper to get the actual content.
                    // The format is: <tag:1byte> <length:1+ bytes> <content>
                    guard serialized.count >= 2 else { return nil }

                    // Skip the ASN1Any wrapper tag
                    var offset = 1

                    // Parse length (DER length encoding)
                    let firstLengthByte = serialized[1]
                    if firstLengthByte < 0x80 {
                        // Short form: length is the byte itself
                        offset = 2
                    } else {
                        // Long form: first byte indicates number of length bytes
                        let numLengthBytes = Int(firstLengthByte & 0x7F)
                        offset = 2 + numLengthBytes
                    }

                    guard offset < serialized.count else { return nil }

                    // Return the content after the tag+length wrapper
                    return serialized.dropFirst(offset)
                } catch {
                    return nil
                }
            }
        }
        return nil
    }

    /// Gets a raw extension by OID including criticality
    ///
    /// - Parameter oid: The OID to search for
    /// - Returns: The raw extension if found, nil otherwise
    public func rawExtension(for oid: String) -> RawExtension? {
        guard let targetOID = try? ASN1ObjectIdentifier(dotRepresentation: oid) else {
            return nil
        }

        for ext in certificate.extensions {
            if ext.oid == targetOID {
                var serializer = DER.Serializer()
                do {
                    try ext.value.serialize(into: &serializer)
                    return RawExtension(
                        oid: ext.oid,
                        critical: ext.critical,
                        value: Data(serializer.serializedBytes)
                    )
                } catch {
                    return nil
                }
            }
        }
        return nil
    }

}
