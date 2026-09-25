/// Pacing (RFC 9002 Section 7.7)
///
/// Pacing spreads packet transmission over time to avoid bursts
/// that can cause network congestion and packet loss.
///
/// Uses a token bucket algorithm where tokens accumulate at the
/// pacing rate and are consumed when sending packets.

import Foundation
import Synchronization

// MARK: - Pacing Configuration

/// Configuration for packet pacing
public struct PacingConfiguration: Sendable {
    /// Initial pacing rate in bytes per second (0 = disabled)
    public var initialRate: UInt64

    /// Maximum burst size in bytes
    public var maxBurst: UInt64

    /// Minimum pacing interval
    public var minInterval: Duration

    /// Creates default pacing configuration
    public init() {
        // Start with 10 Mbps = 1.25 MB/s
        self.initialRate = 1_250_000
        // Allow bursts of up to 10 packets (~15KB)
        self.maxBurst = 15_000
        // Minimum 1ms between bursts
        self.minInterval = .milliseconds(1)
    }

    /// Creates custom pacing configuration
    public init(initialRate: UInt64, maxBurst: UInt64, minInterval: Duration) {
        self.initialRate = initialRate
        self.maxBurst = maxBurst
        self.minInterval = minInterval
    }

    /// Pacing disabled (no rate limiting)
    public static let disabled = PacingConfiguration(
        initialRate: 0,
        maxBurst: .max,
        minInterval: .zero
    )
}

// MARK: - Pacer

/// Token bucket pacer for rate-limited packet transmission
///
/// ## Usage
/// ```swift
/// let pacer = Pacer()
///
/// // Before sending a packet
/// if let delay = pacer.packetDelay(bytes: packetSize) {
///     try await Task.sleep(for: delay)
/// }
///
/// // After congestion feedback
/// pacer.updateRate(bytesPerSecond: newRate)
/// ```
public final class Pacer: Sendable {
    private let state: Mutex<PacerState>

    private struct PacerState: Sendable {
        /// Current pacing rate in bytes per second
        var rate: UInt64

        /// Available token bucket capacity in bytes
        var tokens: UInt64

        /// Maximum burst size in bytes
        var maxBurst: UInt64

        /// Last time tokens were updated
        var lastUpdate: ContinuousClock.Instant

        /// Minimum pacing interval
        var minInterval: Duration

        /// Whether pacing is enabled
        var isEnabled: Bool
    }

    // MARK: - Initialization

    /// Creates a new pacer
    /// - Parameter config: Pacing configuration
    public init(config: PacingConfiguration = PacingConfiguration()) {
        let now = ContinuousClock.now
        self.state = Mutex(PacerState(
            rate: config.initialRate,
            tokens: config.maxBurst,
            maxBurst: config.maxBurst,
            lastUpdate: now,
            minInterval: config.minInterval,
            isEnabled: config.initialRate > 0
        ))
    }

    // MARK: - Rate Control

    /// Updates the pacing rate
    ///
    /// Call this when congestion control adjusts the sending rate.
    ///
    /// - Parameter bytesPerSecond: New pacing rate (0 to disable)
    public func updateRate(bytesPerSecond: UInt64) {
        state.withLock { s in
            s.rate = bytesPerSecond
            s.isEnabled = bytesPerSecond > 0
        }
    }

    /// Updates the maximum burst size
    ///
    /// - Parameter bytes: Maximum burst size in bytes
    public func updateMaxBurst(bytes: UInt64) {
        state.withLock { s in
            s.maxBurst = bytes
            if s.tokens > bytes {
                s.tokens = bytes
            }
        }
    }

    // MARK: - Packet Scheduling

    /// Calculates delay before sending a packet
    ///
    /// This method:
    /// 1. Adds tokens based on elapsed time since last call
    /// 2. Checks if enough tokens are available
    /// 3. Returns delay needed if tokens are insufficient
    ///
    /// - Parameter bytes: Size of packet to send
    /// - Returns: Delay to wait, or nil if packet can be sent immediately
    public func packetDelay(bytes: UInt64) -> Duration? {
        state.withLock { s in
            guard s.isEnabled else { return nil }

            let now = ContinuousClock.now
            replenishTokens(&s, now: now)

            // Check if we have enough tokens
            if s.tokens >= bytes {
                s.tokens -= bytes
                return nil  // Can send immediately
            }

            // Calculate time to wait for tokens
            let tokensNeeded = bytes - s.tokens
            let secondsToWait = Double(tokensNeeded) / Double(s.rate)
            let delay = Duration.seconds(secondsToWait)

            // Enforce minimum interval
            if delay < s.minInterval {
                return s.minInterval
            }

            return delay
        }
    }

    /// Consumes tokens for a packet being sent
    ///
    /// Call this after sending a packet to account for the bytes.
    /// Use this when you need to track bytes separately from delay calculation.
    ///
    /// - Parameter bytes: Number of bytes sent
    public func consume(bytes: UInt64) {
        state.withLock { s in
            guard s.isEnabled else { return }

            let now = ContinuousClock.now
            replenishTokens(&s, now: now)

            if s.tokens >= bytes {
                s.tokens -= bytes
            } else {
                s.tokens = 0
            }
        }
    }

    /// Replenishes tokens based on elapsed time
    private func replenishTokens(_ s: inout PacerState, now: ContinuousClock.Instant) {
        let elapsed = now - s.lastUpdate
        let elapsedSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let newTokens = UInt64(max(0, elapsedSeconds * Double(s.rate)))

        s.tokens = min(s.tokens + newTokens, s.maxBurst)
        s.lastUpdate = now
    }

    // MARK: - State Queries

    /// Whether pacing is enabled
    public var isEnabled: Bool {
        state.withLock { $0.isEnabled }
    }

    /// Current pacing rate in bytes per second
    public var rate: UInt64 {
        state.withLock { $0.rate }
    }

    /// Available tokens (bytes that can be sent immediately)
    public var availableTokens: UInt64 {
        state.withLock { s in
            replenishTokens(&s, now: .now)
            return s.tokens
        }
    }

    /// Time until the next packet can be sent
    ///
    /// - Parameter bytes: Size of packet to send
    /// - Returns: Duration until packet can be sent, or zero if immediate
    public func timeUntilSend(bytes: UInt64) -> Duration {
        packetDelay(bytes: bytes) ?? .zero
    }
}

// MARK: - Congestion Control Integration

extension Pacer {
    /// Updates pacing rate from congestion window and RTT
    ///
    /// RFC 9002 Section 7.7: N * congestion_window / smoothed_rtt
    ///
    /// - Parameters:
    ///   - congestionWindow: Current congestion window in bytes
    ///   - smoothedRTT: Smoothed round-trip time
    ///   - pacingGain: Pacing gain multiplier (typically 1.25 for BBR)
    public func updateFromCongestion(
        congestionWindow: UInt64,
        smoothedRTT: Duration,
        pacingGain: Double = 1.25
    ) {
        let rttSeconds = Double(smoothedRTT.components.seconds) +
                        Double(smoothedRTT.components.attoseconds) / 1e18

        guard rttSeconds > 0 else { return }

        let rate = UInt64(pacingGain * Double(congestionWindow) / rttSeconds)
        updateRate(bytesPerSecond: rate)
    }
}
