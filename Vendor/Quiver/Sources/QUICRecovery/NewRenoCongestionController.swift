/// QUIC NewReno Congestion Controller (RFC 9002 Section 7)
///
/// Implements the NewReno congestion control algorithm with integrated pacing.
/// This is the default and recommended algorithm for QUIC implementations.
///
/// ## Algorithm Overview
///
/// NewReno operates in three phases:
/// 1. **Slow Start**: Exponential window growth (cwnd += bytes_acked)
/// 2. **Congestion Avoidance**: Linear growth (cwnd += max_datagram_size per RTT)
/// 3. **Recovery**: Window halved, wait for post-recovery ACK
///
/// ## Pacing
///
/// To prevent bursty transmission that can overwhelm network buffers,
/// this implementation includes pacing:
/// - pacing_rate = cwnd / smoothed_rtt
/// - Initial burst tokens allow immediate sending at connection start

import Foundation
import Synchronization

/// NewReno congestion controller with integrated pacing
///
/// Uses `class + Mutex` design for high-frequency updates (per-packet operations).
/// This avoids actor hop overhead while maintaining thread safety.
package final class NewRenoCongestionController: CongestionController, Sendable {

    // MARK: - Internal State

    private let state: Mutex<CCState>

    /// Internal state protected by Mutex
    private struct CCState: Sendable {
        // RFC 9002 Section 7.1 State Variables
        var congestionWindow: Int
        var ssthresh: Int
        var recoveryStartTime: ContinuousClock.Instant?
        var bytesAcked: Int

        // Pacing State
        var nextSendTime: ContinuousClock.Instant
        var pacingRate: Double  // bytes per nanosecond
        var burstTokens: Int

        // Configuration (immutable after init)
        let maxDatagramSize: Int
        let minimumWindow: Int
    }

    // MARK: - Initialization

    /// Creates a new NewReno congestion controller
    ///
    /// - Parameter maxDatagramSize: Maximum datagram size in bytes.
    ///   Defaults to `LossDetectionConstants.defaultMaxDatagramSize` (1200).
    ///   At runtime, prefer passing the configured value from
    ///   `QUICConfiguration.maxUDPPayloadSize`.
    package init(maxDatagramSize: Int = LossDetectionConstants.defaultMaxDatagramSize) {
        let minimumWindow = 2 * maxDatagramSize
        // RFC 9002 Section 7.2: Initial window calculation
        let initialWindow = min(
            10 * maxDatagramSize,
            max(14720, 2 * maxDatagramSize)
        )

        self.state = Mutex(CCState(
            congestionWindow: initialWindow,
            ssthresh: Int.max,
            recoveryStartTime: nil,
            bytesAcked: 0,
            nextSendTime: .now,
            pacingRate: 0,
            burstTokens: LossDetectionConstants.initialBurstTokens,
            maxDatagramSize: maxDatagramSize,
            minimumWindow: minimumWindow
        ))
    }

    // MARK: - CongestionController Protocol

    package var congestionWindow: Int {
        state.withLock { $0.congestionWindow }
    }

    package var currentState: CongestionState {
        state.withLock { s in
            if let recoveryStart = s.recoveryStartTime {
                return .recovery(startTime: recoveryStart)
            } else if s.congestionWindow < s.ssthresh {
                return .slowStart
            } else {
                return .congestionAvoidance
            }
        }
    }

    package func availableWindow(bytesInFlight: Int) -> Int {
        state.withLock { s in
            max(0, s.congestionWindow - bytesInFlight)
        }
    }

    // MARK: - Pacing

    package func nextSendTime() -> ContinuousClock.Instant? {
        state.withLock { s in
            // Burst tokens allow immediate sending at connection start
            if s.burstTokens > 0 {
                return nil
            }
            // If pacing rate is not yet established, allow immediate sending
            if s.pacingRate <= 0 {
                return nil
            }
            return s.nextSendTime
        }
    }

    // MARK: - Event Handlers

    package func onPacketSent(bytes: Int, now: ContinuousClock.Instant) {
        state.withLock { s in
            if s.burstTokens > 0 {
                s.burstTokens -= 1
            } else if s.pacingRate > 0 {
                // Calculate next send time based on pacing rate
                // interval = bytes / pacingRate (in nanoseconds)
                let intervalNanos = Double(bytes) / s.pacingRate
                let nanos = Int64(intervalNanos)
                s.nextSendTime = now + .nanoseconds(nanos)
            }
        }
    }

    package func onPacketsAcknowledged(
        packets: [SentPacket],
        now: ContinuousClock.Instant,
        rtt: RTTEstimator
    ) {
        state.withLock { s in
            for packet in packets {
                // Only in-flight packets affect congestion control
                guard packet.inFlight else { continue }

                // During recovery: only count packets sent AFTER recovery started
                if let recoveryStart = s.recoveryStartTime {
                    if packet.timeSent <= recoveryStart {
                        // Ignore ACKs of packets sent before recovery
                        // (already accounted for in the congestion event)
                        continue
                    }
                    // A packet sent during recovery was acknowledged
                    // Exit recovery and resume congestion avoidance
                    s.recoveryStartTime = nil
                }

                // Window growth based on current phase
                if s.congestionWindow < s.ssthresh {
                    // Slow Start: exponential growth
                    // cwnd += bytes_acked
                    s.congestionWindow += packet.sentBytes
                } else {
                    // Congestion Avoidance: linear growth (AIMD)
                    // Increase cwnd by max_datagram_size when
                    // accumulated acked bytes >= cwnd
                    s.bytesAcked += packet.sentBytes
                    if s.bytesAcked >= s.congestionWindow {
                        s.congestionWindow += s.maxDatagramSize
                        s.bytesAcked = 0
                    }
                }
            }

            // Update pacing rate based on new window and RTT
            updatePacingRate(&s, rtt: rtt)
        }
    }

    package func onPacketsLost(
        packets: [SentPacket],
        now: ContinuousClock.Instant,
        rtt: RTTEstimator
    ) {
        guard !packets.isEmpty else { return }

        state.withLock { s in
            // RFC 9002 Section 7.3.2: Only one window reduction per RTT
            // If already in recovery, don't reduce again
            if s.recoveryStartTime != nil {
                return
            }

            // Enter recovery: reduce window by half
            enterRecovery(&s, now: now)

            // Update pacing rate for reduced window
            updatePacingRate(&s, rtt: rtt)
        }
    }

    package func onECNCongestionEvent(now: ContinuousClock.Instant) {
        state.withLock { s in
            // ECN-CE is treated the same as packet loss
            if s.recoveryStartTime != nil {
                return
            }
            enterRecovery(&s, now: now)
        }
    }

    package func onPersistentCongestion() {
        state.withLock { s in
            // RFC 9002 Section 7.6.2: Persistent Congestion
            //
            // Persistent congestion is declared when packets spanning a period
            // greater than (2 * PTO * kPersistentCongestionThreshold) are all lost.
            // This indicates a fundamental change in network conditions.
            //
            // Response (more severe than normal loss):
            // - Collapse cwnd to minimum (2 * max_datagram_size)
            // - Reset ssthresh to infinity (re-enter slow start)
            // - Clear recovery state (not in recovery after this)
            // - Reset pacing (will be re-established with new RTT samples)
            //
            // This is similar to TCP's RTO response, treating the network
            // as if it were a completely new path.
            s.congestionWindow = s.minimumWindow
            s.ssthresh = Int.max
            s.bytesAcked = 0
            s.recoveryStartTime = nil
            s.burstTokens = LossDetectionConstants.initialBurstTokens
            s.pacingRate = 0
        }
    }

    // MARK: - Private Helpers

    /// Enters recovery state and reduces congestion window
    private func enterRecovery(_ s: inout CCState, now: ContinuousClock.Instant) {
        s.recoveryStartTime = now

        // RFC 9002 Section 7.3.2: Reduce window by loss reduction factor (0.5)
        let reducedWindow = Int(Double(s.congestionWindow) * LossDetectionConstants.lossReductionFactor)
        s.ssthresh = max(reducedWindow, s.minimumWindow)
        s.congestionWindow = s.ssthresh
        s.bytesAcked = 0
    }

    /// Updates pacing rate based on current cwnd and RTT
    private func updatePacingRate(_ s: inout CCState, rtt: RTTEstimator) {
        guard rtt.hasEstimate else { return }

        // pacing_rate = cwnd / smoothed_rtt (in bytes per nanosecond)
        let smoothedNanos = rtt.smoothedRTT.components.seconds * 1_000_000_000 +
                            rtt.smoothedRTT.components.attoseconds / 1_000_000_000

        if smoothedNanos > 0 {
            s.pacingRate = Double(s.congestionWindow) / Double(smoothedNanos)
        }
    }
}

// MARK: - Debug Support

extension NewRenoCongestionController: CustomStringConvertible {

    package var description: String {
        state.withLock { s in
            let stateStr: String
            if s.recoveryStartTime != nil {
                stateStr = "recovery"
            } else if s.congestionWindow < s.ssthresh {
                stateStr = "slow_start"
            } else {
                stateStr = "congestion_avoidance"
            }

            return "NewReno(cwnd=\(s.congestionWindow), ssthresh=\(s.ssthresh), state=\(stateStr))"
        }
    }
}
