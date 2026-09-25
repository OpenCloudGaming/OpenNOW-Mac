/// TLS 1.3 Key Exchange (RFC 8446 Section 4.2.8)
///
/// Supports X25519 and P-256 (secp256r1) key agreement.

import Foundation
import Crypto

// MARK: - Key Exchange

/// Key exchange abstraction for TLS 1.3
public enum KeyExchange: Sendable {
    case x25519(Curve25519.KeyAgreement.PrivateKey)
    case p256(P256.KeyAgreement.PrivateKey)

    // MARK: - Generation

    /// Generate a new key pair for the specified named group
    /// - Parameter group: The named group (curve)
    /// - Returns: A new key exchange instance
    public static func generate(for group: NamedGroup) throws -> KeyExchange {
        switch group {
        case .x25519:
            return .x25519(Curve25519.KeyAgreement.PrivateKey())
        case .secp256r1:
            return .p256(P256.KeyAgreement.PrivateKey())
        default:
            throw KeyExchangeError.unsupportedGroup(group)
        }
    }

    // MARK: - Properties

    /// The named group for this key exchange
    public var group: NamedGroup {
        switch self {
        case .x25519: return .x25519
        case .p256: return .secp256r1
        }
    }

    /// The public key bytes (for key_share extension)
    ///
    /// - X25519: 32 bytes (raw representation)
    /// - P-256: 65 bytes (uncompressed point, 0x04 || x || y)
    public var publicKeyBytes: Data {
        switch self {
        case .x25519(let privateKey):
            return Data(privateKey.publicKey.rawRepresentation)
        case .p256(let privateKey):
            return Data(privateKey.publicKey.x963Representation)
        }
    }

    // MARK: - Key Agreement

    /// Perform key agreement with a peer's public key
    /// - Parameter peerPublicKeyBytes: The peer's public key bytes
    /// - Returns: The shared secret
    public func sharedSecret(with peerPublicKeyBytes: Data) throws -> SharedSecret {
        switch self {
        case .x25519(let privateKey):
            guard peerPublicKeyBytes.count == 32 else {
                throw KeyExchangeError.invalidPublicKey("X25519 public key must be 32 bytes")
            }
            let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerPublicKeyBytes
            )
            return try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)

        case .p256(let privateKey):
            // P-256 uses x963 representation (uncompressed point)
            let peerPublicKey = try P256.KeyAgreement.PublicKey(
                x963Representation: peerPublicKeyBytes
            )
            return try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        }
    }

    // MARK: - Key Share Entry

    /// Create a KeyShareEntry for this key exchange
    public func keyShareEntry() -> KeyShareEntry {
        KeyShareEntry(group: group, keyExchange: publicKeyBytes)
    }
}

// MARK: - Static Key Agreement

extension KeyExchange {
    /// Perform key agreement given a named group and peer public key
    /// - Parameters:
    ///   - group: The named group
    ///   - ourPrivateKeyBytes: Our private key bytes (optional, will generate if nil)
    ///   - peerPublicKeyBytes: The peer's public key bytes
    /// - Returns: Tuple of (sharedSecret, ourPublicKeyBytes)
    public static func performKeyAgreement(
        group: NamedGroup,
        peerPublicKeyBytes: Data
    ) throws -> (sharedSecret: SharedSecret, ourPublicKeyBytes: Data) {
        let keyExchange = try generate(for: group)
        let sharedSecret = try keyExchange.sharedSecret(with: peerPublicKeyBytes)
        return (sharedSecret, keyExchange.publicKeyBytes)
    }
}

// MARK: - Key Exchange Errors

/// Errors during key exchange
public enum KeyExchangeError: Error, Sendable {
    case unsupportedGroup(NamedGroup)
    case invalidPublicKey(String)
    case keyAgreementFailed(String)
}

// MARK: - Shared Secret Extension

extension SharedSecret {
    /// Get the raw bytes of the shared secret
    public var rawRepresentation: Data {
        withUnsafeBytes { Data($0) }
    }
}
