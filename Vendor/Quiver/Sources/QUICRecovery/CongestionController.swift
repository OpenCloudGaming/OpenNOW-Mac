/// QUIC Congestion Control (RFC 9002 Section 7)
///
/// Provides the protocol abstraction for congestion control algorithms.
/// Implementations include NewReno (default) with optional CUBIC/BBR support.

import Foundation

// MARK: - Congestion State

/// The current state of the congestion controller
package enum CongestionState: Sendable, Equatable {
    /// Slow start phase: exponential window growth
    /// Active when cwnd < ssthresh
    case slowStart

    /// Congestion avoidance phase: linear window growth (AIMD)
    /// Active when cwnd >= ssthresh and not in recovery
    case congestionAvoidance

    /// Recovery phase: entered upon loss or ECN-CE detection
    /// Window is halved, and we wait for a post-recovery packet to be acknowledged
    case recovery(startTime: ContinuousClock.Instant)

    package static func == (lhs: CongestionState, rhs: CongestionState) -> Bool {
        switch (lhs, rhs) {
        case (.slowStart, .slowStart):
            return true
        case (.congestionAvoidance, .congestionAvoidance):
            return true
        case (.recovery, .recovery):
            return true
        default:
            return false
        }
    }
}

// MARK: - Congestion Controller Protocol

/// Protocol for QUIC congestion control algorithms (RFC 9002 Section 7)
///
/// Implementations must be thread-safe (`Sendable`) as they may be accessed
/// from multiple contexts during packet processing.
///
/// The controller manages:
/// - Congestion window (cwnd) sizing
/// - Slow start threshold (ssthresh)
/// - Recovery period tracking
/// - Pacing for smooth traffic transmission
package protocol CongestionController: Sendable {

    // MARK: - State Queries

    /// Current congestion window in bytes
    ///
    /// This is the maximum number of bytes that can be in flight
    /// (sent but not yet acknowledged).
    var congestionWindow: Int { get }

    /// Current congestion control state
    var currentState: CongestionState { get }

    /// Available window for sending
    ///
    /// Returns the number of additional bytes that can be sent
    /// given the current bytes in flight.
    ///
    /// - Parameter bytesInFlight: Current bytes in flight (unacknowledged)
    /// - Returns: Number of bytes available to send
    func availableWindow(bytesInFlight: Int) -> Int

    // MARK: - Pacing

    /// Next time a packet can be sent (for pacing)
    ///
    /// Returns `nil` if a packet can be sent immediately (e.g., burst tokens available).
    /// Returns a future time if pacing requires waiting.
    ///
    /// - Returns: The earliest time to send the next packet, or nil if immediate
    func nextSendTime() -> ContinuousClock.Instant?

    // MARK: - Event Handlers

    /// Called when a packet is sent
    ///
    /// Updates pacing state and any other per-packet tracking.
    ///
    /// - Parameters:
    ///   - bytes: Size of the packet in bytes
    ///   - now: Current time
    func onPacketSent(bytes: Int, now: ContinuousClock.Instant)

    /// Called when packets are acknowledged
    ///
    /// This is where slow start and congestion avoidance window growth occurs.
    /// Only in-flight packets should affect the congestion window.
    ///
    /// - Parameters:
    ///   - packets: The acknowledged packets
    ///   - now: Current time
    ///   - rtt: Current RTT estimates
    func onPacketsAcknowledged(
        packets: [SentPacket],
        now: ContinuousClock.Instant,
        rtt: RTTEstimator
    )

    /// Called when packets are detected as lost
    ///
    /// This triggers entry into the recovery state and window reduction.
    /// Multiple losses in the same RTT should only cause one reduction.
    ///
    /// - Parameters:
    ///   - packets: The lost packets
    ///   - now: Current time
    ///   - rtt: Current RTT estimates
    func onPacketsLost(
        packets: [SentPacket],
        now: ContinuousClock.Instant,
        rtt: RTTEstimator
    )

    /// Called when ECN Congestion Experienced (ECN-CE) is detected
    ///
    /// Treated similarly to packet loss: triggers recovery and window reduction.
    ///
    /// - Parameter now: Current time
    func onECNCongestionEvent(now: ContinuousClock.Instant)

    /// Called when persistent congestion is detected
    ///
    /// RFC 9002 Section 7.6.2: Persistent congestion indicates that
    /// the network path has fundamentally changed, similar to an RTO in TCP.
    ///
    /// Required response:
    /// - Collapse congestion window to minimum (2 * max_datagram_size)
    /// - Reset slow start threshold to infinity (re-enter slow start)
    /// - Clear any recovery state
    ///
    /// This is more severe than normal packet loss (`onPacketsLost`), which
    /// only halves the window and enters recovery. Persistent congestion
    /// essentially treats the network as a completely new path.
    ///
    /// - Important: The caller decides whether to call `onPacketsLost` or
    ///   `onPersistentCongestion`. They should not both be called for the
    ///   same loss event, as persistent congestion subsumes normal loss handling.
    func onPersistentCongestion()
}

// MARK: - Default Implementations

extension CongestionController {

    /// Default implementation of available window calculation
    package func availableWindow(bytesInFlight: Int) -> Int {
        max(0, congestionWindow - bytesInFlight)
    }
}

// MARK: - Congestion Controller Factory

/// Factory protocol for creating congestion control algorithm instances.
///
/// Implement this protocol to provide custom congestion control algorithms
/// (e.g., CUBIC, BBR) that can be injected into QUIC connections via
/// `QUICConfiguration.congestionControllerFactory`.
///
/// ## Example
///
/// ```swift
/// struct BBRFactory: CongestionControllerFactory {
///     func makeCongestionController(maxDatagramSize: Int) -> any CongestionController {
///         BBRCongestionController(maxDatagramSize: maxDatagramSize)
///     }
/// }
/// ```
package protocol CongestionControllerFactory: Sendable {
    /// Creates a new congestion controller instance.
    ///
    /// Called once per connection to create the congestion controller
    /// that will manage that connection's sending rate.
    ///
    /// - Parameter maxDatagramSize: Maximum datagram size in bytes.
    ///   Supplied by `QUICConfiguration.maxUDPPayloadSize` at connection
    ///   creation time (defaults to `ProtocolLimits.minimumMaximumDatagramSize`).
    /// - Returns: A configured congestion controller
    func makeCongestionController(maxDatagramSize: Int) -> any CongestionController
}

// MARK: - NewReno Factory (Default)

/// Default factory that creates `NewRenoCongestionController` instances.
///
/// This is the factory used when no custom congestion control algorithm
/// is configured. NewReno is the recommended default per RFC 9002.
package struct NewRenoFactory: CongestionControllerFactory {
    package init() {}

    package func makeCongestionController(maxDatagramSize: Int) -> any CongestionController {
        NewRenoCongestionController(maxDatagramSize: maxDatagramSize)
    }
}
