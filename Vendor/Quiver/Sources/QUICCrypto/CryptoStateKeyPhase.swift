/// QUIC Crypto State Key Phase Extension (RFC 9001 Section 6)
///
/// Extends crypto state management to support 1-RTT key phase rotation.
/// Key updates are signaled via the Key Phase bit in short header packets.

import Foundation
import Synchronization
import Crypto
import QUICCore

// MARK: - Key Phase Context

/// Context for managing key phase transitions in 1-RTT packets
public struct KeyPhaseContext: Sendable {
    /// Current key phase bit (0 or 1)
    public let currentPhase: UInt8

    /// Opener for current key phase
    public let currentOpener: any PacketOpener

    /// Sealer for current key phase
    public let currentSealer: any PacketSealer

    /// Opener for previous key phase (for in-flight packets during transition)
    public let previousOpener: (any PacketOpener)?

    /// Opener for next key phase (speculatively derived for incoming key updates)
    public let nextOpener: (any PacketOpener)?

    /// Number of key updates performed
    public let updateCount: UInt64

    /// Creates an initial key phase context
    public init(
        opener: any PacketOpener,
        sealer: any PacketSealer
    ) {
        self.currentPhase = 0
        self.currentOpener = opener
        self.currentSealer = sealer
        self.previousOpener = nil
        self.nextOpener = nil
        self.updateCount = 0
    }

    /// Creates a key phase context with all components
    public init(
        currentPhase: UInt8,
        currentOpener: any PacketOpener,
        currentSealer: any PacketSealer,
        previousOpener: (any PacketOpener)?,
        nextOpener: (any PacketOpener)?,
        updateCount: UInt64
    ) {
        self.currentPhase = currentPhase
        self.currentOpener = currentOpener
        self.currentSealer = currentSealer
        self.previousOpener = previousOpener
        self.nextOpener = nextOpener
        self.updateCount = updateCount
    }

    /// Gets the opener for a specific key phase bit
    /// - Parameter phase: The key phase bit from the packet header
    /// - Returns: The appropriate opener, or nil if not available
    public func opener(for phase: UInt8) -> (any PacketOpener)? {
        if phase == currentPhase {
            return currentOpener
        } else if let prev = previousOpener {
            // During key update transition, try previous keys
            return prev
        } else if let next = nextOpener {
            // Peer initiated key update, try next keys
            return next
        }
        return nil
    }
}

// MARK: - Key Phase Manager

/// Manages key phase transitions for a connection
public final class KeyPhaseManager: Sendable {
    /// Internal state
    private let state: Mutex<KeyPhaseState>

    /// Key schedule for deriving new keys
    private let keySchedule: Mutex<KeySchedule>

    /// Whether we're the client (affects which keys to use)
    private let isClient: Bool

    /// Creates a new key phase manager
    /// - Parameters:
    ///   - keySchedule: The key schedule to use for key derivation
    ///   - isClient: Whether this endpoint is a client
    public init(keySchedule: KeySchedule, isClient: Bool) {
        self.keySchedule = Mutex(keySchedule)
        self.isClient = isClient
        self.state = Mutex(KeyPhaseState())
    }

    /// Sets the initial application keys
    /// - Parameter context: The initial key phase context
    public func setInitialContext(_ context: KeyPhaseContext) {
        state.withLock { state in
            state.context = context
            state.keyUpdateAllowed = true
        }
    }

    /// Gets the current key phase context
    public var context: KeyPhaseContext? {
        state.withLock { $0.context }
    }

    /// Gets the current key phase bit
    public var currentPhase: UInt8 {
        state.withLock { $0.context?.currentPhase ?? 0 }
    }

    /// Initiates a key update
    ///
    /// Per RFC 9001 Section 6.1, key updates can only be initiated once the
    /// handshake is confirmed and there are no unacknowledged packets with
    /// the old keys.
    ///
    /// - Returns: The new key phase context
    /// - Throws: KeyPhaseError if key update is not allowed
    public func initiateKeyUpdate() throws -> KeyPhaseContext {
        try state.withLock { state in
            guard let currentContext = state.context else {
                throw KeyPhaseError.noApplicationKeys
            }

            guard state.keyUpdateAllowed else {
                throw KeyPhaseError.keyUpdateNotAllowed
            }

            // Derive new keys
            let (clientKey, serverKey) = try keySchedule.withLock { schedule in
                try schedule.updateKeys()
            }

            // Create new opener and sealer
            let newOpener = try createOpener(
                from: isClient ? serverKey : clientKey
            )
            let newSealer = try createSealer(
                from: isClient ? clientKey : serverKey
            )

            // Toggle phase
            let newPhase = currentContext.currentPhase ^ 1

            let newContext = KeyPhaseContext(
                currentPhase: newPhase,
                currentOpener: newOpener,
                currentSealer: newSealer,
                previousOpener: currentContext.currentOpener,
                nextOpener: nil,
                updateCount: currentContext.updateCount + 1
            )

            state.context = newContext
            state.keyUpdateAllowed = false  // Must be re-enabled after ACK
            state.lastKeyUpdateTime = .now

            return newContext
        }
    }

