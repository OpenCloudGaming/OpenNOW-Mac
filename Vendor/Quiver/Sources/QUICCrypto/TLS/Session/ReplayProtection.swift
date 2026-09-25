/// 0-RTT Replay Protection (RFC 8446 Section 8, RFC 9001 Section 9.2)
///
/// Provides protection against replay attacks for 0-RTT early data.
/// Servers should use this to detect and reject replayed 0-RTT requests.

import Foundation
import Synchronization
import Crypto

// MARK: - Replay Protection

/// Provides replay protection for 0-RTT early data
///
/// RFC 9001 Section 9.2: QUIC is not vulnerable to replay attacks because
/// the server's transport parameters include a random value. However,
/// application-layer protocols may have their own replay concerns.
///
/// This implementation tracks ticket usage to prevent the same session
/// ticket from being used multiple times with 0-RTT data.
public final class ReplayProtection: Sendable {

    private let state = Mutex<ReplayState>(ReplayState())

    private struct ReplayState: Sendable {
        /// Recently seen ticket identifiers with their timestamps
        var seenTickets: [Data: ContinuousClock.Instant] = [:]

        /// Configuration
        var windowDuration: Duration
        var maxEntries: Int

        init(windowDuration: Duration = .seconds(60), maxEntries: Int = 100000) {
            self.windowDuration = windowDuration
            self.maxEntries = maxEntries
        }
    }

    // MARK: - Initialization

    /// Creates a new replay protection instance
    /// - Parameters:
    ///   - windowDuration: How long to track tickets (default 60 seconds)
    ///   - maxEntries: Maximum number of tickets to track (default 100,000)
    public init(windowDuration: Duration = .seconds(60), maxEntries: Int = 100000) {
        state.withLock { s in
            s.windowDuration = windowDuration
            s.maxEntries = maxEntries
        }
    }

    // MARK: - Replay Detection

    /// Checks if 0-RTT early data should be accepted
    ///
    /// Call this when receiving a ClientHello with early data.
    /// If this returns false, reject the 0-RTT data but continue with 1-RTT handshake.
    ///
    /// - Parameters:
    ///   - ticketIdentifier: Unique identifier for the session ticket (e.g., ticket data hash)
    ///   - requestTime: When the request was received (default: now)
    /// - Returns: true if early data should be accepted, false if it's a replay
    public func shouldAcceptEarlyData(
        ticketIdentifier: Data,
        requestTime: ContinuousClock.Instant = .now
    ) -> Bool {
        state.withLock { s in
            // First, clean up old entries
            cleanupExpired(&s, now: requestTime)

            // Check if we've seen this ticket before
            if s.seenTickets[ticketIdentifier] != nil {
                // This is a replay
                return false
            }

            // Record this ticket
            s.seenTickets[ticketIdentifier] = requestTime

            // If we're at max capacity, remove oldest entries
            if s.seenTickets.count > s.maxEntries {
                evictOldest(&s)
            }

            return true
        }
    }

    /// Records a ticket as used (alternative API for manual control)
    /// - Parameter ticketIdentifier: The ticket identifier to record
    public func recordTicketUsed(_ ticketIdentifier: Data) {
        state.withLock { s in
            s.seenTickets[ticketIdentifier] = .now

            // Cleanup if necessary
            if s.seenTickets.count > s.maxEntries {
                cleanupExpired(&s, now: .now)
                evictOldest(&s)
            }
        }
    }

    /// Checks if a ticket has been seen before without recording it
    /// - Parameter ticketIdentifier: The ticket identifier to check
    /// - Returns: true if the ticket has been seen
    public func hasSeenTicket(_ ticketIdentifier: Data) -> Bool {
        state.withLock { s in
            s.seenTickets[ticketIdentifier] != nil
        }
    }

    // MARK: - Cleanup

    /// Cleans up expired entries
    private func cleanupExpired(_ s: inout ReplayState, now: ContinuousClock.Instant) {
        let cutoff = now - s.windowDuration

        s.seenTickets = s.seenTickets.filter { _, timestamp in
            timestamp > cutoff
        }
    }

    /// Evicts oldest entries when at capacity
    private func evictOldest(_ s: inout ReplayState) {
        // Remove oldest 10% of entries
        let toRemove = max(s.maxEntries / 10, 1)
        let sorted = s.seenTickets.sorted { $0.value < $1.value }

        for (key, _) in sorted.prefix(toRemove) {
            s.seenTickets.removeValue(forKey: key)
        }
    }

    /// Manually triggers cleanup of expired entries
    public func purgeExpired() {
        state.withLock { s in
            cleanupExpired(&s, now: .now)
        }
    }

    /// Clears all tracked tickets
    public func clear() {
        state.withLock { s in
            s.seenTickets.removeAll()
        }
    }

    // MARK: - Statistics

    /// Number of tickets currently being tracked
    public var trackedCount: Int {
        state.withLock { $0.seenTickets.count }
    }
}

// MARK: - Ticket Identifier Helper

extension ReplayProtection {
    /// Creates a ticket identifier from ticket data
    ///
    /// Uses SHA-256 hash of the ticket to create a fixed-size identifier.
    ///
    /// - Parameter ticketData: The raw ticket data
    /// - Returns: A 32-byte identifier
    public static func createIdentifier(from ticketData: Data) -> Data {
        Data(SHA256.hash(data: ticketData))
    }

    /// Creates a ticket identifier from a NewSessionTicket
    /// - Parameter ticket: The NewSessionTicket
    /// - Returns: A 32-byte identifier
    public static func createIdentifier(from ticket: NewSessionTicket) -> Data {
        createIdentifier(from: ticket.ticket)
    }
}

// MARK: - 0-RTT Errors

/// Errors related to 0-RTT early data
public enum QUICEarlyDataError: Error, Sendable {
    /// Early data was rejected by the server
    case earlyDataRejected

    /// Replay was detected
    case replayDetected

    /// Invalid frame in 0-RTT packet
    case invalidFrameIn0RTT(String)

    /// Early data size exceeded limit
    case earlyDataTooLarge(maxAllowed: UInt32, attempted: Int)

    /// Session doesn't support early data
    case earlyDataNotSupported

    /// Session has expired
    case sessionExpired
}
