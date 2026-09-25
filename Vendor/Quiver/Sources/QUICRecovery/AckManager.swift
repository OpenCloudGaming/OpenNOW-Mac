/// ACK Frame Generation (RFC 9002 Section 3)
///
/// Manages received packets and generates ACK frames for a single packet number space.
/// Optimized with interval-based tracking for efficient ACK range generation.

import Foundation
import Synchronization
import QUICCore

/// Manages ACK state for a single packet number space
public final class AckManager: Sendable {
    private let state: Mutex<AckState>

    /// Represents a contiguous range of received packets
    private struct PacketRange: Comparable {
        var start: UInt64  // Smallest packet number in range
        var end: UInt64    // Largest packet number in range
        var receiveTime: ContinuousClock.Instant  // Time when last packet in range was received

        static func < (lhs: PacketRange, rhs: PacketRange) -> Bool {
            lhs.start < rhs.start
        }
    }

    private struct AckState {
        /// Received packet ranges (sorted by start, non-overlapping)
        var receivedRanges: [PacketRange]

        /// Largest packet number received
        var largestReceived: UInt64?

        /// Time when largest packet was received
        var largestReceivedTime: ContinuousClock.Instant?

        /// Number of ack-eliciting packets received since last ACK
        var ackElicitingCount: Int = 0

        /// Whether we should ACK immediately
        var shouldAckImmediately: Bool = false

        /// Time when we should send next ACK (if not immediate)
        var ackAlarm: ContinuousClock.Instant?

        /// Maximum delay before sending ACK
        var maxAckDelay: Duration

        /// Total packet count for memory management
        var totalPacketCount: Int = 0

        /// Cache for sequential packet fast path
        /// Tracks the end of the last range for O(1) sequential insert
        var lastRangeEnd: UInt64?

        init(maxAckDelay: Duration) {
            self.maxAckDelay = maxAckDelay
            self.receivedRanges = []
            self.receivedRanges.reserveCapacity(32)
        }
    }

    /// Maximum number of ranges to track
    private static let maxRanges = 256

    /// Creates a new AckManager
    /// - Parameter maxAckDelay: Maximum delay before sending ACK (default 25ms)
    public init(maxAckDelay: Duration = LossDetectionConstants.defaultMaxAckDelay) {
        self.state = Mutex(AckState(maxAckDelay: maxAckDelay))
    }

    /// Records a received packet
    /// - Parameters:
    ///   - packetNumber: The packet number
    ///   - isAckEliciting: Whether the packet contains ack-eliciting frames
    ///   - receiveTime: When the packet was received
    public func recordReceivedPacket(
        packetNumber: UInt64,
        isAckEliciting: Bool,
        receiveTime: ContinuousClock.Instant
    ) {
        state.withLock { state in
            // Insert packet into ranges (maintains sorted, merged ranges)
            insertPacket(packetNumber, receiveTime: receiveTime, into: &state)

            // Update largest
            if state.largestReceived == nil || packetNumber > state.largestReceived! {
                state.largestReceived = packetNumber
                state.largestReceivedTime = receiveTime
            }

            if isAckEliciting {
                state.ackElicitingCount += 1

                // RFC 9002: Send ACK immediately for first ack-eliciting packet
                if state.ackElicitingCount == 1 {
                    state.shouldAckImmediately = true
                } else if state.ackAlarm == nil {
                    // Set ack timer
                    state.ackAlarm = receiveTime + state.maxAckDelay
                }

                // RFC 9002: Send ACK for every 2 ack-eliciting packets
                if state.ackElicitingCount >= 2 {
                    state.shouldAckImmediately = true
                }
            }
        }
    }

    /// Result of unified binary search
    private enum BinarySearchResult {
        case contained(at: Int)  // Packet is within an existing range
        case insertAt(Int)       // Packet should be inserted at this index
    }

    /// Unified binary search: finds if packet is contained or where to insert
    /// Single search instead of two separate searches
    @inline(__always)
    private func findPacketPosition(_ packetNumber: UInt64, in ranges: [PacketRange]) -> BinarySearchResult {
        var low = 0
        var high = ranges.count

        while low < high {
            let mid = (low + high) / 2
            let range = ranges[mid]

            if packetNumber < range.start {
                high = mid
            } else if packetNumber > range.end {
                low = mid + 1
            } else {
                return .contained(at: mid)
            }
        }
        return .insertAt(low)
    }

