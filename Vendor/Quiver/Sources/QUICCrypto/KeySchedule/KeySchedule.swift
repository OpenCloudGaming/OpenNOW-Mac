/// QUIC Key Schedule (RFC 9001 Section 5)
///
/// Manages key derivation for QUIC connections across all encryption levels.
/// Handles initial, handshake, application, and key update secrets.

import Foundation
import Crypto
import QUICCore

// MARK: - Key Schedule

/// Manages QUIC key derivation across encryption levels
public struct KeySchedule: Sendable {
    /// Current encryption level
    private var currentLevel: EncryptionLevel

    /// Client secrets per level
    private var clientSecrets: [EncryptionLevel: SymmetricKey]

    /// Server secrets per level
    private var serverSecrets: [EncryptionLevel: SymmetricKey]

    /// Derived key material per level (client side)
    private var clientKeys: [EncryptionLevel: KeyMaterial]

    /// Derived key material per level (server side)
    private var serverKeys: [EncryptionLevel: KeyMaterial]

    /// Current key phase (for 1-RTT key updates)
    private var keyPhase: UInt8

    /// Key update count (for debugging/logging)
    private var keyUpdateCount: UInt64

    // MARK: - Initialization

    /// Creates a new KeySchedule
    public init() {
        self.currentLevel = .initial
        self.clientSecrets = [:]
        self.serverSecrets = [:]
        self.clientKeys = [:]
        self.serverKeys = [:]
        self.keyPhase = 0
        self.keyUpdateCount = 0
    }

    // MARK: - Initial Keys

    /// Derives initial keys from the destination connection ID
    /// - Parameters:
    ///   - connectionID: The Destination Connection ID from the first Initial packet
    ///   - version: The QUIC version
    /// - Returns: Client and server key material tuple
    public mutating func deriveInitialKeys(
        connectionID: ConnectionID,
        version: QUICVersion
    ) throws -> (client: KeyMaterial, server: KeyMaterial) {
        let secrets = try InitialSecrets.derive(connectionID: connectionID, version: version)

        clientSecrets[.initial] = secrets.clientSecret
        serverSecrets[.initial] = secrets.serverSecret

        let clientKey = try KeyMaterial.derive(from: secrets.clientSecret)
        let serverKey = try KeyMaterial.derive(from: secrets.serverSecret)

        clientKeys[.initial] = clientKey
        serverKeys[.initial] = serverKey
        currentLevel = .initial

        return (client: clientKey, server: serverKey)
    }

    // MARK: - Handshake Keys

    /// Sets handshake secrets from TLS and derives key material
    /// - Parameters:
    ///   - clientSecret: Client handshake secret from TLS
    ///   - serverSecret: Server handshake secret from TLS
    /// - Returns: Client and server key material tuple
    public mutating func setHandshakeSecrets(
        clientSecret: SymmetricKey,
        serverSecret: SymmetricKey
    ) throws -> (client: KeyMaterial, server: KeyMaterial) {
        clientSecrets[.handshake] = clientSecret
        serverSecrets[.handshake] = serverSecret

        let clientKey = try KeyMaterial.derive(from: clientSecret)
        let serverKey = try KeyMaterial.derive(from: serverSecret)

        clientKeys[.handshake] = clientKey
        serverKeys[.handshake] = serverKey
        currentLevel = .handshake

        return (client: clientKey, server: serverKey)
    }

    // MARK: - Application Keys

    /// Sets application (1-RTT) secrets from TLS and derives key material
    /// - Parameters:
    ///   - clientSecret: Client application secret from TLS
    ///   - serverSecret: Server application secret from TLS
    /// - Returns: Client and server key material tuple
    public mutating func setApplicationSecrets(
        clientSecret: SymmetricKey,
        serverSecret: SymmetricKey
    ) throws -> (client: KeyMaterial, server: KeyMaterial) {
        clientSecrets[.application] = clientSecret
        serverSecrets[.application] = serverSecret

        let clientKey = try KeyMaterial.derive(from: clientSecret)
        let serverKey = try KeyMaterial.derive(from: serverSecret)

        clientKeys[.application] = clientKey
        serverKeys[.application] = serverKey
        currentLevel = .application

        return (client: clientKey, server: serverKey)
    }

