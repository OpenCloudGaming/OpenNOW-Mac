/// X.509 Certificate (RFC 5280)
///
/// Wrapper around swift-certificates' Certificate type for QUIC/TLS integration.

import Foundation
@preconcurrency import X509
import SwiftASN1

// Type alias to avoid naming conflict with TLS Certificate message
public typealias X509CertificateBase = X509.Certificate

// MARK: - X.509 Certificate

/// A parsed X.509 certificate wrapping swift-certificates' Certificate type
public struct X509Certificate: Sendable {
    /// The underlying swift-certificates Certificate
    public let certificate: X509CertificateBase

    /// Original DER-encoded certificate
    public let derEncoded: Data

    // MARK: - Properties (delegated to Certificate)

    /// Certificate version (0 = v1, 1 = v2, 2 = v3)
    public var version: Int {
        switch certificate.version {
        case .v1: return 0
        case .v3: return 2
        default: return 2
        }
    }

    /// Serial number (unique within issuer)
    public var serialNumber: Data {
        Data(certificate.serialNumber.bytes)
    }

    /// Signature algorithm used to sign the certificate
    public var signatureAlgorithm: SignatureAlgorithmIdentifier {
        SignatureAlgorithmIdentifier(certificate.signatureAlgorithm)
    }

    /// Certificate issuer (who signed this certificate)
    public var issuer: X509Name {
        X509Name(certificate.issuer)
    }

    /// Validity period
    public var validity: X509Validity {
        X509Validity(notBefore: certificate.notValidBefore, notAfter: certificate.notValidAfter)
    }

    /// Certificate subject (who this certificate identifies)
    public var subject: X509Name {
        X509Name(certificate.subject)
    }

    /// Subject's public key
    public var publicKey: X509CertificateBase.PublicKey {
        certificate.publicKey
    }

    /// Subject Public Key Info (SPKI) DER-encoded bytes
    ///
    /// This is the DER encoding of the SubjectPublicKeyInfo structure,
    /// which includes the algorithm identifier and the public key bits.
    public var subjectPublicKeyInfoDER: Data {
        var serializer = DER.Serializer()
        do {
            try certificate.publicKey.serialize(into: &serializer)
            return Data(serializer.serializedBytes)
        } catch {
            return Data()
        }
    }

    /// Extensions (v3 only)
    public var extensions: X509CertificateBase.Extensions {
        certificate.extensions
    }

    /// The TBS (To-Be-Signed) certificate bytes for signature verification
    public var tbsCertificateBytes: Data {
        Data(certificate.tbsCertificateBytes)
    }

    /// The signature value (DER-encoded for ECDSA, raw bytes for Ed25519)
    ///
    /// Extracted from the DER-encoded certificate structure:
    /// ```
    /// Certificate ::= SEQUENCE {
    ///     tbsCertificate      TBSCertificate,
    ///     signatureAlgorithm  AlgorithmIdentifier,
    ///     signatureValue      BIT STRING
    /// }
    /// ```
    public var signatureValue: Data {
        do {
            let certValue = try ASN1Parser.parseOne(from: derEncoded)
            guard certValue.tag.isSequence, certValue.children.count >= 3 else {
                return Data()
            }
            let (_, signatureBytes) = try certValue.children[2].asBitString()
            return signatureBytes
        } catch {
            return Data()
        }
    }

    // MARK: - Computed Properties

    /// Whether this is a self-signed certificate
    public var isSelfSigned: Bool {
        certificate.issuer == certificate.subject
    }

    /// Whether this is a CA certificate (based on BasicConstraints)
    public var isCA: Bool {
        guard let bc = try? certificate.extensions.basicConstraints else {
            return false
        }
        switch bc {
        case .isCertificateAuthority:
            return true
        case .notCertificateAuthority:
            return false
        }
    }

    /// Path length constraint (if any)
    public var pathLengthConstraint: Int? {
        guard let bc = try? certificate.extensions.basicConstraints else {
            return nil
        }
        switch bc {
        case .isCertificateAuthority(let maxPathLength):
            return maxPathLength
        case .notCertificateAuthority:
            return nil
        }
    }

    // MARK: - Initialization

    /// Creates an X509Certificate from a swift-certificates Certificate
    public init(_ certificate: X509CertificateBase, derEncoded: Data) {
        self.certificate = certificate
        self.derEncoded = derEncoded
    }

    // MARK: - Parsing

    /// Parses an X.509 certificate from DER-encoded data
    public static func parse(from data: Data) throws -> X509Certificate {
        do {
            let certificate = try X509CertificateBase(derEncoded: Array(data))
            return X509Certificate(certificate, derEncoded: data)
        } catch {
            throw X509Error.asn1Error(ASN1Error.invalidFormat("Failed to parse certificate: \(error)"))
        }
    }
}

// MARK: - Signature Algorithm Identifier

