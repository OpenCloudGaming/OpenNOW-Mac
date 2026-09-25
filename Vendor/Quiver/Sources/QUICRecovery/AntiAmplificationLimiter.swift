/// Anti-Amplification Limit (RFC 9000 Section 8.1)
///
/// Before address validation is complete, an endpoint MUST NOT send
/// more than three times the number of bytes received, to prevent
/// amplification attacks.
///
/// This limit applies only to servers during the handshake:
/// - Servers must limit response size until client address is validated
/// - Clients are not subject to this limit (they initiate the connection)
/// - The limit is lifted once the handshake is confirmed
///
/// ## Usage
///
/// ```swift
/// let limiter = AntiAmplificationLimiter(isServer: true)
///
/// // When receiving data
/// limiter.recordBytesReceived(1200)
///
/// // Before sending, check if allowed
/// if limiter.canSend(bytes: 1200) {
///     // Send the packet
///     limiter.recordBytesSent(1200)
/// }
///
/// // After handshake completion
/// limiter.confirmHandshake()
/// ```

import Foundation
import Synchronization

/// Manages the anti-amplification limit for QUIC connections
///
/// RFC 9000 Section 8.1: Address Validation during Connection Establishment
public final class AntiAmplificationLimiter: Sendable {

    private let state: Mutex<LimiterState>

    private struct LimiterState: Sendable {
        /// Total bytes received from peer
        var bytesReceived: UInt64 = 0

        /// Total bytes sent to peer
        var bytesSent: UInt64 = 0

        /// Amplification factor (RFC 9000 specifies 3)
        let amplificationFactor: UInt64 = 3

        /// Whether address validation is complete
        var addressValidated: Bool = false

        /// Whether this endpoint is a server (only servers are limited)
        let isServer: Bool

        /// Maximum bytes allowed to send based on received bytes
        /// Uses saturating multiplication to prevent overflow (RFC 9000 Section 8.1 compliance)
        var sendLimit: UInt64 {
            let (result, overflow) = bytesReceived.multipliedReportingOverflow(by: amplificationFactor)
            return overflow ? UInt64.max : result
        }

        /// Remaining bytes that can be sent
        var remainingAllowance: UInt64 {
            guard sendLimit > bytesSent else { return 0 }
            return sendLimit - bytesSent
        }
    }

    // MARK: - Initialization

    /// Creates an anti-amplification limiter
    ///
    /// - Parameter isServer: Whether this endpoint is a server.
    ///   Only servers are subject to the amplification limit.
    public init(isServer: Bool) {
        self.state = Mutex(LimiterState(isServer: isServer))
    }

    // MARK: - Byte Tracking

    /// Records bytes received from the peer
    ///
    /// This increases the allowance for sending data back.
    ///
    /// - Parameter bytes: Number of bytes received
    public func recordBytesReceived(_ bytes: UInt64) {
        state.withLock { s in
            // Saturating addition to prevent overflow
            let (result, overflow) = s.bytesReceived.addingReportingOverflow(bytes)
            s.bytesReceived = overflow ? UInt64.max : result
        }
    }

    /// Records bytes sent to the peer
    ///
    /// - Parameter bytes: Number of bytes sent
    public func recordBytesSent(_ bytes: UInt64) {
        state.withLock { s in
            // Saturating addition to prevent overflow
            let (result, overflow) = s.bytesSent.addingReportingOverflow(bytes)
            s.bytesSent = overflow ? UInt64.max : result
        }
    }

    // MARK: - Limit Checking

    /// Checks if sending the specified number of bytes is allowed
    ///
    /// - Parameter bytes: Number of bytes to send
    /// - Returns: `true` if sending is allowed
    public func canSend(bytes: UInt64) -> Bool {
        state.withLock { s in
            // Clients are not subject to amplification limit
            guard s.isServer else { return true }

            // Once address is validated, no limit applies
            guard !s.addressValidated else { return true }

            // Check if within the amplification limit (with overflow protection)
            let (total, overflow) = s.bytesSent.addingReportingOverflow(bytes)
            if overflow { return false }
            return total <= s.sendLimit
        }
    }

    /// Gets the maximum bytes that can be sent right now
    ///
    /// - Returns: Maximum bytes allowed, or `UInt64.max` if unlimited
    public func availableSendWindow() -> UInt64 {
        state.withLock { s in
            // Clients are not limited
            guard s.isServer else { return UInt64.max }

            // Once validated, no limit
            guard !s.addressValidated else { return UInt64.max }

            return s.remainingAllowance
        }
    }

    /// Whether the endpoint is currently blocked by the amplification limit
    ///
    /// This can happen when:
    /// - Server hasn't received enough data from client
    /// - Server has sent 3x the received amount
    ///
    /// When blocked, the server must wait for more data from the client
    /// to be able to send more.
    public var isBlocked: Bool {
        state.withLock { s in
            guard s.isServer && !s.addressValidated else { return false }
            return s.remainingAllowance == 0
        }
    }

    // MARK: - Address Validation

    /// Marks the address as validated, lifting the amplification limit
    ///
    /// This should be called when:
    /// - Server receives Handshake packet (client address validated)
    /// - Or when handshake is confirmed
    public func validateAddress() {
        state.withLock { s in
            s.addressValidated = true
        }
    }

    /// Marks the handshake as confirmed, lifting the amplification limit
    ///
    /// RFC 9001: Once the handshake is confirmed, address validation is complete.
    public func confirmHandshake() {
        validateAddress()
    }

    /// Whether the address has been validated
    public var isAddressValidated: Bool {
        state.withLock { $0.addressValidated }
    }

    // MARK: - Statistics

    /// Total bytes received from peer
    public var bytesReceived: UInt64 {
        state.withLock { $0.bytesReceived }
    }

    /// Total bytes sent to peer
    public var bytesSent: UInt64 {
        state.withLock { $0.bytesSent }
    }

    /// Current send limit (3x received bytes)
    public var sendLimit: UInt64 {
        state.withLock { s in
            s.addressValidated ? UInt64.max : s.sendLimit
        }
    }
}

// MARK: - Debug Support

extension AntiAmplificationLimiter: CustomStringConvertible {
    public var description: String {
        state.withLock { s in
            if !s.isServer {
                return "AntiAmplificationLimiter(client, unlimited)"
            }
            if s.addressValidated {
                return "AntiAmplificationLimiter(server, validated, unlimited)"
            }
            return "AntiAmplificationLimiter(server, received=\(s.bytesReceived), sent=\(s.bytesSent), limit=\(s.sendLimit))"
        }
    }
}
