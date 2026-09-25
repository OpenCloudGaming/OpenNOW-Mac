/// HTTP3Connection — Priority Tracking & Scheduling (RFC 9218)
///
/// Extension containing priority-related functionality:
/// - `handlePriorityUpdate` — processes PRIORITY_UPDATE frames from control stream
/// - `sendPriorityUpdate` — sends PRIORITY_UPDATE frames to peer
/// - `priority(for:)` — queries effective priority for a stream
/// - `cleanupStreamPriority` — cleans up tracking for closed streams
/// - Priority scheduling helpers for response stream ordering

import Foundation
import QUIC
import QUICCore
import QUICStream

// MARK: - Priority Tracking & Scheduling (RFC 9218)

extension HTTP3Connection {

    // MARK: - Priority Tracking

    /// Handles a PRIORITY_UPDATE frame received on the control stream.
    ///
    /// Updates the priority for the specified stream. If the stream
    /// hasn't been created yet, the priority is stored as pending.
    ///
    /// - Parameters:
    ///   - streamID: The stream ID being reprioritized
    ///   - priority: The new priority
    func handlePriorityUpdate(streamID: UInt64, priority: StreamPriority) {
        // Check if the stream is already active (has an existing priority entry
        // that was set when the request stream was first processed).
        // If the stream is not yet known, store the update as pending so it
        // can be applied when the stream is created.
        let isExistingStream = streamPriorities.keys.contains(streamID)

        streamPriorities[streamID] = priority

        if !isExistingStream {
            pendingPriorityUpdates[streamID] = priority
        }

        // Update the active response stream priority if it exists
        if activeResponseStreams.keys.contains(streamID) {
            activeResponseStreams[streamID] = priority
        }
    }

    /// Sends a PRIORITY_UPDATE frame for a request stream.
    ///
    /// RFC 9218 Section 7.1: PRIORITY_UPDATE frames are sent on the
    /// control stream to dynamically change the priority of a stream.
    ///
    /// - Parameters:
    ///   - streamID: The stream ID to reprioritize
    ///   - priority: The new priority
    /// - Throws: `HTTP3Error` if the control stream is not available
    public func sendPriorityUpdate(streamID: UInt64, priority: StreamPriority) async throws {
        guard let controlStream = localControlStream else {
            throw HTTP3Error(code: .closedCriticalStream, reason: "Control stream not open")
        }

        let frame = HTTP3Frame.priorityUpdateRequest(streamID: streamID, priority: priority)
        let encoded = HTTP3FrameCodec.encode(frame)
        try await controlStream.write(encoded)

        // Track locally
        streamPriorities[streamID] = priority
    }

    /// Returns the effective priority for a stream.
    ///
    /// Checks dynamic priorities (from PRIORITY_UPDATE) first,
    /// then falls back to the default priority.
    ///
    /// - Parameter streamID: The stream ID to query
    /// - Returns: The effective priority, or `.default` if not tracked
    public func priority(for streamID: UInt64) -> StreamPriority {
        streamPriorities[streamID] ?? .default
    }

    /// Cleans up priority tracking for a closed stream.
    ///
    /// - Parameter streamID: The stream ID to clean up
    func cleanupStreamPriority(_ streamID: UInt64) {
        streamPriorities.removeValue(forKey: streamID)
        pendingPriorityUpdates.removeValue(forKey: streamID)
        activeResponseStreams.removeValue(forKey: streamID)
        streamScheduler.resetCursors()
    }

    // MARK: - Priority Scheduling

    /// Registers a stream as an active response stream with the given priority.
    ///
    /// Call this when beginning to send a response. The stream will be
    /// included in priority-ordered scheduling until it is cleaned up.
    ///
    /// - Parameters:
    ///   - streamID: The stream ID to register
    ///   - priority: The stream's effective priority
    public func registerActiveResponseStream(_ streamID: UInt64, priority: StreamPriority) {
        activeResponseStreams[streamID] = priority
    }

