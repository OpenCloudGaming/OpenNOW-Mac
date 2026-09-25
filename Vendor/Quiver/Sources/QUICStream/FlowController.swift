/// Flow Controller (RFC 9000 Section 4)
///
/// Manages connection-level and stream-level flow control.

import Foundation
import QUICCore

/// Connection and stream-level flow control
///
/// QUIC uses credit-based flow control similar to HTTP/2.
/// The receiver advertises the maximum amount of data the sender can send.
package struct FlowController: Sendable {
    // MARK: - Role

    /// Whether this endpoint is the client
    private let isClient: Bool

    // MARK: - Connection-Level Receive Side

    /// Total bytes received across all streams
    private(set) var connectionBytesReceived: UInt64

    /// Maximum bytes we allow peer to send (our receive window)
    private(set) var connectionRecvLimit: UInt64

    /// Initial connection receive limit (for calculating when to send MAX_DATA)
    private let initialConnectionRecvLimit: UInt64

    /// Threshold for sending MAX_DATA (percentage of window consumed)
    private let autoUpdateThreshold: Double

    // MARK: - Connection-Level Send Side

    /// Total bytes sent across all streams
    private(set) var connectionBytesSent: UInt64

    /// Maximum bytes peer allows us to send (peer's receive window)
    private(set) var connectionSendLimit: UInt64

    /// Whether we're currently blocked on connection-level flow control
    private(set) var connectionBlocked: Bool

    // MARK: - Stream Limits

    /// Maximum bidirectional streams we allow peer to open
    private(set) var maxLocalBidiStreams: UInt64

    /// Maximum unidirectional streams we allow peer to open
    private(set) var maxLocalUniStreams: UInt64

    /// Maximum bidirectional streams peer allows us to open
    private(set) var maxRemoteBidiStreams: UInt64

    /// Maximum unidirectional streams peer allows us to open
    private(set) var maxRemoteUniStreams: UInt64

    /// Current count of locally-opened bidirectional streams
    private(set) var openLocalBidiStreams: UInt64

    /// Current count of locally-opened unidirectional streams
    private(set) var openLocalUniStreams: UInt64

    /// Current count of remotely-opened bidirectional streams
    private(set) var openRemoteBidiStreams: UInt64

    /// Current count of remotely-opened unidirectional streams
    private(set) var openRemoteUniStreams: UInt64

    /// Initial stream data limit for locally-initiated bidirectional streams
    package let initialMaxStreamDataBidiLocal: UInt64

    /// Initial stream data limit for remotely-initiated bidirectional streams
    package let initialMaxStreamDataBidiRemote: UInt64

    /// Initial stream data limit for unidirectional streams
    package let initialMaxStreamDataUni: UInt64

    /// Per-stream receive limits (stream ID -> current limit)
    private var streamRecvLimits: [UInt64: UInt64]

    /// Per-stream bytes received (stream ID -> bytes received)
    private var streamBytesReceived: [UInt64: UInt64]

    // MARK: - Initialization

    /// Creates a new FlowController
    /// - Parameters:
    ///   - isClient: Whether this endpoint is the client
    ///   - initialMaxData: Initial connection-level receive limit
    ///   - initialMaxStreamDataBidiLocal: Initial limit for local bidi streams
    ///   - initialMaxStreamDataBidiRemote: Initial limit for remote bidi streams
    ///   - initialMaxStreamDataUni: Initial limit for unidirectional streams
    ///   - initialMaxStreamsBidi: Initial bidirectional stream limit
    ///   - initialMaxStreamsUni: Initial unidirectional stream limit
    ///   - peerMaxData: Peer's initial MAX_DATA
    ///   - peerMaxStreamsBidi: Peer's initial MAX_STREAMS_BIDI
    ///   - peerMaxStreamsUni: Peer's initial MAX_STREAMS_UNI
    ///   - autoUpdateThreshold: Threshold for auto-sending MAX_DATA (0.0-1.0)
    package init(
        isClient: Bool,
        initialMaxData: UInt64 = 1024 * 1024,  // 1MB default
        initialMaxStreamDataBidiLocal: UInt64 = 256 * 1024,  // 256KB
        initialMaxStreamDataBidiRemote: UInt64 = 256 * 1024,
        initialMaxStreamDataUni: UInt64 = 256 * 1024,
        initialMaxStreamsBidi: UInt64 = 100,
        initialMaxStreamsUni: UInt64 = 100,
        peerMaxData: UInt64 = 0,
        peerMaxStreamsBidi: UInt64 = 0,
        peerMaxStreamsUni: UInt64 = 0,
        autoUpdateThreshold: Double = 0.5
    ) {
        self.isClient = isClient
        self.connectionBytesReceived = 0
        self.connectionRecvLimit = initialMaxData
        self.initialConnectionRecvLimit = initialMaxData
        self.autoUpdateThreshold = autoUpdateThreshold

        self.connectionBytesSent = 0
        self.connectionSendLimit = peerMaxData
        self.connectionBlocked = false

        self.maxLocalBidiStreams = initialMaxStreamsBidi
        self.maxLocalUniStreams = initialMaxStreamsUni
        self.maxRemoteBidiStreams = peerMaxStreamsBidi
        self.maxRemoteUniStreams = peerMaxStreamsUni

        self.openLocalBidiStreams = 0
        self.openLocalUniStreams = 0
        self.openRemoteBidiStreams = 0
        self.openRemoteUniStreams = 0

        self.initialMaxStreamDataBidiLocal = initialMaxStreamDataBidiLocal
        self.initialMaxStreamDataBidiRemote = initialMaxStreamDataBidiRemote
        self.initialMaxStreamDataUni = initialMaxStreamDataUni

        self.streamRecvLimits = [:]
        self.streamBytesReceived = [:]
    }

    // MARK: - Connection-Level Flow Control

    /// Check if we can receive more data on the connection
    /// - Parameter bytes: Number of bytes to receive
    /// - Returns: true if within receive limit
    package func canReceive(bytes: UInt64) -> Bool {
        // Use saturating arithmetic to prevent overflow
        let (total, overflow) = connectionBytesReceived.addingReportingOverflow(bytes)
        if overflow { return false }
        return total <= connectionRecvLimit
    }

    /// Record bytes received on the connection
    /// - Parameter bytes: Number of bytes received
    package mutating func recordBytesReceived(_ bytes: UInt64) {
        // Use saturating addition to prevent overflow
        let (total, overflow) = connectionBytesReceived.addingReportingOverflow(bytes)
        connectionBytesReceived = overflow ? UInt64.max : total
    }

    /// Check if we can send more data on the connection
    /// - Parameter bytes: Number of bytes to send
    /// - Returns: true if within send limit
    package func canSend(bytes: UInt64) -> Bool {
        // Use saturating arithmetic to prevent overflow
        let (total, overflow) = connectionBytesSent.addingReportingOverflow(bytes)
        if overflow { return false }
        return total <= connectionSendLimit
    }

    /// Record bytes sent on the connection
    /// - Parameter bytes: Number of bytes sent
    package mutating func recordBytesSent(_ bytes: UInt64) {
        // Use saturating addition to prevent overflow
        let (total, overflow) = connectionBytesSent.addingReportingOverflow(bytes)
        connectionBytesSent = overflow ? UInt64.max : total
        if connectionBytesSent >= connectionSendLimit {
            connectionBlocked = true
        }
    }

    /// Available connection-level send window
    package var connectionSendWindow: UInt64 {
        guard connectionSendLimit > connectionBytesSent else { return 0 }
        return connectionSendLimit - connectionBytesSent
    }

    /// Update connection send limit (from peer's MAX_DATA)
    /// - Parameter maxData: New maximum data limit
    package mutating func updateConnectionSendLimit(_ maxData: UInt64) {
        if maxData > connectionSendLimit {
            connectionSendLimit = maxData
            connectionBlocked = false
        }
    }

    /// Generate MAX_DATA frame if needed
    /// - Returns: MAX_DATA frame if window update needed, nil otherwise
    package mutating func generateMaxData() -> MaxDataFrame? {
        // Calculate remaining window (with underflow protection)
        guard connectionRecvLimit >= connectionBytesReceived else {
            // Already exceeded limit - shouldn't happen but protect against it
            return nil
        }
        let remaining = connectionRecvLimit - connectionBytesReceived
        let threshold = UInt64(Double(initialConnectionRecvLimit) * autoUpdateThreshold)

        // Send MAX_DATA if remaining window is below threshold
        if remaining < threshold {
            // Increase limit by initial amount (with overflow protection)
            let (newLimit, overflow) = connectionRecvLimit.addingReportingOverflow(initialConnectionRecvLimit)
            connectionRecvLimit = overflow ? UInt64.max : newLimit
            return MaxDataFrame(maxData: connectionRecvLimit)
        }

        return nil
    }

    /// Generate DATA_BLOCKED frame if needed
    /// - Returns: DATA_BLOCKED frame if blocked, nil otherwise
    package func generateDataBlocked() -> DataBlockedFrame? {
        if connectionBlocked {
            return DataBlockedFrame(dataLimit: connectionSendLimit)
        }
        return nil
    }

    // MARK: - Stream-Level Flow Control

    /// Check if we can receive data on a stream
    /// - Parameters:
    ///   - streamID: Stream identifier
    ///   - bytes: Number of bytes
    ///   - endOffset: Ending byte offset (offset + length)
    /// - Returns: true if within stream limit
    package func canReceiveOnStream(_ streamID: UInt64, endOffset: UInt64) -> Bool {
        guard let limit = streamRecvLimits[streamID] else {
            // New stream - check against initial limit
            return endOffset <= getInitialStreamLimit(for: streamID)
        }
        return endOffset <= limit
    }

    /// Get the highest offset received on a stream
    /// - Parameter streamID: Stream identifier
    /// - Returns: The highest byte offset received, or 0 if no data received
    package func streamBytesReceived(for streamID: UInt64) -> UInt64 {
        streamBytesReceived[streamID] ?? 0
    }

    /// Record bytes received on a stream
    /// - Parameters:
    ///   - streamID: Stream identifier
    ///   - endOffset: The ending offset of the received data
    /// - Returns: The number of NEW bytes (not previously counted for flow control)
    @discardableResult
    package mutating func recordStreamBytesReceived(_ streamID: UInt64, endOffset: UInt64) -> UInt64 {
        let current = streamBytesReceived[streamID] ?? 0
        if endOffset > current {
            let newBytes = endOffset - current
            streamBytesReceived[streamID] = endOffset
            return newBytes
        }
        return 0
    }

    /// Initialize stream flow control
    /// - Parameter streamID: Stream identifier
    package mutating func initializeStream(_ streamID: UInt64) {
        if streamRecvLimits[streamID] == nil {
            streamRecvLimits[streamID] = getInitialStreamLimit(for: streamID)
            streamBytesReceived[streamID] = 0
        }
    }

    /// Get initial stream limit based on stream type and initiator
    ///
    /// For bidirectional streams, the limit depends on whether we initiated the stream:
    /// - Local stream (we initiated): use `initialMaxStreamDataBidiLocal`
    /// - Remote stream (peer initiated): use `initialMaxStreamDataBidiRemote`
    private func getInitialStreamLimit(for streamID: UInt64) -> UInt64 {
        if StreamID.isUnidirectional(streamID) {
            return initialMaxStreamDataUni
        } else {
            // Determine if this is a locally-initiated stream
            let isClientInitiated = StreamID.isClientInitiated(streamID)
            let isLocal = (isClient && isClientInitiated) || (!isClient && !isClientInitiated)
            return isLocal ? initialMaxStreamDataBidiLocal : initialMaxStreamDataBidiRemote
        }
    }

    /// Update stream receive limit
    /// - Parameters:
    ///   - streamID: Stream identifier
    ///   - maxData: New maximum data limit
    package mutating func updateStreamRecvLimit(_ streamID: UInt64, maxData: UInt64) {
        let current = streamRecvLimits[streamID] ?? 0
        if maxData > current {
            streamRecvLimits[streamID] = maxData
        }
    }

    /// Generate MAX_STREAM_DATA frame if needed for a stream
    /// - Parameter streamID: Stream identifier
    /// - Returns: MAX_STREAM_DATA frame if window update needed
    package mutating func generateMaxStreamData(for streamID: UInt64) -> MaxStreamDataFrame? {
        guard let limit = streamRecvLimits[streamID],
              let received = streamBytesReceived[streamID] else {
            return nil
        }

        // Underflow protection
        guard limit >= received else { return nil }
        let remaining = limit - received
        let initialLimit = getInitialStreamLimit(for: streamID)
        let threshold = UInt64(Double(initialLimit) * autoUpdateThreshold)

        if remaining < threshold {
            // Overflow protection
            let (newLimit, overflow) = limit.addingReportingOverflow(initialLimit)
            let safeLimit = overflow ? UInt64.max : newLimit
            streamRecvLimits[streamID] = safeLimit
            return MaxStreamDataFrame(streamID: streamID, maxStreamData: safeLimit)
        }

        return nil
    }

    /// Remove stream from tracking (when closed)
    /// - Parameter streamID: Stream identifier
    package mutating func removeStream(_ streamID: UInt64) {
        streamRecvLimits.removeValue(forKey: streamID)
        streamBytesReceived.removeValue(forKey: streamID)
    }

    /// Get all tracked stream IDs (for cleanup on connection close)
    package var trackedStreamIDs: [UInt64] {
        Array(streamRecvLimits.keys)
    }

    // MARK: - Stream Concurrency

    /// Check if we can open a new locally-initiated stream
    /// - Parameter bidirectional: Whether bidirectional
    /// - Returns: true if allowed
    package func canOpenStream(bidirectional: Bool) -> Bool {
        if bidirectional {
            return openLocalBidiStreams < maxRemoteBidiStreams
        } else {
            return openLocalUniStreams < maxRemoteUniStreams
        }
    }

    /// Record opening a local stream
    /// - Parameter bidirectional: Whether bidirectional
    package mutating func recordLocalStreamOpened(bidirectional: Bool) {
        if bidirectional {
            openLocalBidiStreams += 1
        } else {
            openLocalUniStreams += 1
        }
    }

    /// Record closing a local stream
    /// - Parameter bidirectional: Whether bidirectional
    package mutating func recordLocalStreamClosed(bidirectional: Bool) {
        if bidirectional {
            if openLocalBidiStreams > 0 { openLocalBidiStreams -= 1 }
        } else {
            if openLocalUniStreams > 0 { openLocalUniStreams -= 1 }
        }
    }

    /// Check if peer can open a new stream
    /// - Parameter bidirectional: Whether bidirectional
    /// - Returns: true if allowed
    package func canAcceptRemoteStream(bidirectional: Bool) -> Bool {
        if bidirectional {
            return openRemoteBidiStreams < maxLocalBidiStreams
        } else {
            return openRemoteUniStreams < maxLocalUniStreams
        }
    }

    /// Record opening a remote stream
    /// - Parameter bidirectional: Whether bidirectional
    package mutating func recordRemoteStreamOpened(bidirectional: Bool) {
        if bidirectional {
            openRemoteBidiStreams += 1
        } else {
            openRemoteUniStreams += 1
        }
    }

    /// Record closing a remote stream
    /// - Parameter bidirectional: Whether bidirectional
    package mutating func recordRemoteStreamClosed(bidirectional: Bool) {
        if bidirectional {
            if openRemoteBidiStreams > 0 { openRemoteBidiStreams -= 1 }
        } else {
            if openRemoteUniStreams > 0 { openRemoteUniStreams -= 1 }
        }
    }

    /// Update remote stream limit (from peer's MAX_STREAMS)
    /// - Parameters:
    ///   - maxStreams: New maximum
    ///   - bidirectional: Whether for bidirectional streams
    package mutating func updateRemoteStreamLimit(_ maxStreams: UInt64, bidirectional: Bool) {
        if bidirectional {
            if maxStreams > maxRemoteBidiStreams {
                maxRemoteBidiStreams = maxStreams
            }
        } else {
            if maxStreams > maxRemoteUniStreams {
                maxRemoteUniStreams = maxStreams
            }
        }
    }

    /// Generate MAX_STREAMS frame if needed
    /// - Parameter bidirectional: Whether for bidirectional streams
    /// - Returns: MAX_STREAMS frame if update needed
    package mutating func generateMaxStreams(bidirectional: Bool) -> MaxStreamsFrame? {
        // Simple auto-increase: when 50% of streams are used, increase limit
        if bidirectional {
            // Skip auto-increase if streams are disabled (limit = 0)
            guard maxLocalBidiStreams > 0 else { return nil }
            let threshold = maxLocalBidiStreams / 2
            if openRemoteBidiStreams >= threshold {
                // Overflow protection
                let (newLimit, overflow) = maxLocalBidiStreams.addingReportingOverflow(10)
                maxLocalBidiStreams = overflow ? UInt64.max : newLimit
                return MaxStreamsFrame(maxStreams: maxLocalBidiStreams, isBidirectional: true)
            }
        } else {
            // Skip auto-increase if streams are disabled (limit = 0)
            guard maxLocalUniStreams > 0 else { return nil }
            let threshold = maxLocalUniStreams / 2
            if openRemoteUniStreams >= threshold {
                // Overflow protection
                let (newLimit, overflow) = maxLocalUniStreams.addingReportingOverflow(10)
                maxLocalUniStreams = overflow ? UInt64.max : newLimit
                return MaxStreamsFrame(maxStreams: maxLocalUniStreams, isBidirectional: false)
            }
        }
        return nil
    }

    /// Generate STREAMS_BLOCKED frame if blocked
    /// - Parameter bidirectional: Whether for bidirectional streams
    /// - Returns: STREAMS_BLOCKED frame if blocked
    package func generateStreamsBlocked(bidirectional: Bool) -> StreamsBlockedFrame? {
        if bidirectional {
            if openLocalBidiStreams >= maxRemoteBidiStreams {
                return StreamsBlockedFrame(streamLimit: maxRemoteBidiStreams, isBidirectional: true)
            }
        } else {
            if openLocalUniStreams >= maxRemoteUniStreams {
                return StreamsBlockedFrame(streamLimit: maxRemoteUniStreams, isBidirectional: false)
            }
        }
        return nil
    }
}
