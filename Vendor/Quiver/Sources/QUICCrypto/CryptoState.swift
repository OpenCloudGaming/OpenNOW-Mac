/// QUIC Crypto State
///
/// Manages cryptographic state for QUIC connections including
/// key derivation and packet protection.

import Foundation
import Crypto
import QUICCore

// MARK: - Crypto Errors

/// Errors that can occur during cryptographic operations
public enum CryptoError: Error, Sendable {
    /// IV is too short for the cipher
    case invalidIVLength(expected: Int, actual: Int)
    /// Sample is too short for header protection
    case insufficientSample(expected: Int, actual: Int)
    /// Header protection encryption failed
    case headerProtectionFailed
    /// Header protection not available on this platform
    case unsupportedPlatform(String)
    /// AEAD encryption/decryption failed
    case aeadFailed
}

// MARK: - Header Protection

/// Protocol for header protection operations (RFC 9001 Section 5.4)
public protocol HeaderProtection: Sendable {
    /// Generates a 5-byte mask from a 16-byte sample
    /// - Parameter sample: The 16-byte sample from the packet
    /// - Returns: 5-byte mask for header protection
    /// - Throws: CryptoError if sample is insufficient or encryption fails
    func mask(sample: Data) throws -> Data
}

// MARK: - Crypto Open/Seal (inspired by quiche)

/// Packet opener (decryption)
///
/// Extends PacketOpenerProtocol from QUICCore for compatibility with PacketDecoder.
/// All method requirements are inherited from PacketOpenerProtocol.
public protocol PacketOpener: PacketOpenerProtocol {}

/// Packet sealer (encryption)
///
/// Extends PacketSealerProtocol from QUICCore for compatibility with PacketEncoder.
/// All method requirements are inherited from PacketSealerProtocol.
public protocol PacketSealer: PacketSealerProtocol {}

// MARK: - Crypto Context

/// Cryptographic context for a single encryption level
public struct CryptoContext: Sendable {
    /// The opener for this level (decryption)
    public let opener: (any PacketOpener)?

    /// The sealer for this level (encryption)
    public let sealer: (any PacketSealer)?

    /// Creates an empty crypto context
    public init() {
        self.opener = nil
        self.sealer = nil
    }

    /// Creates a crypto context with opener and sealer
    public init(opener: any PacketOpener, sealer: any PacketSealer) {
        self.opener = opener
        self.sealer = sealer
    }

    /// Creates a crypto context with optional opener and/or sealer
    /// Used for 0-RTT where only one direction is available
    public init(opener: (any PacketOpener)?, sealer: (any PacketSealer)?) {
        self.opener = opener
        self.sealer = sealer
    }
}

// MARK: - Crypto State

/// Manages all cryptographic state for a connection
public final class CryptoState: Sendable {
    /// Crypto contexts for each encryption level
    private let contexts: [EncryptionLevel: CryptoContext]

    /// Creates a new crypto state
    public init(contexts: [EncryptionLevel: CryptoContext] = [:]) {
        self.contexts = contexts
    }

    /// Gets the crypto context for an encryption level
    public func context(for level: EncryptionLevel) -> CryptoContext? {
        contexts[level]
    }

    /// Creates a new crypto state with an updated context for a level
    public func withContext(_ context: CryptoContext, for level: EncryptionLevel) -> CryptoState {
        var newContexts = contexts
        newContexts[level] = context
        return CryptoState(contexts: newContexts)
    }
}