    /// Unregisters a stream from active response scheduling.
    ///
    /// Call this when the response has been fully sent.
    ///
    /// - Parameter streamID: The stream ID to unregister
    public func unregisterActiveResponseStream(_ streamID: UInt64) {
        activeResponseStreams.removeValue(forKey: streamID)
    }

    /// Returns stream IDs sorted by priority for scheduling data sends.
    ///
    /// Implements RFC 9218 scheduling:
    /// - Lower urgency values are served first (urgency 0 = highest priority)
    /// - Within the same urgency level, non-incremental streams are served
    ///   one at a time (sequential), while incremental streams are interleaved
    /// - Round-robin rotation ensures fairness within urgency groups
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let orderedStreams = connection.priorityOrderedStreamIDs()
    /// for streamID in orderedStreams {
    ///     // Send data on this stream
    /// }
    /// ```
    ///
    /// - Returns: Array of stream IDs in priority-scheduled order
    public func priorityOrderedStreamIDs() -> [UInt64] {
        guard !activeResponseStreams.isEmpty else { return [] }

        // Build a list sorted by priority, then by stream ID for determinism
        var grouped: [UInt8: [(streamID: UInt64, priority: StreamPriority)]] = [:]
        for (streamID, priority) in activeResponseStreams {
            grouped[priority.urgency, default: []].append((streamID, priority))
        }

        // Sort each group by stream ID for deterministic ordering
        for (urgency, group) in grouped {
            grouped[urgency] = group.sorted { $0.streamID < $1.streamID }
        }

        var result: [UInt64] = []

        // Process urgency levels in order (0 = highest priority first)
        for urgency in UInt8(0)...7 {
            guard let group = grouped[urgency], !group.isEmpty else {
                continue
            }

            // Separate incremental and non-incremental
            let nonIncremental = group.filter { !$0.priority.incremental }
            let incremental = group.filter { $0.priority.incremental }

            if !nonIncremental.isEmpty {
                // Non-incremental: serve the active one first (cursor-based)
                let cursor = streamScheduler.cursorPositions[urgency] ?? 0
                let validCursor = cursor % nonIncremental.count
                result.append(nonIncremental[validCursor].streamID)

                // Then interleave incremental streams
                for entry in incremental {
                    result.append(entry.streamID)
                }

                // Then remaining non-incremental
                for (i, entry) in nonIncremental.enumerated() where i != validCursor {
                    result.append(entry.streamID)
                }
            } else {
                // Only incremental — round-robin all
                for entry in incremental {
                    result.append(entry.streamID)
                }
            }
        }

        return result
    }

    /// Advances the scheduler cursor for a given urgency level after
    /// data has been sent on a stream at that urgency.
    ///
    /// This ensures fair round-robin scheduling across streams at the
    /// same urgency level.
    ///
    /// - Parameter streamID: The stream that just sent data
    public func advanceSchedulerCursor(for streamID: UInt64) {
        guard let priority = activeResponseStreams[streamID] else { return }
        let urgency = priority.urgency

        // Count streams at this urgency level
        let groupSize = activeResponseStreams.values.filter { $0.urgency == urgency }.count
        guard groupSize > 0 else { return }

        if priority.incremental {
            streamScheduler.advanceIncrementalCursor(for: urgency, groupSize: groupSize)
        } else {
            streamScheduler.advanceCursor(for: urgency, groupSize: groupSize)
        }
    }

    /// The number of active response streams being tracked for scheduling.
    public var activeResponseStreamCount: Int {
        activeResponseStreams.count
    }

    /// Returns all tracked stream priorities (for debugging / testing).
    public var allStreamPriorities: [UInt64: StreamPriority] {
        streamPriorities
    }

    /// Returns all pending priority updates (for debugging / testing).
    public var allPendingPriorityUpdates: [UInt64: StreamPriority] {
        pendingPriorityUpdates
    }
}