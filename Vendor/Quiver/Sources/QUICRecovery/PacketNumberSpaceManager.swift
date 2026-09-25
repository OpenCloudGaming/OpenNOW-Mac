/// Packet Number Space Manager
///
/// Coordinates loss detection and ACK management across all encryption levels.

import Foundation
import Synchronization
import QUICCore

// MARK: - PTO Action

/// Action to take when PTO (Probe Timeout) expires
///
/// RFC 9002 Section 6.2: When a PTO expires, the sender MUST send
/// one or two probe datagrams. This struct describes what action
/// to take.
package struct PTOAction: Sendable, Equatable {
    /// The encryption level at which to send the probe
    package let level: EncryptionLevel

    /// Number of probe packets to send (1 or 2)
    ///
    /// RFC 9002 Section 6.2.4: It is RECOMMENDED that implementations
    /// send two probe datagrams to improve detection of packet loss.
    package let probeCount: Int

    /// Packets that can be retransmitted as probes (if any)
    ///
    /// If empty, the sender should send a PING frame.
    package let packetsToProbe: [SentPacket]

    /// Creates a PTO action
    package init(
        level: EncryptionLevel,
        probeCount: Int = 2,
        packetsToProbe: [SentPacket] = []
    ) {
        self.level = level
        self.probeCount = probeCount
        self.packetsToProbe = packetsToProbe
    }

    package static func == (lhs: PTOAction, rhs: PTOAction) -> Bool {
        lhs.level == rhs.level &&
        lhs.probeCount == rhs.probeCount &&
        lhs.packetsToProbe.count == rhs.packetsToProbe.count
    }
}

