/// X.509 Certificate Errors
///
/// Defines errors that can occur during X.509 certificate parsing and validation.

import Foundation

// MARK: - X.509 Errors

/// Errors that can occur during X.509 operations
public enum X509Error: Error, Sendable {
    // MARK: - Parsing Errors

    /// Invalid certificate structure
    case invalidCertificateStructure(String)

    /// Missing required field
    case missingRequiredField(String)

    /// Invalid field value
    case invalidFieldValue(field: String, reason: String)

    /// Unsupported certificate version
    case unsupportedVersion(Int)

    /// ASN.1 parsing error
    case asn1Error(ASN1Error)

    // MARK: - Signature Errors

    /// Unsupported signature algorithm
    case unsupportedSignatureAlgorithm(String)

    /// Signature verification failed
    case signatureVerificationFailed(String)

    /// Signature algorithm mismatch
    case signatureAlgorithmMismatch

    // MARK: - Public Key Errors

    /// Unsupported public key algorithm
    case unsupportedPublicKeyAlgorithm(String)

    /// Invalid public key data
    case invalidPublicKey(String)

    /// Missing curve parameter for EC key
    case missingCurveParameter

    /// Unsupported elliptic curve
    case unsupportedCurve(String)

    // MARK: - Validation Errors

    /// Certificate has expired
    case certificateExpired(notAfter: Date)

    /// Certificate is not yet valid
    case certificateNotYetValid(notBefore: Date)

    /// Certificate chain is empty
    case emptyChain

    /// No trusted root found
    case untrustedRoot

    /// Certificate is not a CA but was used as one
    case notCA

    /// Path length constraint exceeded
    case pathLengthExceeded(allowed: Int, actual: Int)

    /// Invalid key usage for the operation
    case invalidKeyUsage(String)

    /// Hostname does not match certificate
    case hostnameMismatch(expected: String, actual: [String])

    /// Required extension is missing
    case missingExtension(String)

    /// Extension has invalid value
    case invalidExtension(oid: String, reason: String)

    /// Self-signed certificate is not trusted
    case selfSignedNotTrusted

    /// Issuer certificate not found in chain
    case issuerNotFound(issuer: String)

    /// Certificate revoked
    case certificateRevoked

    /// Invalid Extended Key Usage (RFC 5280 Section 4.2.1.12)
    case invalidExtendedKeyUsage(required: String, found: [String])

    /// Malformed Subject Alternative Name entry
    case malformedSAN(type: String, value: String)

    /// Name Constraints violation (RFC 5280 Section 4.2.1.10)
    case nameConstraintsViolation(name: String, reason: String)

    // MARK: - Internal Errors

    /// Internal error
    case internalError(String)
}

// MARK: - CustomStringConvertible

extension X509Error: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidCertificateStructure(let reason):
            return "Invalid certificate structure: \(reason)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .invalidFieldValue(let field, let reason):
            return "Invalid value for \(field): \(reason)"
        case .unsupportedVersion(let version):
            return "Unsupported certificate version: \(version)"
        case .asn1Error(let error):
            return "ASN.1 error: \(error)"
        case .unsupportedSignatureAlgorithm(let alg):
            return "Unsupported signature algorithm: \(alg)"
        case .signatureVerificationFailed(let reason):
            return "Signature verification failed: \(reason)"
        case .signatureAlgorithmMismatch:
            return "Signature algorithm in TBSCertificate does not match outer signature"
        case .unsupportedPublicKeyAlgorithm(let alg):
            return "Unsupported public key algorithm: \(alg)"
        case .invalidPublicKey(let reason):
            return "Invalid public key: \(reason)"
        case .missingCurveParameter:
            return "EC public key missing curve parameter"
        case .unsupportedCurve(let curve):
            return "Unsupported elliptic curve: \(curve)"
        case .certificateExpired(let notAfter):
            return "Certificate expired on \(notAfter)"
        case .certificateNotYetValid(let notBefore):
            return "Certificate not valid until \(notBefore)"
        case .emptyChain:
            return "Certificate chain is empty"
        case .untrustedRoot:
            return "Certificate chain does not lead to a trusted root"
        case .notCA:
            return "Certificate is not a CA but was used to sign another certificate"
        case .pathLengthExceeded(let allowed, let actual):
            return "Path length constraint exceeded: allowed \(allowed), actual \(actual)"
        case .invalidKeyUsage(let reason):
            return "Invalid key usage: \(reason)"
        case .hostnameMismatch(let expected, let actual):
            return "Hostname mismatch: expected \(expected), certificate has \(actual)"
        case .missingExtension(let ext):
            return "Missing required extension: \(ext)"
        case .invalidExtension(let oid, let reason):
            return "Invalid extension \(oid): \(reason)"
        case .selfSignedNotTrusted:
            return "Self-signed certificate is not in the trust store"
        case .issuerNotFound(let issuer):
            return "Issuer certificate not found: \(issuer)"
        case .certificateRevoked:
            return "Certificate has been revoked"
        case .invalidExtendedKeyUsage(let required, let found):
            return "Invalid Extended Key Usage: required \(required), found \(found.isEmpty ? "none" : found.joined(separator: ", "))"
        case .malformedSAN(let type, let value):
            return "Malformed Subject Alternative Name: \(type) = \(value)"
        case .nameConstraintsViolation(let name, let reason):
            return "Name Constraints violation: \(name) - \(reason)"
        case .internalError(let reason):
            return "Internal error: \(reason)"
        }
    }
}

// MARK: - LocalizedError

extension X509Error: LocalizedError {
    public var errorDescription: String? {
        description
    }
}
