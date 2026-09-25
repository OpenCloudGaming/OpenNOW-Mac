/// Idle Timeout Manager (RFC 9000 Section 10.1)
///
/// Manages idle timeout for QUIC connections:
/// - Calculates effective timeout as min(local, peer) values
/// - Tracks last activity time
/// - Provides keep-alive scheduling
/// - Signals when timeout has occurred

import Foundation
import Synchronization
import QUICCore

// MARK: - Idle Timeout State

/// State of the idle timeout manager
public enum IdleTimeoutState: Sendable {
    /// Connection is active
    case active
    /// Connection timed out
    case timedOut
    /// Connection was closed gracefully
    case closed
}

// MARK: - Idle Timeout Manager

/// Manages idle timeout for a single connection
public final class IdleTimeoutManager: Sendable {

    private let state = Mutex<TimeoutState>(TimeoutState())

    private struct TimeoutState: Sendable {
        /// Last activity time (packet sent or received)
        var lastActivity: ContinuousClock.Instant = .now

        /// Effective idle timeout (min of local and peer)
        var effectiveTimeout: Duration = .seconds(30)

        /// Local max idle timeout from configuration
        var localTimeout: Duration = .seconds(30)

        /// Peer's max idle timeout from transport parameters
        var peerTimeout: Duration?

        /// Current state
        var currentState: IdleTimeoutState = .active

        /// Whether keep-alive is enabled
        var keepAliveEnabled: Bool = false

        /// Keep-alive interval (typically effectiveTimeout / 2)
        var keepAliveInterval: Duration?
    }

    // MARK: - Initialization

    /// Creates an idle timeout manager
    /// - Parameter localTimeout: Local max idle timeout from configuration
    public init(localTimeout: Duration = .seconds(30)) {
        state.withLock { s in
            s.localTimeout = localTimeout
            s.effectiveTimeout = localTimeout
        }
    }

    // MARK: - Configuration

    /// Sets the peer's max idle timeout from transport parameters
    /// - Parameter timeout: Peer's max_idle_timeout in milliseconds (0 means no timeout)
    public func setPeerTimeout(_ timeoutMs: UInt64) {
        state.withLock { s in
            if timeoutMs == 0 {
                // Peer advertises no timeout - use local only
                s.peerTimeout = nil
                s.effectiveTimeout = s.localTimeout
            } else {
                let peerDuration = Duration.milliseconds(Int64(timeoutMs))
                s.peerTimeout = peerDuration

                // Effective timeout is minimum of local and peer
                // If local is 0, it means no timeout from our side
                if s.localTimeout == .zero {
                    s.effectiveTimeout = peerDuration
                } else {
                    s.effectiveTimeout = min(s.localTimeout, peerDuration)
                }
            }

            // Update keep-alive interval
            if s.keepAliveEnabled {
                s.keepAliveInterval = s.effectiveTimeout / 2
            }
        }
    }

    /// Enables keep-alive PINGs
    /// - Parameter enabled: Whether to enable keep-alive
    public func setKeepAlive(enabled: Bool) {
        state.withLock { s in
            s.keepAliveEnabled = enabled
            if enabled {
                s.keepAliveInterval = s.effectiveTimeout / 2
            } else {
                s.keepAliveInterval = nil
            }
        }
    }

    // MARK: - Activity Tracking

    /// Records activity (packet sent or received)
    public func recordActivity() {
        state.withLock { s in
            guard s.currentState == .active else { return }
            s.lastActivity = .now
        }
    }

    /// Marks the connection as closed
    public func markClosed() {
        state.withLock { s in
            s.currentState = .closed
        }
    }

    // MARK: - Timeout Checking