/// Manages loss detection and ACK state for all packet number spaces
package final class PacketNumberSpaceManager: Sendable {
    /// Loss detectors per encryption level (packet number space)
    package let lossDetectors: [EncryptionLevel: LossDetector]

    /// ACK managers per encryption level
    package let ackManagers: [EncryptionLevel: AckManager]

    /// RTT estimator (shared across all spaces)
    private let _rttEstimator: Mutex<RTTEstimator>

    /// PTO count (consecutive probe timeouts)
    private let _ptoCount: Mutex<Int>

    /// Whether handshake is confirmed
    private let _handshakeConfirmed: Mutex<Bool>

    /// Peer's max_ack_delay transport parameter
    ///
    /// RFC 9002 Section 5.3: This value is used to cap the ack_delay field
    /// when calculating RTT samples, and for PTO/persistent congestion calculation.
    ///
    /// Default: 25ms (RFC 9000 Section 18.2)
    /// Set this when peer's transport parameters are received.
    private let _peerMaxAckDelay: Mutex<Duration>

    /// Creates a new PacketNumberSpaceManager
    /// - Parameter maxAckDelay: Maximum ACK delay for ACK generation
    package init(maxAckDelay: Duration = LossDetectionConstants.defaultMaxAckDelay) {
        var detectors: [EncryptionLevel: LossDetector] = [:]
        var acks: [EncryptionLevel: AckManager] = [:]

        // Create managers for each packet number space
        // Note: Initial and 0-RTT share the same packet number space in loss detection
        // but we track them separately for simplicity
        for level in [EncryptionLevel.initial, .handshake, .application] {
            detectors[level] = LossDetector()
            acks[level] = AckManager(maxAckDelay: maxAckDelay)
        }

        self.lossDetectors = detectors
        self.ackManagers = acks
        self._rttEstimator = Mutex(RTTEstimator())
        self._ptoCount = Mutex(0)
        self._handshakeConfirmed = Mutex(false)
        self._peerMaxAckDelay = Mutex(LossDetectionConstants.defaultMaxAckDelay)
    }

    /// Gets the current RTT estimator state
    package var rttEstimator: RTTEstimator {
        _rttEstimator.withLock { $0 }
    }

    /// Gets the current PTO count
    package var ptoCount: Int {
        _ptoCount.withLock { $0 }
    }

    /// Whether handshake is confirmed
    package var handshakeConfirmed: Bool {
        get { _handshakeConfirmed.withLock { $0 } }
        set { _handshakeConfirmed.withLock { $0 = newValue } }
    }

    /// Peer's max_ack_delay transport parameter
    ///
    /// Set this when peer's transport parameters are received during handshake.
    /// Before handshake completion, the default value (25ms) is used.
    package var peerMaxAckDelay: Duration {
        get { _peerMaxAckDelay.withLock { $0 } }
        set { _peerMaxAckDelay.withLock { $0 = newValue } }
    }

    /// Effective max_ack_delay considering handshake state
    ///
    /// RFC 9002 Section 5.3: Before the handshake is confirmed, an endpoint
    /// might not have received the peer's max_ack_delay value. In this case,
    /// max_ack_delay should be treated as 0.
    private var effectiveMaxAckDelay: Duration {
        handshakeConfirmed ? peerMaxAckDelay : .zero
    }

    /// Updates RTT from a new sample
    ///
    /// Uses the internally managed `peerMaxAckDelay` value.
    ///
    /// - Parameters:
    ///   - sample: The RTT sample
    ///   - ackDelay: The ack delay reported by peer in the ACK frame
    package func updateRTT(
        sample: Duration,
        ackDelay: Duration
    ) {
        let confirmed = handshakeConfirmed
        let maxDelay = peerMaxAckDelay
        _rttEstimator.withLock { estimator in
            estimator.updateRTT(
                rttSample: sample,
                ackDelay: ackDelay,
                maxAckDelay: maxDelay,
                handshakeConfirmed: confirmed
            )
        }
    }

    /// Discards an encryption level (called after handshake completion)
    /// - Parameter level: The encryption level to discard
    package func discardLevel(_ level: EncryptionLevel) {
        lossDetectors[level]?.clear()
        ackManagers[level]?.clear()
    }

    /// Calculates the next PTO deadline
    ///
    /// Uses the internally managed `peerMaxAckDelay` value.
    ///
    /// - Parameter now: Current time
    /// - Returns: The PTO deadline
    package func nextPTODeadline(now: ContinuousClock.Instant) -> ContinuousClock.Instant {
        let maxDelay = effectiveMaxAckDelay

        let pto = _rttEstimator.withLock { rtt in
            rtt.probeTimeout(maxAckDelay: maxDelay)
        }

        let ptoMultiplier = _ptoCount.withLock { 1 << $0 }  // 2^pto_count
        return now + (pto * ptoMultiplier)
    }

    /// Increments PTO count on timeout
    package func onPTOExpired() {
        _ptoCount.withLock { $0 += 1 }
    }

    /// Resets PTO count on successful ACK
    package func resetPTOCount() {
        _ptoCount.withLock { $0 = 0 }
    }

    /// Gets the earliest loss time across all levels
    /// - Returns: The earliest loss time, or nil if none
    package func earliestLossTime() -> (level: EncryptionLevel, time: ContinuousClock.Instant)? {
        var earliest: (level: EncryptionLevel, time: ContinuousClock.Instant)? = nil

        for level in [EncryptionLevel.initial, .handshake, .application] {
            if let lossTime = lossDetectors[level]?.earliestLossTime() {
                if earliest == nil || lossTime < earliest!.time {
                    earliest = (level, lossTime)
                }
            }
        }

        return earliest
    }

    /// Gets the earliest ACK time across all levels
    /// - Returns: The earliest ACK time, or nil if none
    package func earliestAckTime() -> (level: EncryptionLevel, time: ContinuousClock.Instant)? {
        var earliest: (level: EncryptionLevel, time: ContinuousClock.Instant)? = nil

        for level in [EncryptionLevel.initial, .handshake, .application] {
            if let ackTime = ackManagers[level]?.nextAckTime() {
                if earliest == nil || ackTime < earliest!.time {
                    earliest = (level, ackTime)
                }
            }
        }

        return earliest
    }

    /// Whether any level has ack-eliciting packets in flight
    package var hasAckElicitingInFlight: Bool {
        for level in [EncryptionLevel.initial, .handshake, .application] {
            if let detector = lossDetectors[level], detector.ackElicitingInFlight > 0 {
                return true
            }
        }
        return false
    }

    /// Total bytes in flight across all levels
    package var totalBytesInFlight: Int {
        var total = 0
        for level in [EncryptionLevel.initial, .handshake, .application] {
            total += lossDetectors[level]?.bytesInFlight ?? 0
        }
        return total
    }

    /// Records a sent packet
    /// - Parameter packet: The sent packet
    package func onPacketSent(_ packet: SentPacket) {
        lossDetectors[packet.encryptionLevel]?.onPacketSent(packet)
    }

    /// Records a received packet
    /// - Parameters:
    ///   - packetNumber: The packet number
    ///   - level: The encryption level
    ///   - isAckEliciting: Whether the packet is ack-eliciting
    ///   - receiveTime: When the packet was received
    package func onPacketReceived(
        packetNumber: UInt64,
        level: EncryptionLevel,
        isAckEliciting: Bool,
        receiveTime: ContinuousClock.Instant
    ) {
        ackManagers[level]?.recordReceivedPacket(
            packetNumber: packetNumber,
            isAckEliciting: isAckEliciting,
            receiveTime: receiveTime
        )
    }

    /// Processes an ACK frame
    ///
    /// Uses the internally managed `peerMaxAckDelay` for RTT calculation.
    ///
    /// - Parameters:
    ///   - ackFrame: The received ACK frame
    ///   - level: The encryption level
    ///   - receiveTime: When the ACK was received
    /// - Returns: The loss detection result
    package func onAckReceived(
        ackFrame: AckFrame,
        level: EncryptionLevel,
        receiveTime: ContinuousClock.Instant
    ) -> LossDetectionResult {
        guard let lossDetector = lossDetectors[level] else {
            return .empty
        }

        let rtt = rttEstimator
        let result = lossDetector.onAckReceived(
            ackFrame: ackFrame,
            ackReceivedTime: receiveTime,
            rttEstimator: rtt
        )

        // Update RTT if we got a sample
        if let sample = result.rttSample {
            updateRTT(
                sample: sample,
                ackDelay: result.ackDelay
            )
        }

        // Reset PTO count on valid ACK
        if !result.ackedPackets.isEmpty {
            resetPTOCount()
        }

        return result
    }

    /// Generates an ACK frame for a level if needed
    /// - Parameters:
    ///   - level: The encryption level
    ///   - now: Current time
    ///   - ackDelayExponent: The ACK delay exponent
    ///   - ecnCounts: ECN counts to include in the ACK frame (from `ECNManager.countsForACK`)
    /// - Returns: An ACK frame, or nil if not needed
    package func generateAckFrame(
        for level: EncryptionLevel,
        now: ContinuousClock.Instant,
        ackDelayExponent: UInt64,
        ecnCounts: ECNCounts? = nil
    ) -> AckFrame? {
        ackManagers[level]?.generateAckFrame(now: now, ackDelayExponent: ackDelayExponent, ecnCounts: ecnCounts)
    }

    // MARK: - Persistent Congestion Detection

    /// Checks if persistent congestion has occurred
    ///
    /// RFC 9002 Section 7.6.2: Establishing Persistent Congestion
    ///
    /// Persistent congestion is detected when the time between the oldest
    /// and newest lost ACK-eliciting packets exceeds the congestion period:
    ///
    /// ```
    /// congestion_period = 2 * PTO * kPersistentCongestionThreshold
    /// ```
    ///
    /// Where:
    /// - PTO = smoothed_rtt + max(4 * rttvar, kGranularity) + max_ack_delay
    /// - kPersistentCongestionThreshold = 3 (RFC 9002 default)
    ///
    /// Requirements for persistent congestion:
    /// 1. At least 2 ACK-eliciting packets must be lost
    /// 2. The time span between oldest and newest must exceed congestion_period
    /// 3. None of the lost packets were sent before the most recent RTT sample
    ///    (not implemented here - caller should filter if needed)
    ///
    /// - Note: Uses `effectiveMaxAckDelay` which is 0 before handshake confirmation
    ///   and `peerMaxAckDelay` after. This affects PTO calculation.
    ///
    /// - Parameter lostPackets: The packets detected as lost in this ACK processing
    /// - Returns: `true` if persistent congestion is detected
    package func checkPersistentCongestion(lostPackets: [SentPacket]) -> Bool {
        // Requirement 1: Need at least 2 lost packets to measure a time span
        guard lostPackets.count >= 2 else { return false }

        // Only ACK-eliciting packets count for persistent congestion
        let ackEliciting = lostPackets.filter { $0.ackEliciting }
        guard ackEliciting.count >= 2 else { return false }

        // Find the time span between oldest and newest lost packets
        let sorted = ackEliciting.sorted { $0.timeSent < $1.timeSent }
        guard let oldest = sorted.first, let newest = sorted.last else {
            return false
        }

        let timeSpan = newest.timeSent - oldest.timeSent

        // Calculate congestion period using current RTT estimates
        // Note: effectiveMaxAckDelay is 0 before handshake is confirmed
        let maxDelay = effectiveMaxAckDelay

        let pto = _rttEstimator.withLock { rtt in
            rtt.probeTimeout(maxAckDelay: maxDelay)
        }

        // RFC 9002: congestion_period = 2 * PTO * kPersistentCongestionThreshold
        // With threshold=3: congestion_period = 6 * PTO
        let congestionPeriod = pto * 2 * LossDetectionConstants.persistentCongestionThreshold

        return timeSpan >= congestionPeriod
    }

    // MARK: - PTO (Probe Timeout) Handling

    /// Determines the encryption level at which to send probe packets
    ///
    /// RFC 9002 Section 6.2.1: Priority order for PTO probes:
    /// 1. Initial (if keys available and packets in flight)
    /// 2. Handshake (if keys available and packets in flight)
    /// 3. Application (1-RTT) data
    ///
    /// - Parameter hasInitialKeys: Whether Initial keys are available
    /// - Parameter hasHandshakeKeys: Whether Handshake keys are available
    /// - Returns: The encryption level for probing, or nil if none needed
    package func getPTOSpace(
        hasInitialKeys: Bool,
        hasHandshakeKeys: Bool
    ) -> EncryptionLevel? {
        // During handshake, prioritize Initial and Handshake spaces
        if !handshakeConfirmed {
            // Check Initial space first
            if hasInitialKeys {
                if let detector = lossDetectors[.initial],
                   detector.ackElicitingInFlight > 0 {
                    return .initial
                }
            }

            // Then Handshake space
            if hasHandshakeKeys {
                if let detector = lossDetectors[.handshake],
                   detector.ackElicitingInFlight > 0 {
                    return .handshake
                }
            }
        }

        // Finally Application space
        if let detector = lossDetectors[.application],
           detector.ackElicitingInFlight > 0 {
            return .application
        }

        // RFC 9002 Section 6.2.2.1: If no ack-eliciting packets in flight,
        // client should still probe during handshake
        if !handshakeConfirmed {
            if hasInitialKeys {
                return .initial
            }
            if hasHandshakeKeys {
                return .handshake
            }
        }

        return nil
    }

    /// Handles PTO timeout and determines what action to take
    ///
    /// RFC 9002 Section 6.2: When the PTO timer expires, send probe packets.
    ///
    /// - Parameters:
    ///   - hasInitialKeys: Whether Initial keys are available
    ///   - hasHandshakeKeys: Whether Handshake keys are available
    /// - Returns: The action to take, or nil if no probing needed
    package func handlePTOTimeout(
        hasInitialKeys: Bool,
        hasHandshakeKeys: Bool
    ) -> PTOAction? {
        // Determine which space to probe
        guard let level = getPTOSpace(
            hasInitialKeys: hasInitialKeys,
            hasHandshakeKeys: hasHandshakeKeys
        ) else {
            return nil
        }

        // Increment PTO count
        onPTOExpired()

        // Get packets that can be retransmitted
        // (oldest unacknowledged ack-eliciting packets)
        let packetsToProbe: [SentPacket]
        if let detector = lossDetectors[level] {
            packetsToProbe = detector.getOldestUnackedPackets(count: 2)
        } else {
            packetsToProbe = []
        }

        return PTOAction(
            level: level,
            probeCount: 2,
            packetsToProbe: packetsToProbe
        )
    }

    /// Whether PTO probing is needed (no ack-eliciting packets in flight
    /// but handshake is not confirmed - client should send probes)
    ///
    /// RFC 9002 Section 6.2.2.1: If there are no ack-eliciting packets in
    /// flight, the client SHOULD set a PTO timer to send probe packets.
    package var needsPTOProbeEvenWithoutInFlight: Bool {
        !handshakeConfirmed && !hasAckElicitingInFlight
    }
}
