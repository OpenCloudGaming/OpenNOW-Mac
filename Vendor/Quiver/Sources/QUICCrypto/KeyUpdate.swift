/// Key Update Management (RFC 9001 Section 6)
///
/// Tracks AEAD confidentiality and integrity limits to determine
/// when key updates are required. Also manages key update state.

import Foundation
import Synchronization

// MARK: - AEAD Limits

/// AEAD algorithm limits per RFC 9001 Section 6.6
///
/// These limits ensure cryptographic security by limiting how many
/// packets can be encrypted with the same key.
public struct AEADLimits: Sendable {
    /// Maximum packets that can be encrypted (confidentiality limit)
    public let confidentialityLimit: UInt64

    /// Maximum packets that can fail authentication (integrity limit)
    public let integrityLimit: UInt64

    /// AES-128-GCM and AES-256-GCM limits
    /// RFC 9001 Section 6.6: 2^23 packets
    public static let aesGCM = AEADLimits(
        confidentialityLimit: 1 << 23,  // ~8 million packets
        integrityLimit: 1 << 52         // Very high, practically unlimited
    )

    /// ChaCha20-Poly1305 limits
    /// RFC 9001 Section 6.6: 2^62 packets (effectively unlimited)
    public static let chaCha20Poly1305 = AEADLimits(
        confidentialityLimit: 1 << 62,
        integrityLimit: 1 << 36
    )

    public init(confidentialityLimit: UInt64, integrityLimit: UInt64) {
        self.confidentialityLimit = confidentialityLimit
        self.integrityLimit = integrityLimit
    }
}

// MARK: - Key Update State

/// Current state of key update process
public enum KeyUpdateState: Sendable, Equatable {
    /// No key update in progress
    case idle

    /// Key update initiated, waiting for peer acknowledgment
    case initiated

    /// Received key update from peer, updating keys
    case received
}

// MARK: - Key Usage Tracker

/// Tracks usage of a single key for AEAD limit enforcement
public struct AEADKeyUsage: Sendable {
    /// Number of packets encrypted with this key
    public var packetsEncrypted: UInt64 = 0

    /// Number of packets that failed decryption
    public var decryptionFailures: UInt64 = 0

    /// The AEAD limits for this key
    public let limits: AEADLimits

    public init(limits: AEADLimits) {
        self.limits = limits
    }

    /// Whether the confidentiality limit is approaching
    /// Returns true when 75% of the limit is reached
    public var isConfidentialityLimitApproaching: Bool {
        packetsEncrypted >= (limits.confidentialityLimit * 3) / 4
    }

    /// Whether the confidentiality limit has been exceeded
    public var isConfidentialityLimitExceeded: Bool {
        packetsEncrypted >= limits.confidentialityLimit
    }

    /// Whether the integrity limit has been exceeded
    public var isIntegrityLimitExceeded: Bool {
        decryptionFailures >= limits.integrityLimit
    }

    /// Records a packet encryption
    public mutating func recordEncryption() {
        packetsEncrypted += 1
    }

    /// Records a decryption failure
    public mutating func recordDecryptionFailure() {
        decryptionFailures += 1
    }
}

// MARK: - Key Update Manager

/// Manages key updates and AEAD limit tracking
///
/// RFC 9001 Section 6: Endpoints MUST initiate a key update before
/// exceeding AEAD confidentiality or integrity limits.
///
/// ## Usage
/// ```swift
/// let manager = KeyUpdateManager(cipherSuite: .aes128GcmSha256)
///
/// // Record packet operations
/// manager.recordEncryption()
/// manager.recordDecryptionFailure()
///
/// // Check if key update needed
/// if manager.shouldInitiateKeyUpdate {
///     // Initiate key update
///     manager.initiateKeyUpdate()
/// }
///
/// // After key update
/// manager.keyUpdateComplete(newKeyPhase: 1)
/// ```
public final class KeyUpdateManager: Sendable {
    private let state: Mutex<KeyUpdateManagerState>

    private struct KeyUpdateManagerState: Sendable {
        /// Current key usage
        var currentAEADKeyUsage: AEADKeyUsage

        /// Current key phase (0 or 1)
        var keyPhase: UInt8 = 0

        /// Key update state
        var updateState: KeyUpdateState = .idle