    /// Inserts a packet number into the ranges, merging as needed
    /// Uses fast path for sequential packets, binary search for others
    private func insertPacket(
        _ packetNumber: UInt64,
        receiveTime: ContinuousClock.Instant,
        into state: inout AckState
    ) {
        // Fast path: sequential packet (most common case in QUIC)
        // ~90% of packets arrive in order, so this saves binary search overhead
        if let lastEnd = state.lastRangeEnd, packetNumber == lastEnd + 1 {
            // Extend the last range - O(1) operation
            let lastIndex = state.receivedRanges.count - 1
            state.receivedRanges[lastIndex].end = packetNumber
            state.receivedRanges[lastIndex].receiveTime = max(
                state.receivedRanges[lastIndex].receiveTime,
                receiveTime
            )
            state.lastRangeEnd = packetNumber
            state.totalPacketCount += 1
            return
        }

        // Slow path: out-of-order or first packet
        insertPacketSlow(packetNumber, receiveTime: receiveTime, into: &state)
    }

    /// Slow path for inserting out-of-order packets
    @inline(never)
    private func insertPacketSlow(
        _ packetNumber: UInt64,
        receiveTime: ContinuousClock.Instant,
        into state: inout AckState
    ) {
        switch findPacketPosition(packetNumber, in: state.receivedRanges) {
        case .contained(let index):
            // Already in a range, just update receive time if newer
            if receiveTime > state.receivedRanges[index].receiveTime {
                state.receivedRanges[index].receiveTime = receiveTime
            }
            return

        case .insertAt(let insertIndex):
            state.totalPacketCount += 1

            // Check if we can extend the previous range
            let canExtendPrevious = insertIndex > 0 &&
                state.receivedRanges[insertIndex - 1].end + 1 == packetNumber

            // Check if we can extend the next range
            let canExtendNext = insertIndex < state.receivedRanges.count &&
                packetNumber + 1 == state.receivedRanges[insertIndex].start

            if canExtendPrevious && canExtendNext {
                // Merge three ranges into one
                let prevIndex = insertIndex - 1
                state.receivedRanges[prevIndex].end = state.receivedRanges[insertIndex].end
                state.receivedRanges[prevIndex].receiveTime = max(
                    state.receivedRanges[prevIndex].receiveTime,
                    receiveTime,
                    state.receivedRanges[insertIndex].receiveTime
                )
                state.receivedRanges.remove(at: insertIndex)
                // Update lastRangeEnd if we extended the last range
                if prevIndex == state.receivedRanges.count - 1 {
                    state.lastRangeEnd = state.receivedRanges[prevIndex].end
                }
            } else if canExtendPrevious {
                // Extend previous range
                state.receivedRanges[insertIndex - 1].end = packetNumber
                state.receivedRanges[insertIndex - 1].receiveTime = max(
                    state.receivedRanges[insertIndex - 1].receiveTime,
                    receiveTime
                )
                // Update lastRangeEnd if we extended the last range
                if insertIndex - 1 == state.receivedRanges.count - 1 {
                    state.lastRangeEnd = packetNumber
                }
            } else if canExtendNext {
                // Extend next range
                state.receivedRanges[insertIndex].start = packetNumber
                state.receivedRanges[insertIndex].receiveTime = max(
                    state.receivedRanges[insertIndex].receiveTime,
                    receiveTime
                )
            } else {
                // Insert new range
                let newRange = PacketRange(start: packetNumber, end: packetNumber, receiveTime: receiveTime)
                state.receivedRanges.insert(newRange, at: insertIndex)

                // Update lastRangeEnd if this is now the last range
                if insertIndex == state.receivedRanges.count - 1 {
                    state.lastRangeEnd = packetNumber
                }

                // Prune if too many ranges (25% removal for smoother degradation)
                if state.receivedRanges.count > Self.maxRanges {
                    // Remove oldest (smallest) ranges, keep 75%
                    let toRemove = state.receivedRanges.count - (Self.maxRanges * 3 / 4)
                    state.receivedRanges.removeFirst(toRemove)
                    // Update lastRangeEnd after pruning
                    state.lastRangeEnd = state.receivedRanges.last?.end
                }
            }
        }
    }