    /// Handles a received packet with a different key phase
    ///
    /// When receiving a packet with a different key phase bit, this may
    /// indicate a peer-initiated key update.
    ///
    /// - Parameter receivedPhase: The key phase bit from the received packet
    /// - Returns: The opener to use for decryption
    /// - Throws: KeyPhaseError if keys are not available
    public func handleReceivedKeyPhase(_ receivedPhase: UInt8) throws -> any PacketOpener {
        try state.withLock { state in
            guard let currentContext = state.context else {
                throw KeyPhaseError.noApplicationKeys
            }

            if receivedPhase == currentContext.currentPhase {
                // Same phase - use current keys
                return currentContext.currentOpener
            }

            // Different phase - peer initiated key update
            if let nextOpener = currentContext.nextOpener {
                // We've already derived next keys
                return nextOpener
            }

            if let prevOpener = currentContext.previousOpener {
                // In-flight packet from before our key update
                return prevOpener
            }

            // Need to derive new keys for peer's update
            let (clientKey, serverKey) = try keySchedule.withLock { schedule in
                try schedule.updateKeys()
            }

            let newOpener = try createOpener(
                from: isClient ? serverKey : clientKey
            )

            // Store as next opener until we confirm the key update
            state.context = KeyPhaseContext(
                currentPhase: currentContext.currentPhase,
                currentOpener: currentContext.currentOpener,
                currentSealer: currentContext.currentSealer,
                previousOpener: currentContext.previousOpener,
                nextOpener: newOpener,
                updateCount: currentContext.updateCount
            )

            return newOpener
        }
    }

    /// Confirms a key update after successfully decrypting with new keys
    ///
    /// After successfully decrypting a packet with the new key phase,
    /// complete the key phase transition.
    ///
    /// - Parameter phase: The key phase that was successfully used
    public func confirmKeyUpdate(phase: UInt8) {
        state.withLock { state in
            guard let currentContext = state.context,
                  phase != currentContext.currentPhase,
                  let nextOpener = currentContext.nextOpener else {
                return
            }

            // Complete the transition
            let newSealer: any PacketSealer
            do {
                let (clientKey, serverKey) = try keySchedule.withLock { schedule in
                    // Keys were already updated in handleReceivedKeyPhase
                    // Get current application keys
                    guard let client = schedule.clientKeyMaterial(for: .application),
                          let server = schedule.serverKeyMaterial(for: .application) else {
                        throw KeyPhaseError.noApplicationKeys
                    }
                    return (client, server)
                }

                newSealer = try createSealer(
                    from: isClient ? clientKey : serverKey
                )
            } catch {
                // Can't complete transition without sealer
                return
            }

            state.context = KeyPhaseContext(
                currentPhase: phase,
                currentOpener: nextOpener,
                currentSealer: newSealer,
                previousOpener: currentContext.currentOpener,
                nextOpener: nil,
                updateCount: currentContext.updateCount + 1
            )

            // RFC 9001 Section 6.1: After receiving a peer-initiated key update,
            // must not initiate another key update until packets with new keys are acknowledged
            state.keyUpdateAllowed = false
            state.lastKeyUpdateTime = .now
        }
    }

    /// Re-enables key updates after previous update is confirmed
    ///
    /// Called when all packets sent with the old key phase have been acknowledged.
    public func enableKeyUpdate() {
        state.withLock { state in
            state.keyUpdateAllowed = true
        }
    }

    /// Whether a key update can be initiated
    public var canInitiateKeyUpdate: Bool {
        state.withLock { $0.keyUpdateAllowed }
    }

    // MARK: - Private Helpers

    private func createOpener(from keys: KeyMaterial) throws -> any PacketOpener {
        try AES128GCMOpener(keyMaterial: keys)
    }

    private func createSealer(from keys: KeyMaterial) throws -> any PacketSealer {
        try AES128GCMSealer(keyMaterial: keys)
    }
}

// MARK: - Key Phase State

/// Internal state for key phase management
private struct KeyPhaseState: Sendable {
    var context: KeyPhaseContext?
    var keyUpdateAllowed: Bool = false
    var lastKeyUpdateTime: ContinuousClock.Instant?
}

// MARK: - Key Phase Errors

/// Errors related to key phase management
public enum KeyPhaseError: Error, Sendable {
    /// No application keys are available
    case noApplicationKeys
    /// Key update is not currently allowed (previous update not confirmed)
    case keyUpdateNotAllowed
    /// Key derivation failed
    case keyDerivationFailed(String)
    /// No opener available for the key phase
    case noOpenerForPhase(UInt8)
}
