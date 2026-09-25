/// Stream Scheduler
///
/// Priority-based stream scheduler with fair queuing within priority levels.
/// Implements RFC 9218 Extensible Priorities for HTTP/3 integration.

import Foundation

// MARK: - StreamScheduling Protocol

/// Protocol for pluggable stream scheduling strategies.
///
/// Conforming types determine the order in which streams are served,
/// enabling alternative scheduling algorithms such as:
/// - FIFO (first-in, first-out)
/// - Weighted fair queuing
/// - Deadline-based scheduling
/// - Custom application-specific ordering
///
/// The default implementation is ``StreamScheduler``, which implements
/// RFC 9218 Extensible Priorities with incremental-aware scheduling.
public protocol StreamScheduling: Sendable {
    /// Schedules streams and returns them in priority order.
    ///
    /// - Parameter streams: Dictionary of stream ID to DataStream
    /// - Returns: Array of (streamID, stream) tuples ordered by the scheduling policy
    mutating func scheduleStreams(
        _ streams: [UInt64: DataStream]
    ) -> [(streamID: UInt64, stream: DataStream)]

    /// Advances the cursor for a specific urgency level.
    ///
    /// Call this after a stream at the given urgency has sent data
    /// to ensure fair rotation.
    mutating func advanceCursor(for urgency: UInt8, groupSize: Int)

    /// Resets all internal scheduling state (e.g., cursors).
    mutating func resetCursors()
}

// MARK: - Scheduling Strategy

/// Scheduling strategy that determines how streams within the same
/// urgency group are served.
///
/// RFC 9218 Section 5 describes the expected server behavior:
///
/// - **Non-incremental** streams: The server should dedicate resources to
///   a single stream at a time, completing it before moving to the next.
///   This minimizes time-to-first-byte for individual resources.
///
/// - **Incremental** streams: The server should interleave data from
///   multiple streams, sharing bandwidth. This enables progressive
///   rendering and streaming use cases.
///
/// ## Example
///
/// Urgency group with streams A (non-incremental), B (incremental), C (incremental):
/// - A is served exclusively first (non-incremental takes priority)
/// - B and C are interleaved after A completes
public enum SchedulingStrategy: Sendable, Hashable {
    /// Serve one stream at a time until completion (non-incremental default)
    case sequential

    /// Interleave data from multiple streams (incremental)
    case interleaved

    /// Round-robin within the group (fair sharing regardless of incremental flag)
    case roundRobin
}

// MARK: - StreamScheduler

/// Priority-based stream scheduler with fair queuing
///
/// This scheduler orders streams by their priority (urgency level) and implements
/// RFC 9218-compliant scheduling behavior:
///
/// 1. Group streams by urgency level (0-7)
/// 2. Process groups in priority order (0 first, 7 last)
/// 3. Within each group, apply incremental/non-incremental scheduling:
///    - Non-incremental streams are served one at a time (sequential)
///    - Incremental streams are interleaved (round-robin)
/// 4. Non-incremental streams within a group are served before incremental ones
/// 5. Cursors persist between calls for fairness
///
/// ## Thread Safety
/// This struct is not thread-safe by itself. It should be used within a synchronized context.
public struct StreamScheduler: StreamScheduling, Sendable {
    /// Round-robin cursors per urgency level
    ///
    /// Key: urgency level (0-7)
    /// Value: cursor position for next scheduling round
    private var cursors: [UInt8: Int] = [:]

    /// Scheduling mode (default: RFC 9218 compliant incremental-aware scheduling)
    public var useIncrementalScheduling: Bool = true

    /// Creates a new StreamScheduler
    public init() {}

    /// Schedules streams and returns them in priority order.
    ///
    /// When `useIncrementalScheduling` is true (default), the scheduler
    /// implements RFC 9218 behavior:
    /// - Non-incremental streams are placed first in each urgency group
    ///   (only the "active" one, determined by cursor)
    /// - Incremental streams are interleaved via round-robin after
    ///   non-incremental streams
    ///
    /// When `useIncrementalScheduling` is false, simple round-robin
    /// is used within each group (legacy behavior).
    ///
    /// - Parameter streams: Dictionary of stream ID to DataStream
    /// - Returns: Array of (streamID, stream) tuples ordered by priority with fair queuing
    public mutating func scheduleStreams(
        _ streams: [UInt64: DataStream]
    ) -> [(streamID: UInt64, stream: DataStream)] {
        // Group streams by urgency
        var groups: [UInt8: [(UInt64, DataStream)]] = [:]
        for (streamID, stream) in streams {
            let urgency = stream.priority.urgency
            groups[urgency, default: []].append((streamID, stream))
        }

        // Sort each group by stream ID for deterministic ordering
        for (urgency, group) in groups {
            groups[urgency] = group.sorted { $0.0 < $1.0 }
        }

        // Build result in priority order
        var result: [(streamID: UInt64, stream: DataStream)] = []

        // Process urgency levels in order (0 = highest priority first)
        for urgency in UInt8(0)...7 {
            guard let group = groups[urgency], !group.isEmpty else {
                continue
            }

            if useIncrementalScheduling {
                // RFC 9218 incremental-aware scheduling
                result.append(contentsOf: scheduleGroupIncremental(group, urgency: urgency))
            } else {
                // Legacy round-robin scheduling
                result.append(contentsOf: scheduleGroupRoundRobin(group, urgency: urgency))
            }
        }

        return result
    }