    /// Generates an ACK frame if needed
    /// - Parameters:
    ///   - now: Current time
    ///   - ackDelayExponent: ACK delay exponent for encoding
    /// - Returns: An ACK frame, or nil if no ACK is needed
    public func generateAckFrame(
        now: ContinuousClock.Instant,
        ackDelayExponent: UInt64,
        ecnCounts: ECNCounts? = nil
    ) -> AckFrame? {
        state.withLock { state in
            guard let largest = state.largestReceived,
                  let largestTime = state.largestReceivedTime else {
                return nil
            }

            // Check if we need to send an ACK
            let shouldSend = state.shouldAckImmediately ||
                            (state.ackAlarm != nil && now >= state.ackAlarm!)

            guard shouldSend || state.ackElicitingCount > 0 else {
                return nil
            }

            // Calculate ack delay
            let delay = now - largestTime
            let delayMicros = delay.components.seconds * 1_000_000 +
                              delay.components.attoseconds / 1_000_000_000_000
            let encodedDelay = UInt64(max(0, delayMicros)) >> ackDelayExponent

            // Build ACK ranges directly from our interval structure (already sorted)
            let ranges = buildAckRanges(from: state.receivedRanges, largest: largest)

            // Reset counters
            state.ackElicitingCount = 0
            state.shouldAckImmediately = false
            state.ackAlarm = nil

            return AckFrame(
                largestAcknowledged: largest,
                ackDelay: encodedDelay,
                ackRanges: ranges,
                ecnCounts: ecnCounts
            )
        }
    }

    /// Builds ACK ranges from interval structure
    /// O(k) where k is number of ranges (typically small)
    private func buildAckRanges(from packetRanges: [PacketRange], largest: UInt64) -> [AckRange] {
        guard !packetRanges.isEmpty else { return [] }

        var ackRanges: [AckRange] = []
        ackRanges.reserveCapacity(min(packetRanges.count, Int(LossDetectionConstants.maxAckRanges)))

        // Process ranges in reverse order (largest to smallest)
        var previousRangeStart: UInt64? = nil

        for i in stride(from: packetRanges.count - 1, through: 0, by: -1) {
            guard ackRanges.count < LossDetectionConstants.maxAckRanges else { break }

            let range = packetRanges[i]
            let rangeLength = range.end - range.start

            if ackRanges.isEmpty {
                // First ACK range (from largest acknowledged)
                ackRanges.append(AckRange(gap: 0, rangeLength: rangeLength))
            } else {
                // Calculate gap: unacked packets between this range and previous
                // Gap = previousRangeStart - range.end - 2
                let gap = previousRangeStart! - range.end - 2
                ackRanges.append(AckRange(gap: gap, rangeLength: rangeLength))
            }

            previousRangeStart = range.start
        }

        return ackRanges
    }

    /// Whether an ACK should be sent immediately
    public func shouldSendAckImmediately() -> Bool {
        state.withLock { $0.shouldAckImmediately }
    }

    /// Gets the time when the next ACK should be sent
    public func nextAckTime() -> ContinuousClock.Instant? {
        state.withLock { state in
            if state.shouldAckImmediately {
                return .now
            }
            return state.ackAlarm
        }
    }

    /// Clears acknowledgment state (called when encryption level is discarded)
    public func clear() {
        state.withLock { state in
            state.receivedRanges.removeAll()
            state.largestReceived = nil
            state.largestReceivedTime = nil
            state.ackElicitingCount = 0
            state.shouldAckImmediately = false
            state.ackAlarm = nil
            state.totalPacketCount = 0
            state.lastRangeEnd = nil
        }
    }

    /// Gets the largest received packet number
    public var largestReceived: UInt64? {
        state.withLock { $0.largestReceived }
    }

    /// Gets the count of received packets
    public var receivedPacketCount: Int {
        state.withLock { $0.totalPacketCount }
    }

    /// Gets the number of ranges being tracked
    public var rangeCount: Int {
        state.withLock { $0.receivedRanges.count }
    }
}

// MARK: - Array Extension for Binary Search

extension Array {
    /// Returns the index of the first element where the predicate is true
    /// Uses binary search, assumes array is sorted by the predicate
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
