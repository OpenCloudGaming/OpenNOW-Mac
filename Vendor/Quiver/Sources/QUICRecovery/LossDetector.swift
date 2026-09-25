/// QUIC Loss Detection (RFC 9002 Section 4)
///
/// Detects lost packets using packet threshold and time threshold criteria.
/// Optimized for efficient ACK processing and loss detection.
///
/// ## Performance Optimizations
/// - Sorted array storage for cache-efficient iteration
/// - Bounds-based filtering to skip irrelevant packets
/// - Binary search for O(log n) packet lookup
/// - Batch operations for reduced overhead

import Foundation
import Synchronization
import QUICCore

/// Loss detection for a single packet number space (RFC 9002)
package final class LossDetector: Sendable {
    private let state: Mutex<LossState>

    private struct LossState {
        /// Sent packets awaiting acknowledgment, stored as sorted array by packet number
        /// Sorted order enables efficient range queries and cache-friendly iteration
        /// Note: Dictionary index was removed as profiling showed it was never read,
        /// only written. Binary search on sorted array provides O(log n) lookup.
        var sentPackets: ContiguousArray<SentPacket>

        /// Largest packet number acknowledged
        var largestAckedPacket: UInt64?

        /// Time when loss timer should fire
        var lossTime: ContinuousClock.Instant?

        /// Bytes in flight
        var bytesInFlight: Int = 0

        /// Ack-eliciting packets in flight
        var ackElicitingInFlight: Int = 0

        /// Smallest unacked packet number (for fast iteration)
        var smallestUnacked: UInt64?

        /// Largest sent packet number (for bounds checking)
        var largestSent: UInt64?

        init() {
            // Pre-allocate capacity to reduce reallocations
            // Typical QUIC connections have <1000 packets in flight
            self.sentPackets = ContiguousArray()
            self.sentPackets.reserveCapacity(128)
        }
    }

    /// Creates a new LossDetector
    package init() {
        self.state = Mutex(LossState())
    }

    /// Records a sent packet
    /// - Parameter packet: The sent packet to track
    ///
    /// ## Performance
    /// - Fast path (in-order): O(1) append
    /// - Slow path (out-of-order): O(n) insert (rare in practice)
    package func onPacketSent(_ packet: SentPacket) {
        state.withLock { state in
            let pn = packet.packetNumber

            // Fast path: packets usually arrive in order (append to end)
            if state.sentPackets.isEmpty || pn > state.sentPackets.last!.packetNumber {
                state.sentPackets.append(packet)
            } else {
                // Slow path: out-of-order packet (rare in practice)
                // Find insertion point using binary search
                let insertIdx = state.sentPackets.partitioningIndex { $0.packetNumber >= pn }
                state.sentPackets.insert(packet, at: insertIdx)
            }

            if packet.inFlight {
                state.bytesInFlight += packet.sentBytes
            }
            if packet.ackEliciting {
                state.ackElicitingInFlight += 1
            }

            // Update bounds
            if state.smallestUnacked == nil || pn < state.smallestUnacked! {
                state.smallestUnacked = pn
            }
            if state.largestSent == nil || pn > state.largestSent! {
                state.largestSent = pn
            }
        }
    }

    /// Processes acknowledgments and detects losses
    /// - Parameters:
    ///   - ackFrame: The received ACK frame
    ///   - ackReceivedTime: When the ACK was received
    ///   - rttEstimator: The RTT estimator to update
    /// - Returns: Result containing acknowledged and lost packets
    ///
    /// ## RFC 9002 Compliance
    /// - largestAckedPacket is only updated after successful ACK processing
    /// - RTT sample is taken from the largest newly acknowledged ack-eliciting packet
    /// - isFirstAckElicitingAck is set only when an ack-eliciting packet is actually acknowledged
    package func onAckReceived(
        ackFrame: AckFrame,
        ackReceivedTime: ContinuousClock.Instant,
        rttEstimator: RTTEstimator
    ) -> LossDetectionResult {
        // Estimate capacity based on ACK ranges to avoid reallocations
        let estimatedAcked = min(
            ackFrame.ackRanges.reduce(0) { $0 + Int($1.rangeLength) + 1 },
            256
        )
        var ackedPackets: [SentPacket] = []
        ackedPackets.reserveCapacity(estimatedAcked)
        var lostPackets: [SentPacket] = []
        lostPackets.reserveCapacity(8)
        var rttSample: Duration? = nil
        var isFirstAckElicitingAck = false

        state.withLock { state in
            let largestAcked = ackFrame.largestAcknowledged
            let wasFirstAck = state.largestAckedPacket == nil

            // Process acknowledged packets directly from ACK ranges (no intermediate array)
            // This validates ACK ranges by checking against our sent packets
            processAckedRanges(
                ackFrame: ackFrame,
                state: &state,
                ackedPackets: &ackedPackets,
                rttSample: &rttSample,
                ackReceivedTime: ackReceivedTime
            )

            // [Critical Fix] Only update largestAckedPacket AFTER successful ACK processing
            // This prevents spurious loss detection from invalid ACK frames
            if !ackedPackets.isEmpty {
                if state.largestAckedPacket == nil || largestAcked > state.largestAckedPacket! {
                    state.largestAckedPacket = largestAcked
                }

                // [Warning Fix] isFirstAckElicitingAck: only set when we actually
                // acknowledged an ack-eliciting packet for the first time
                if wasFirstAck && ackedPackets.contains(where: { $0.ackEliciting }) {
                    isFirstAckElicitingAck = true
                }
            }

            // Detect lost packets
            lostPackets = detectLostPacketsInternal(
                &state,
                now: ackReceivedTime,
                rttEstimator: rttEstimator
            )
        }

        // Decode ack delay (already in microseconds after frame decoding)
        let ackDelay = Duration.microseconds(Int64(ackFrame.ackDelay))

        return LossDetectionResult(
            ackedPackets: ackedPackets,
            lostPackets: lostPackets,
            rttSample: rttSample,
            ackDelay: ackDelay,
            isFirstAckElicitingAck: isFirstAckElicitingAck
        )
    }

    /// Pre-computed ACK range interval for efficient lookup
    private struct AckInterval {
        let start: UInt64  // Inclusive
        let end: UInt64    // Inclusive
    }

    /// Processes ACK ranges using bounded iteration over sentPackets
    ///
    /// SECURITY: This method iterates over sentPackets (bounded by our own sent packets)
    /// instead of iterating over ACK ranges (which could be attacker-controlled).
    /// This prevents CPU DoS attacks via malicious ACK frames with huge ranges.
    ///
    /// ## Performance Optimization
    /// - Pre-computes ACK ranges as intervals once
    /// - Uses binary search to find packet range bounds
    /// - Iterates only packets within [smallestAcked, largestAcked]
    /// - Uses Set + removeAll(where:) for O(n) batch removal instead of O(k*n)
    ///
    /// ## RFC 9002 Compliance
    /// - RTT sample is taken ONLY if the largest newly acknowledged packet is ack-eliciting
    ///   (RFC 9002 Section 5.1: use only the largest newly acknowledged packet)
    @inline(__always)
    private func processAckedRanges(
        ackFrame: AckFrame,
        state: inout LossState,
        ackedPackets: inout [SentPacket],
        rttSample: inout Duration?,
        ackReceivedTime: ContinuousClock.Instant
    ) {
        let largestAcked = ackFrame.largestAcknowledged

        // Pre-compute ACK ranges as intervals (sorted by start descending)
        let intervals = computeAckIntervals(ranges: ackFrame.ackRanges, largestAcked: largestAcked)
        guard !intervals.isEmpty else { return }

        // Compute bounds: smallest acknowledged packet number
        let smallestAcked = intervals.last!.start

        // Find the range of indices to check using binary search
        // Only check packets in [smallestAcked, largestAcked]
        let startIdx = state.sentPackets.partitioningIndex { $0.packetNumber >= smallestAcked }
        let endIdx = state.sentPackets.partitioningIndex { $0.packetNumber > largestAcked }

        guard startIdx < endIdx else { return }

        // Collect acknowledged packet numbers for efficient batch removal
        // Using Set for O(1) lookup during removeAll
        var ackedPacketNumbers = Set<UInt64>()
        ackedPacketNumbers.reserveCapacity(endIdx - startIdx)

        // Track the largest acked packet for RTT sampling (RFC 9002 Section 5.1)
        // RTT sample is only taken if this packet is ack-eliciting
        var largestAckedPacket: SentPacket? = nil

        for i in startIdx..<endIdx {
            let packet = state.sentPackets[i]
            let pn = packet.packetNumber

            // Check if this packet number falls within any ACK range using binary search
            if isPacketInIntervals(pn, intervals: intervals) {
                ackedPacketNumbers.insert(pn)
                ackedPackets.append(packet)

                if packet.inFlight {
                    state.bytesInFlight -= packet.sentBytes
                }
                if packet.ackEliciting {
                    state.ackElicitingInFlight -= 1
                }

                // Track largest acked packet (iteration is in ascending pn order)
                // The last packet matching largestAcked is what we want
                if pn == largestAcked {
                    largestAckedPacket = packet
                }
            }
        }

        // RFC 9002 Section 5.1: RTT sample is generated using ONLY the largest
        // newly acknowledged packet, and only if it's ack-eliciting
        if let packet = largestAckedPacket, packet.ackEliciting {
            rttSample = ackReceivedTime - packet.timeSent
        }

        // Batch remove using removeAll(where:) - O(n) single pass
        // This is much faster than individual remove(at:) calls which are O(n) each
        if !ackedPacketNumbers.isEmpty {
            state.sentPackets.removeAll { ackedPacketNumbers.contains($0.packetNumber) }
        }
    }

    /// Computes ACK intervals from ACK ranges
    ///
    /// ACK ranges are structured as (RFC 9000 Section 19.3.1):
    /// - First range: [largestAcked - firstRange.rangeLength, largestAcked]
    /// - Subsequent ranges: gap indicates unacked packets below (smallest_prev - 1)
    ///
    /// Returns intervals sorted by start (descending order).
    @inline(__always)
    private func computeAckIntervals(ranges: [AckRange], largestAcked: UInt64) -> [AckInterval] {
        var intervals: [AckInterval] = []
        intervals.reserveCapacity(ranges.count)

        var current = largestAcked

        for (index, range) in ranges.enumerated() {
            let rangeEnd: UInt64
            let rangeStart: UInt64

            if index == 0 {
                rangeEnd = current
                guard range.rangeLength <= current else { break }
                rangeStart = current - range.rangeLength
            } else {
                let gapOffset = range.gap + 1
                guard gapOffset <= current else { break }
                current = current - gapOffset
                rangeEnd = current
                guard range.rangeLength <= current else { break }
                rangeStart = current - range.rangeLength
            }

            intervals.append(AckInterval(start: rangeStart, end: rangeEnd))
            current = rangeStart
        }

        return intervals
    }

    /// Checks if a packet number falls within any of the pre-computed intervals
    /// using binary search for O(log n) lookup.
    ///
    /// Intervals are sorted by start (descending) and non-overlapping.
    /// Binary search finds the first interval where end >= pn, then we check if start <= pn.
    @inline(__always)
    private func isPacketInIntervals(_ pn: UInt64, intervals: [AckInterval]) -> Bool {
        // Binary search to find the first interval where end >= pn
        // Since intervals are sorted descending (by both start and end),
        // we find the first interval that could contain pn
        var lo = 0
        var hi = intervals.count

        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if intervals[mid].end < pn {
                // This interval's end is below pn, look in earlier (larger) intervals
                hi = mid
            } else {
                // This interval's end >= pn, might contain pn or answer is further right
                lo = mid + 1
            }
        }

        // lo points to one past the last interval where end >= pn
        // Check if the interval at lo-1 contains pn
        if lo > 0 {
            let interval = intervals[lo - 1]
            return pn >= interval.start && pn <= interval.end
        }

        return false
    }

    /// Internal loss detection algorithm (RFC 9002 Section 4.3)
    ///
    /// ## Performance Optimization
    /// - Uses binary search to find boundary for iteration
    /// - Uses Set + removeAll(where:) for O(n) batch removal instead of O(k*n)
    ///
    /// ## RFC 9002 Compliance
    /// - Loss detection only applies to in-flight packets
    /// - Loss timer (earliestLossTime) is only set based on in-flight packets
    private func detectLostPacketsInternal(
        _ state: inout LossState,
        now: ContinuousClock.Instant,
        rttEstimator: RTTEstimator
    ) -> [SentPacket] {
        guard let largestAcked = state.largestAckedPacket else { return [] }

        // Calculate loss delay threshold once
        let baseRTT = max(rttEstimator.latestRTT, rttEstimator.smoothedRTT)
        let lossDelay = baseRTT * LossDetectionConstants.timeThresholdNumerator /
                        LossDetectionConstants.timeThresholdDenominator
        let lossDelayThreshold = max(lossDelay, LossDetectionConstants.granularity)

        var lostPackets: [SentPacket] = []
        lostPackets.reserveCapacity(8)
        var earliestLossTime: ContinuousClock.Instant? = nil
        var lostPacketNumbers = Set<UInt64>()
        lostPacketNumbers.reserveCapacity(8)

        // Only iterate packets with pn < largestAcked (potential loss candidates)
        // Use binary search to find the boundary
        let boundaryIdx = state.sentPackets.partitioningIndex { $0.packetNumber >= largestAcked }

        // Process packets before boundary (pn < largestAcked) - potential loss candidates
        for i in 0..<boundaryIdx {
            let packet = state.sentPackets[i]
            let pn = packet.packetNumber

            // [Warning Fix] RFC 9002: Loss detection only applies to in-flight packets
            // Non-in-flight packets (e.g., ACK-only) should not trigger loss detection
            // or affect the loss timer
            guard packet.inFlight else {
                // Still remove non-in-flight packets that are older than loss threshold
                // to avoid memory growth, but don't report them as lost
                let packetLost = largestAcked >= pn + LossDetectionConstants.packetThreshold
                let timeLost = (now - packet.timeSent) >= lossDelayThreshold
                if packetLost || timeLost {
                    lostPacketNumbers.insert(pn)
                    if packet.ackEliciting {
                        state.ackElicitingInFlight -= 1
                    }
                }
                continue
            }

            // Packet threshold loss: 3+ newer packets acknowledged
            let packetLost = largestAcked >= pn + LossDetectionConstants.packetThreshold

            // Time threshold loss
            let timeLost = (now - packet.timeSent) >= lossDelayThreshold

            if packetLost || timeLost {
                lostPacketNumbers.insert(pn)
                lostPackets.append(packet)
                state.bytesInFlight -= packet.sentBytes
                if packet.ackEliciting {
                    state.ackElicitingInFlight -= 1
                }
            } else {
                // Not yet lost by packet threshold - calculate when it will be lost by time
                // Only in-flight packets contribute to the loss timer
                if largestAcked < pn + LossDetectionConstants.packetThreshold {
                    let lossTime = packet.timeSent + lossDelayThreshold
                    if earliestLossTime == nil || lossTime < earliestLossTime! {
                        earliestLossTime = lossTime
                    }
                }
            }
        }

        // Batch remove using removeAll(where:) - O(n) single pass
        if !lostPacketNumbers.isEmpty {
            state.sentPackets.removeAll { lostPacketNumbers.contains($0.packetNumber) }
        }

        // Update smallest unacked
        state.smallestUnacked = state.sentPackets.first?.packetNumber
        state.lossTime = earliestLossTime

        return lostPackets
    }

    /// Detects losses due to timeout
    /// - Parameters:
    ///   - now: Current time
    ///   - rttEstimator: The RTT estimator
    /// - Returns: Packets detected as lost
    package func detectLostPackets(
        now: ContinuousClock.Instant,
        rttEstimator: RTTEstimator
    ) -> [SentPacket] {
        state.withLock { state in
            detectLostPacketsInternal(&state, now: now, rttEstimator: rttEstimator)
        }
    }

    /// Gets the earliest loss time for timer scheduling
    package func earliestLossTime() -> ContinuousClock.Instant? {
        state.withLock { $0.lossTime }
    }

    /// Gets packets that need retransmission (ack-eliciting packets still in flight)
    package func getRetransmittablePackets() -> [SentPacket] {
        state.withLock { state in
            // Use lazy filter to avoid intermediate array allocation,
            // then collect only matching packets
            var result: [SentPacket] = []
            result.reserveCapacity(state.ackElicitingInFlight)
            for packet in state.sentPackets where packet.ackEliciting {
                result.append(packet)
            }
            return result
        }
    }

    /// Gets the current bytes in flight
    package var bytesInFlight: Int {
        state.withLock { $0.bytesInFlight }
    }

    /// Gets the count of ack-eliciting packets in flight
    package var ackElicitingInFlight: Int {
        state.withLock { $0.ackElicitingInFlight }
    }

    /// Gets the largest acknowledged packet number
    package var largestAckedPacket: UInt64? {
        state.withLock { $0.largestAckedPacket }
    }

    /// Gets the smallest unacked packet number
    package var smallestUnacked: UInt64? {
        state.withLock { $0.smallestUnacked }
    }

    /// Gets the oldest unacknowledged ack-eliciting packets for PTO probing
    ///
    /// RFC 9002 Section 6.2: When PTO expires, send probe packets.
    /// The probe SHOULD carry data from the oldest unacked packet.
    ///
    /// - Parameter count: Maximum number of packets to return (typically 2)
    /// - Returns: Oldest unacked ack-eliciting packets, sorted by packet number
    package func getOldestUnackedPackets(count: Int) -> [SentPacket] {
        state.withLock { state in
            // sentPackets is already sorted by packet number
            // Just iterate from the beginning and take first `count` ack-eliciting packets
            var result: [SentPacket] = []
            result.reserveCapacity(count)

            for packet in state.sentPackets {
                if packet.ackEliciting {
                    result.append(packet)
                    if result.count >= count {
                        break
                    }
                }
            }

            return result
        }
    }

    /// Clears state (called when encryption level is discarded)
    package func clear() {
        state.withLock { state in
            state.sentPackets.removeAll(keepingCapacity: true)
            state.largestAckedPacket = nil
            state.largestSent = nil
            state.lossTime = nil
            state.bytesInFlight = 0
            state.ackElicitingInFlight = 0
            state.smallestUnacked = nil
        }
    }
}

// MARK: - ContiguousArray Extension

extension ContiguousArray {
    /// Returns the index of the first element where the predicate is true
    /// Uses binary search, assumes array is sorted by the predicate
    @inline(__always)
    fileprivate func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count

        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