    // MARK: - Key Update (RFC 9001 Section 6)

    /// Performs a key update for 1-RTT keys
    ///
    /// Key update derives new secrets using "quic ku" label:
    /// ```
    /// secret_<n+1> = HKDF-Expand-Label(secret_<n>, "quic ku", "", 32)
    /// ```
    ///
    /// - Returns: New client and server key material tuple
    public mutating func updateKeys() throws -> (client: KeyMaterial, server: KeyMaterial) {
        guard let clientAppSecret = clientSecrets[.application],
              let serverAppSecret = serverSecrets[.application] else {
            throw KeyScheduleError.applicationSecretsNotSet
        }

        // Derive new secrets using "quic ku" label
        let newClientSecretData = try hkdfExpandLabel(
            secret: clientAppSecret,
            label: "quic ku",
            context: Data(),
            length: 32
        )
        let newServerSecretData = try hkdfExpandLabel(
            secret: serverAppSecret,
            label: "quic ku",
            context: Data(),
            length: 32
        )

        let newClientSecret = SymmetricKey(data: newClientSecretData)
        let newServerSecret = SymmetricKey(data: newServerSecretData)

        // Update stored secrets
        clientSecrets[.application] = newClientSecret
        serverSecrets[.application] = newServerSecret

        // Derive new key material
        let clientKey = try KeyMaterial.derive(from: newClientSecret)
        let serverKey = try KeyMaterial.derive(from: newServerSecret)

        clientKeys[.application] = clientKey
        serverKeys[.application] = serverKey

        // Toggle key phase
        keyPhase ^= 1
        keyUpdateCount += 1

        return (client: clientKey, server: serverKey)
    }

    // MARK: - Accessors

    /// Gets client key material for an encryption level
    /// - Parameter level: The encryption level
    /// - Returns: Key material if available
    public func clientKeyMaterial(for level: EncryptionLevel) -> KeyMaterial? {
        clientKeys[level]
    }

    /// Gets server key material for an encryption level
    /// - Parameter level: The encryption level
    /// - Returns: Key material if available
    public func serverKeyMaterial(for level: EncryptionLevel) -> KeyMaterial? {
        serverKeys[level]
    }

    /// Gets the client secret for an encryption level
    /// - Parameter level: The encryption level
    /// - Returns: Secret if available
    public func clientSecret(for level: EncryptionLevel) -> SymmetricKey? {
        clientSecrets[level]
    }

    /// Gets the server secret for an encryption level
    /// - Parameter level: The encryption level
    /// - Returns: Secret if available
    public func serverSecret(for level: EncryptionLevel) -> SymmetricKey? {
        serverSecrets[level]
    }

    /// The current encryption level
    public var level: EncryptionLevel {
        currentLevel
    }

    /// The current key phase bit (0 or 1)
    public var currentKeyPhase: UInt8 {
        keyPhase
    }

    /// Number of key updates performed
    public var updateCount: UInt64 {
        keyUpdateCount
    }

    /// Whether keys are available for a given level
    public func hasKeys(for level: EncryptionLevel) -> Bool {
        clientKeys[level] != nil && serverKeys[level] != nil
    }

    // MARK: - Level Management

    /// Discards keys for a given encryption level
    /// - Parameter level: The encryption level to discard
    ///
    /// Per RFC 9001 Section 4.9, keys should be discarded when:
    /// - Initial keys: After receiving Handshake packet
    /// - Handshake keys: After handshake confirmed
    public mutating func discardKeys(for level: EncryptionLevel) {
        clientSecrets.removeValue(forKey: level)
        serverSecrets.removeValue(forKey: level)
        clientKeys.removeValue(forKey: level)
        serverKeys.removeValue(forKey: level)
    }
}

// MARK: - Errors

/// Errors thrown by KeySchedule operations
public enum KeyScheduleError: Error, Sendable {
    /// Application secrets have not been set (required for key update)
    case applicationSecretsNotSet
    /// Secrets for the requested level are not available
    case secretsNotAvailable(EncryptionLevel)
    /// Key derivation failed
    case keyDerivationFailed(String)
}