        /// Time of last key update
        var lastKeyUpdate: ContinuousClock.Instant?

        /// Minimum interval between key updates
        var minKeyUpdateInterval: Duration = .seconds(1)

        /// Total key updates performed
        var totalKeyUpdates: UInt64 = 0
    }

    // MARK: - Initialization

    /// Creates a key update manager
    /// - Parameter cipherSuite: The AEAD cipher suite in use
    public init(cipherSuite: QUICCipherSuite) {
        let limits: AEADLimits
        switch cipherSuite {
        case .chacha20Poly1305Sha256:
            limits = .chaCha20Poly1305
        case .aes128GcmSha256:
            limits = .aesGCM
        }

        self.state = Mutex(KeyUpdateManagerState(
            currentAEADKeyUsage: AEADKeyUsage(limits: limits)
        ))
    }

    // MARK: - Usage Recording

    /// Records a packet encryption
    public func recordEncryption() {
        state.withLock { s in
            s.currentAEADKeyUsage.recordEncryption()
        }
    }

    /// Records a decryption failure
    public func recordDecryptionFailure() {
        state.withLock { s in
            s.currentAEADKeyUsage.recordDecryptionFailure()
        }
    }

    // MARK: - Key Update Decisions

    /// Whether a key update should be initiated
    ///
    /// Returns true if:
    /// - Confidentiality limit is approaching, or
    /// - Integrity limit is exceeded
    public var shouldInitiateKeyUpdate: Bool {
        state.withLock { s in
            guard s.updateState == .idle else { return false }

            // Check minimum interval since last update
            if let lastUpdate = s.lastKeyUpdate {
                let elapsed = ContinuousClock.now - lastUpdate
                if elapsed < s.minKeyUpdateInterval {
                    return false
                }
            }

            return s.currentAEADKeyUsage.isConfidentialityLimitApproaching ||
                   s.currentAEADKeyUsage.isIntegrityLimitExceeded
        }
    }

    /// Whether a key update is required (limit exceeded)
    ///
    /// If this returns true, the connection MUST be closed if
    /// key update fails.
    public var isKeyUpdateRequired: Bool {
        state.withLock { s in
            s.currentAEADKeyUsage.isConfidentialityLimitExceeded ||
            s.currentAEADKeyUsage.isIntegrityLimitExceeded
        }
    }

    // MARK: - Key Update Operations

    /// Initiates a key update
    ///
    /// Call this when `shouldInitiateKeyUpdate` returns true.
    /// The key update completes when `keyUpdateComplete` is called.
    public func initiateKeyUpdate() {
        state.withLock { s in
            guard s.updateState == .idle else { return }
            s.updateState = .initiated
        }
    }

    /// Records that a key update was received from peer
    public func receiveKeyUpdate() {
        state.withLock { s in
            if s.updateState == .idle {
                s.updateState = .received
            }
        }
    }

    /// Completes the key update
    ///
    /// Call this after new keys are installed.
    ///
    /// - Parameter newKeyPhase: The new key phase (0 or 1)
    public func keyUpdateComplete(newKeyPhase: UInt8) {
        state.withLock { s in
            s.keyPhase = newKeyPhase
            s.updateState = .idle
            s.lastKeyUpdate = .now
            s.totalKeyUpdates += 1

            // Reset usage counters for new key
            s.currentAEADKeyUsage = AEADKeyUsage(limits: s.currentAEADKeyUsage.limits)
        }
    }

    // MARK: - State Queries

    /// Current key phase
    public var keyPhase: UInt8 {
        state.withLock { $0.keyPhase }
    }

    /// Current key update state
    public var updateState: KeyUpdateState {
        state.withLock { $0.updateState }
    }

    /// Total number of key updates performed
    public var totalKeyUpdates: UInt64 {
        state.withLock { $0.totalKeyUpdates }
    }

    /// Number of packets encrypted with current key
    public var packetsEncrypted: UInt64 {
        state.withLock { $0.currentAEADKeyUsage.packetsEncrypted }
    }

    /// Remaining packets before confidentiality limit
    public var remainingEncryptions: UInt64 {
        state.withLock { s in
            let used = s.currentAEADKeyUsage.packetsEncrypted
            let limit = s.currentAEADKeyUsage.limits.confidentialityLimit
            return used < limit ? limit - used : 0
        }
    }
}