    /// Schedules a group with RFC 9218 incremental-aware behavior.
    ///
    /// Non-incremental streams are served one at a time (the current
    /// cursor-selected one goes first). Incremental streams are all
    /// included and interleaved via round-robin.
    ///
    /// The ordering within a group is:
    /// 1. The active non-incremental stream (cursor-selected)
    /// 2. All incremental streams (round-robin from cursor)
    /// 3. Remaining non-incremental streams
    private mutating func scheduleGroupIncremental(
        _ group: [(UInt64, DataStream)],
        urgency: UInt8
    ) -> [(streamID: UInt64, stream: DataStream)] {
        // Single-pass partition into non-incremental and incremental indices
        var nonIncrementalIndices: [Int] = []
        var incrementalIndices: [Int] = []
        nonIncrementalIndices.reserveCapacity(group.count)
        incrementalIndices.reserveCapacity(group.count)
        for i in group.indices {
            if group[i].1.priority.incremental {
                incrementalIndices.append(i)
            } else {
                nonIncrementalIndices.append(i)
            }
        }

        var result: [(streamID: UInt64, stream: DataStream)] = []
        result.reserveCapacity(group.count)

        // Handle non-incremental streams: serve only the active one first
        if !nonIncrementalIndices.isEmpty {
            let cursor = cursors[urgency] ?? 0
            let validCursor = cursor % nonIncrementalIndices.count

            // The active non-incremental stream goes first
            let activeIdx = nonIncrementalIndices[validCursor]
            result.append((streamID: group[activeIdx].0, stream: group[activeIdx].1))

            // Incremental streams interleaved after active non-incremental
            // (index-offset iteration — no temporary array allocation)
            if !incrementalIndices.isEmpty {
                let incrementalCursorKey = urgency &+ 128
                let incCursor = cursors[incrementalCursorKey] ?? 0
                let validIncCursor = incCursor % incrementalIndices.count
                let incCount = incrementalIndices.count
                for j in 0..<incCount {
                    let idx = incrementalIndices[(validIncCursor + j) % incCount]
                    result.append((streamID: group[idx].0, stream: group[idx].1))
                }
            }

            // Remaining non-incremental streams go last
            let niCount = nonIncrementalIndices.count
            for j in 1..<niCount {
                let idx = nonIncrementalIndices[(validCursor + j) % niCount]
                result.append((streamID: group[idx].0, stream: group[idx].1))
            }
        } else if !incrementalIndices.isEmpty {
            // Only incremental streams — round-robin via index offset
            let cursor = cursors[urgency] ?? 0
            let validCursor = cursor % incrementalIndices.count
            let incCount = incrementalIndices.count
            for j in 0..<incCount {
                let idx = incrementalIndices[(validCursor + j) % incCount]
                result.append((streamID: group[idx].0, stream: group[idx].1))
            }
        }

        return result
    }

    /// Schedules a group with simple round-robin (legacy behavior).
    private mutating func scheduleGroupRoundRobin(
        _ group: [(UInt64, DataStream)],
        urgency: UInt8
    ) -> [(streamID: UInt64, stream: DataStream)] {
        let cursor = cursors[urgency] ?? 0
        let validCursor = cursor % group.count
        let count = group.count

        // Index-offset iteration — no temporary array allocation
        var result: [(streamID: UInt64, stream: DataStream)] = []
        result.reserveCapacity(count)
        for j in 0..<count {
            let idx = (validCursor + j) % count
            result.append((streamID: group[idx].0, stream: group[idx].1))
        }

        // Update cursor for next round (advance by group size)
        cursors[urgency] = (validCursor + count) % count

        return result
    }

    /// Advances the cursor for a specific urgency level.
    ///
    /// Call this after a stream at the given urgency has sent data.
    /// This ensures the next stream in the group gets priority next time.
    public mutating func advanceCursor(for urgency: UInt8, groupSize: Int) {
        guard groupSize > 0 else { return }
        let current = cursors[urgency] ?? 0
        cursors[urgency] = (current + 1) % groupSize
    }