    /// Checks if the connection has timed out
    /// - Returns: true if timed out
    public func checkTimeout() -> Bool {
        return state.withLock { s in
            guard s.currentState == .active else {
                return s.currentState == .timedOut
            }

            // No timeout if effective timeout is 0
            guard s.effectiveTimeout > .zero else {
                return false
            }

            let deadline = s.lastActivity + s.effectiveTimeout
            if ContinuousClock.now >= deadline {
                s.currentState = .timedOut
                return true
            }
            return false
        }
    }

    /// Gets the time until idle timeout
    /// - Returns: Duration until timeout, or nil if already timed out or no timeout configured
    public func timeUntilTimeout() -> Duration? {
        return state.withLock { s in
            guard s.currentState == .active else { return nil }
            guard s.effectiveTimeout > .zero else { return nil }

            let deadline = s.lastActivity + s.effectiveTimeout
            let now = ContinuousClock.now
            if deadline <= now {
                return .zero
            }
            return deadline - now
        }
    }

    /// Gets the time until next keep-alive should be sent
    /// - Returns: Duration until keep-alive needed, or nil if not enabled
    public func timeUntilKeepAlive() -> Duration? {
        return state.withLock { s in
            guard s.currentState == .active else { return nil }
            guard let interval = s.keepAliveInterval else { return nil }

            let keepAliveDeadline = s.lastActivity + interval
            let now = ContinuousClock.now
            if keepAliveDeadline <= now {
                return .zero
            }
            return keepAliveDeadline - now
        }
    }

    /// Checks if a keep-alive PING should be sent
    /// - Returns: true if keep-alive is due
    public func shouldSendKeepAlive() -> Bool {
        return state.withLock { s in
            guard s.currentState == .active else { return false }
            guard let interval = s.keepAliveInterval else { return false }

            let keepAliveDeadline = s.lastActivity + interval
            return ContinuousClock.now >= keepAliveDeadline
        }
    }

    // MARK: - Deadline Computation

    /// Gets the next deadline (timeout or keep-alive)
    /// - Returns: The earliest deadline, or nil if no deadline
    public func nextDeadline() -> ContinuousClock.Instant? {
        return state.withLock { s in
            guard s.currentState == .active else { return nil }

            var deadlines: [ContinuousClock.Instant] = []

            // Timeout deadline
            if s.effectiveTimeout > .zero {
                deadlines.append(s.lastActivity + s.effectiveTimeout)
            }

            // Keep-alive deadline
            if let interval = s.keepAliveInterval {
                deadlines.append(s.lastActivity + interval)
            }

            return deadlines.min()
        }
    }

    // MARK: - Properties

    /// Current state
    public var currentState: IdleTimeoutState {
        state.withLock { $0.currentState }
    }

    /// Effective idle timeout
    public var effectiveTimeout: Duration {
        state.withLock { $0.effectiveTimeout }
    }

    /// Local idle timeout
    public var localTimeout: Duration {
        state.withLock { $0.localTimeout }
    }

    /// Peer's idle timeout (if received)
    public var peerTimeout: Duration? {
        state.withLock { $0.peerTimeout }
    }

    /// Last activity time
    public var lastActivity: ContinuousClock.Instant {
        state.withLock { $0.lastActivity }
    }

    /// Whether keep-alive is enabled
    public var keepAliveEnabled: Bool {
        state.withLock { $0.keepAliveEnabled }
    }
}

// MARK: - Idle Timeout Integration

/// Extension to integrate with transport parameters
extension IdleTimeoutManager {
    /// Updates from received transport parameters
    /// - Parameter params: The peer's transport parameters
    public func updateFromTransportParameters(_ params: TransportParameters) {
        setPeerTimeout(params.maxIdleTimeout)
    }

    /// Creates transport parameters value
    /// - Returns: The max_idle_timeout value to send in milliseconds
    public func maxIdleTimeoutValue() -> UInt64 {
        let timeout = state.withLock { $0.localTimeout }
        let ms = timeout.components.seconds * 1000 + timeout.components.attoseconds / 1_000_000_000_000_000
        return UInt64(ms)
    }
}