/// Algorithm identifier wrapper for swift-certificates' SignatureAlgorithm
public struct SignatureAlgorithmIdentifier: Sendable, Equatable {
    /// The underlying SignatureAlgorithm
    public let signatureAlgorithm: X509CertificateBase.SignatureAlgorithm

    /// Algorithm OID
    public var algorithm: ASN1ObjectIdentifier {
        switch signatureAlgorithm {
        case .ecdsaWithSHA256:
            return try! ASN1ObjectIdentifier(dotRepresentation: "1.2.840.10045.4.3.2")
        case .ecdsaWithSHA384:
            return try! ASN1ObjectIdentifier(dotRepresentation: "1.2.840.10045.4.3.3")
        case .ecdsaWithSHA512:
            return try! ASN1ObjectIdentifier(dotRepresentation: "1.2.840.10045.4.3.4")
        case .ed25519:
            return try! ASN1ObjectIdentifier(dotRepresentation: "1.3.101.112")
        default:
            return try! ASN1ObjectIdentifier(dotRepresentation: "1.2.840.10045.4.3.2")
        }
    }

    public init(_ signatureAlgorithm: X509CertificateBase.SignatureAlgorithm) {
        self.signatureAlgorithm = signatureAlgorithm
    }

    /// The known algorithm type if recognized
    public var knownAlgorithm: KnownOID? {
        switch signatureAlgorithm {
        case .ecdsaWithSHA256:
            return .ecdsaWithSHA256
        case .ecdsaWithSHA384:
            return .ecdsaWithSHA384
        case .ecdsaWithSHA512:
            return .ecdsaWithSHA512
        case .ed25519:
            return .ed25519
        default:
            return nil
        }
    }

    /// Maps this algorithm to a SignatureScheme (if applicable)
    public var signatureScheme: SignatureScheme? {
        switch signatureAlgorithm {
        case .ecdsaWithSHA256:
            return .ecdsa_secp256r1_sha256
        case .ecdsaWithSHA384:
            return .ecdsa_secp384r1_sha384
        case .ed25519:
            return .ed25519
        default:
            return nil
        }
    }
}

// MARK: - X.509 Name

/// X.509 Distinguished Name (DN) wrapper
public struct X509Name: Sendable, Equatable, Hashable {
    /// The underlying DistinguishedName
    public let distinguishedName: DistinguishedName

    /// Relative Distinguished Names in order
    public var rdnSequence: [RelativeDistinguishedName] {
        Array(distinguishedName)
    }

    /// Common Name (CN)
    public var commonName: String? {
        findAttribute(.RDNAttributeType.commonName)
    }

    /// Organization (O)
    public var organization: String? {
        findAttribute(.RDNAttributeType.organizationName)
    }

    /// Organizational Unit (OU)
    public var organizationalUnit: String? {
        findAttribute(.RDNAttributeType.organizationalUnitName)
    }

    /// Country (C)
    public var country: String? {
        findAttribute(.RDNAttributeType.countryName)
    }

    /// State/Province (ST)
    public var stateOrProvince: String? {
        findAttribute(.RDNAttributeType.stateOrProvinceName)
    }

    /// Locality (L)
    public var locality: String? {
        findAttribute(.RDNAttributeType.localityName)
    }

    private func findAttribute(_ oid: ASN1ObjectIdentifier) -> String? {
        for rdn in distinguishedName {
            for attr in rdn {
                if attr.type == oid {
                    return attr.description
                }
            }
        }
        return nil
    }

    public init(_ distinguishedName: DistinguishedName) {
        self.distinguishedName = distinguishedName
    }

    /// Returns a string representation (e.g., "CN=example.com, O=Example Inc")
    public var string: String {
        String(describing: distinguishedName)
    }

    public static func == (lhs: X509Name, rhs: X509Name) -> Bool {
        lhs.distinguishedName == rhs.distinguishedName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(distinguishedName)
    }
}

// MARK: - X.509 Validity

/// Certificate validity period
public struct X509Validity: Sendable {
    /// Not valid before this time
    public let notBefore: Date

    /// Not valid after this time
    public let notAfter: Date

    /// Checks if the certificate is valid at the given time
    public func isValid(at date: Date = Date()) -> Bool {
        date >= notBefore && date <= notAfter
    }

    public init(notBefore: Date, notAfter: Date) {
        self.notBefore = notBefore
        self.notAfter = notAfter
    }
}

// MARK: - CustomStringConvertible

extension X509Certificate: CustomStringConvertible {
    public var description: String {
        """
        X509Certificate {
            version: v\(version + 1)
            serialNumber: \(serialNumber.hexString)
            issuer: \(issuer.string)
            subject: \(subject.string)
            validity: \(validity.notBefore) - \(validity.notAfter)
            algorithm: \(signatureAlgorithm.algorithm)
            isCA: \(isCA)
        }
        """
    }
}

// MARK: - Data Extension

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// Note: KnownOID is defined in ASN1Value.swift
