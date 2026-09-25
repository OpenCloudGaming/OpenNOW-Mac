/// TLS 1.3 Signature Operations (RFC 8446 Section 4.2.3)
///
/// Supports ECDSA with P-256/P-384 and Ed25519.

import Foundation
import Crypto

// MARK: - TLS Signature

/// Signature operations for TLS 1.3
public enum TLSSignature {

    // MARK: - Signing

    /// Sign data using ECDSA with P-256
    /// - Parameters:
    ///   - data: The data to sign
    ///   - privateKey: The P-256 private key
    /// - Returns: The DER-encoded signature
    public static func sign(
        data: Data,
        privateKey: P256.Signing.PrivateKey
    ) throws -> Data {
        let signature = try privateKey.signature(for: data)
        return Data(signature.derRepresentation)
    }

    /// Sign data using the specified scheme
    /// - Parameters:
    ///   - data: The data to sign
    ///   - privateKey: The private key (as Data)
    ///   - scheme: The signature scheme
    /// - Returns: The signature
    public static func sign(
        data: Data,
        privateKey: Data,
        scheme: SignatureScheme
    ) throws -> Data {
        switch scheme {
        case .ecdsa_secp256r1_sha256:
            let key = try P256.Signing.PrivateKey(rawRepresentation: privateKey)
            return try sign(data: data, privateKey: key)
        default:
            throw SignatureError.unsupportedScheme(scheme)
        }
    }

    // MARK: - Verification

    /// Verify a signature using ECDSA with P-256
    /// - Parameters:
    ///   - signature: The DER-encoded signature
    ///   - data: The signed data
    ///   - publicKey: The P-256 public key
    /// - Returns: True if the signature is valid
    public static func verify(
        signature: Data,
        for data: Data,
        publicKey: P256.Signing.PublicKey
    ) throws -> Bool {
        let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
        return publicKey.isValidSignature(sig, for: data)
    }

    /// Verify a signature using the specified scheme
    /// - Parameters:
    ///   - signature: The signature
    ///   - data: The signed data
    ///   - publicKey: The public key (as Data, x963 format)
    ///   - scheme: The signature scheme
    /// - Returns: True if the signature is valid
    public static func verify(
        signature: Data,
        for data: Data,
        publicKey: Data,
        scheme: SignatureScheme
    ) throws -> Bool {
        switch scheme {
        case .ecdsa_secp256r1_sha256:
            let key = try P256.Signing.PublicKey(x963Representation: publicKey)
            return try verify(signature: signature, for: data, publicKey: key)
        default:
            throw SignatureError.unsupportedScheme(scheme)
        }
    }

    // MARK: - CertificateVerify Content

    /// Construct the content for CertificateVerify signature
    /// - Parameters:
    ///   - transcriptHash: The transcript hash
    ///   - isServer: Whether this is for server (true) or client (false)
    /// - Returns: The content to be signed
    public static func certificateVerifyContent(
        transcriptHash: Data,
        isServer: Bool
    ) -> Data {
        let context = isServer ? "TLS 1.3, server CertificateVerify" : "TLS 1.3, client CertificateVerify"
        let contextData = Data(context.utf8)

        // 64 spaces + context + 0x00 + transcript_hash
        var content = Data(repeating: 0x20, count: 64)
        content.append(contextData)
        content.append(0x00)
        content.append(transcriptHash)

        return content
    }
}

// MARK: - Signature Errors

/// Errors during signature operations
public enum SignatureError: Error, Sendable {
    case unsupportedScheme(SignatureScheme)
    case invalidSignature(String)
    case invalidPublicKey(String)
    case signingFailed(String)
}

// MARK: - Signing Key Wrapper

/// Wrapper for signing keys that supports multiple algorithms
public enum SigningKey: Sendable {
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)

    /// The signature scheme for this key
    public var scheme: SignatureScheme {
        switch self {
        case .p256: return .ecdsa_secp256r1_sha256
        case .p384: return .ecdsa_secp384r1_sha384
        case .ed25519: return .ed25519
        }
    }

    /// The public key bytes (x963 format for EC, raw for Ed25519)
    public var publicKeyBytes: Data {
        switch self {
        case .p256(let key):
            return Data(key.publicKey.x963Representation)
        case .p384(let key):
            return Data(key.publicKey.x963Representation)
        case .ed25519(let key):
            return Data(key.publicKey.rawRepresentation)
        }
    }

    /// The verification key corresponding to this signing key
    public var verificationKey: VerificationKey {
        switch self {
        case .p256(let key):
            return .p256(key.publicKey)
        case .p384(let key):
            return .p384(key.publicKey)
        case .ed25519(let key):
            return .ed25519(key.publicKey)
        }
    }

    /// Sign data
    public func sign(_ data: Data) throws -> Data {
        switch self {
        case .p256(let key):
            return try TLSSignature.sign(data: data, privateKey: key)
        case .p384(let key):
            let signature = try key.signature(for: data)
            return Data(signature.derRepresentation)
        case .ed25519(let key):
            let signature = try key.signature(for: data)
            return Data(signature)
        }
    }

    /// Generate a new P-256 signing key
    public static func generateP256() -> SigningKey {
        .p256(P256.Signing.PrivateKey())
    }

    /// Generate a new P-384 signing key
    public static func generateP384() -> SigningKey {
        .p384(P384.Signing.PrivateKey())
    }

    /// Generate a new Ed25519 signing key
    public static func generateEd25519() -> SigningKey {
        .ed25519(Curve25519.Signing.PrivateKey())
    }
}

// MARK: - Verification Key Wrapper

/// Wrapper for verification keys
public enum VerificationKey: Sendable {
    case p256(P256.Signing.PublicKey)
    case p384(P384.Signing.PublicKey)
    case ed25519(Curve25519.Signing.PublicKey)

    /// Create from public key bytes and scheme
    public init(publicKeyBytes: Data, scheme: SignatureScheme) throws {
        switch scheme {
        case .ecdsa_secp256r1_sha256:
            let key = try P256.Signing.PublicKey(x963Representation: publicKeyBytes)
            self = .p256(key)
        case .ecdsa_secp384r1_sha384:
            let key = try P384.Signing.PublicKey(x963Representation: publicKeyBytes)
            self = .p384(key)
        case .ed25519:
            let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyBytes)
            self = .ed25519(key)
        default:
            throw SignatureError.unsupportedScheme(scheme)
        }
    }

    /// The signature scheme for this key
    public var scheme: SignatureScheme {
        switch self {
        case .p256: return .ecdsa_secp256r1_sha256
        case .p384: return .ecdsa_secp384r1_sha384
        case .ed25519: return .ed25519
        }
    }

    /// Verify a signature
    public func verify(signature: Data, for data: Data) throws -> Bool {
        switch self {
        case .p256(let key):
            return try TLSSignature.verify(signature: signature, for: data, publicKey: key)
        case .p384(let key):
            let sig = try P384.Signing.ECDSASignature(derRepresentation: signature)
            return key.isValidSignature(sig, for: data)
        case .ed25519(let key):
            return key.isValidSignature(signature, for: data)
        }
    }
}