    /// Advances the incremental cursor for a specific urgency level.
    ///
    /// Call this after an incremental stream has sent data to rotate
    /// to the next incremental stream in the group.
    public mutating func advanceIncrementalCursor(for urgency: UInt8, groupSize: Int) {
        guard groupSize > 0 else { return }
        let cursorKey = urgency &+ 128
        let current = cursors[cursorKey] ?? 0
        cursors[cursorKey] = (current + 1) % groupSize
    }

    /// Resets all cursors.
    ///
    /// Call this when streams are significantly added/removed.
    public mutating func resetCursors() {
        cursors.removeAll()
    }

    /// Removes cursor for a specific urgency level.
    public mutating func removeCursor(for urgency: UInt8) {
        cursors.removeValue(forKey: urgency)
        cursors.removeValue(forKey: urgency &+ 128)
    }

    // MARK: - Priority Updates

    /// Applies a PRIORITY_UPDATE to the stream map.
    ///
    /// This updates the priority of the specified stream if it exists.
    /// If the stream doesn't exist yet (it may be created later), the
    /// update is returned as pending.
    ///
    /// - Parameters:
    ///   - update: The PRIORITY_UPDATE to apply
    ///   - streams: The current stream map
    /// - Returns: true if the stream was found and updated, false if pending
    public mutating func applyPriorityUpdate(
        _ update: PriorityUpdate,
        to streams: [UInt64: DataStream]
    ) -> Bool {
        if let stream = streams[update.elementID] {
            stream.priority = update.priority
            return true
        }
        return false
    }

    // MARK: - Private
}

// MARK: - StreamScheduler Statistics

extension StreamScheduler {
    /// Returns the current cursor positions for debugging.
    public var cursorPositions: [UInt8: Int] {
        cursors
    }

    /// Returns the number of tracked cursor positions.
    public var cursorCount: Int {
        cursors.count
    }
}

// MARK: - StreamPriority HTTP/3 Extensions

extension StreamPriority {
    /// Creates a StreamPriority from an HTTP/3 Priority header field value.
    ///
    /// Convenience initializer that delegates to `PriorityHeaderParser.parse`.
    ///
    /// - Parameter headerValue: The Priority header field value (e.g., "u=1, i")
    /// - Returns: The parsed StreamPriority
    public static func fromHeader(_ headerValue: String?) -> StreamPriority {
        PriorityHeaderParser.parse(headerValue)
    }

    /// Serializes this priority to an HTTP/3 Priority header field value.
    ///
    /// - Returns: The Priority header value string (e.g., "u=1, i")
    public func toHeader() -> String {
        PriorityHeaderParser.serialize(self)
    }

    // MARK: - HTTP/3 Stream Type Defaults

    /// Default priority for control streams.
    ///
    /// Control streams should have highest priority since they carry
    /// critical protocol data (SETTINGS, GOAWAY, etc.).
    public static let controlStream = StreamPriority(urgency: 0, incremental: false)

    /// Default priority for QPACK streams.
    ///
    /// QPACK encoder/decoder streams should have high priority to
    /// avoid blocking header decompression.
    public static let qpackStream = StreamPriority(urgency: 0, incremental: false)

    /// Default priority for server push streams.
    ///
    /// Push streams default to lower priority than regular requests
    /// since they're speculative.
    public static let pushStream = StreamPriority(urgency: 7, incremental: true)

    // MARK: - WebTransport Stream Type Defaults

    /// Default priority for WebTransport bidirectional streams.
    ///
    /// Bidi streams are typically interactive (request/response, echo, RPC),
    /// so they use the default HTTP/3 urgency with incremental delivery
    /// enabled to allow interleaving of concurrent bidi streams.
    public static let webTransportBidi = StreamPriority(urgency: 3, incremental: true)

    /// Default priority for WebTransport unidirectional streams.
    ///
    /// Uni streams are typically used for server-push notifications or
    /// one-shot data transfers. Slightly lower urgency than bidi streams
    /// since they're often less latency-sensitive.
    public static let webTransportUni = StreamPriority(urgency: 4, incremental: false)

    /// Default priority for WebTransport datagrams.
    ///
    /// Datagrams are unreliable and unordered, used for real-time data
    /// (game state, telemetry) that tolerates loss. Lower urgency than
    /// streams, with incremental delivery for fair sharing.
    public static let webTransportDatagram = StreamPriority(urgency: 5, incremental: true)

    /// Default priority for the WebTransport session CONNECT stream.
    ///
    /// The Extended CONNECT stream carries capsules (CLOSE, DRAIN) that
    /// control session lifecycle. It must have high priority to ensure
    /// timely session teardown and signaling.
    public static let webTransportSessionControl = StreamPriority(urgency: 1, incremental: false)
}