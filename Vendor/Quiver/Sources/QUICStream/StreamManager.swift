/// Stream Manager (RFC 9000 Section 2)
///
/// Manages all streams for a QUIC connection.
///
/// ## StreamIdentifier Migration
///
/// This module is being incrementally migrated from raw `UInt64` stream IDs
/// to the type-safe ``StreamIdentifier`` wrapper. During the transition:
/// - Internal storage continues to use `UInt64` keys for compatibility.
/// - New ``StreamIdentifier``-based overloads are provided alongside existing
///   `UInt64`-based methods. Prefer the typed overloads in new code.
/// - Use `.rawValue` at module boundaries where `UInt64` is still expected.

import Foundation
import Logging
import Synchronization
import QUICCore

/// Error types for StreamManager operations
public enum StreamManagerError: Error, Sendable {
    /// Maximum streams limit reached
    case streamLimitReached(bidirectional: Bool)
    /// Stream does not exist
    case streamNotFound(UInt64)
    /// Invalid stream ID for the role
    case invalidStreamID(UInt64)
    /// Stream already exists
    case streamAlreadyExists(UInt64)
    /// Connection-level flow control violated
    case connectionFlowControlViolation
    /// Stream error
    case streamError(StreamError)
}

/// Manages all streams for a QUIC connection
public final class StreamManager: Sendable {
    private static let logger = QuiverLogging.logger(label: "quic.stream.manager")
    private let state: Mutex<StreamManagerState>

    private struct StreamManagerState {
        /// Active streams by ID
        var streams: [UInt64: DataStream]

        /// Flow controller
        var flowController: FlowController

        /// Stream scheduler for priority-based scheduling
        var scheduler: StreamScheduler

        /// Next local bidirectional stream index
        var nextLocalBidiStreamIndex: UInt64

        /// Next local unidirectional stream index
        var nextLocalUniStreamIndex: UInt64

        /// Whether this endpoint is a client
        let isClient: Bool

        /// Initial send limit for locally-initiated bidirectional streams
        var initialSendMaxDataBidiLocal: UInt64

        /// Initial send limit for remotely-initiated bidirectional streams
        var initialSendMaxDataBidiRemote: UInt64

        /// Initial send limit for unidirectional streams
        var initialSendMaxDataUni: UInt64

        /// Maximum buffer size per stream
        let maxBufferSize: UInt64
    }

    /// Creates a new StreamManager
    /// - Parameters:
    ///   - isClient: Whether this endpoint is a client
    ///   - initialMaxData: Initial connection-level receive limit
    ///   - initialMaxStreamDataBidiLocal: Initial receive limit for local bidi streams
    ///   - initialMaxStreamDataBidiRemote: Initial receive limit for remote bidi streams
    ///   - initialMaxStreamDataUni: Initial receive limit for uni streams
    ///   - initialMaxStreamsBidi: Initial bidirectional stream limit
    ///   - initialMaxStreamsUni: Initial unidirectional stream limit
    ///   - peerInitialMaxData: Peer's initial MAX_DATA (our send limit)
    ///   - peerInitialMaxStreamDataBidiLocal: Peer's initial limit for their local bidi
    ///   - peerInitialMaxStreamDataBidiRemote: Peer's initial limit for their remote bidi
    ///   - peerInitialMaxStreamDataUni: Peer's initial limit for uni
    ///   - peerInitialMaxStreamsBidi: Peer's initial MAX_STREAMS_BIDI
    ///   - peerInitialMaxStreamsUni: Peer's initial MAX_STREAMS_UNI
    ///   - maxBufferSize: Maximum buffer size per stream
    public init(
        isClient: Bool,
        initialMaxData: UInt64 = 1024 * 1024,
        initialMaxStreamDataBidiLocal: UInt64 = 256 * 1024,
        initialMaxStreamDataBidiRemote: UInt64 = 256 * 1024,
        initialMaxStreamDataUni: UInt64 = 256 * 1024,
        initialMaxStreamsBidi: UInt64 = 100,
        initialMaxStreamsUni: UInt64 = 100,
        peerInitialMaxData: UInt64 = 0,
        peerInitialMaxStreamDataBidiLocal: UInt64 = 0,
        peerInitialMaxStreamDataBidiRemote: UInt64 = 0,
        peerInitialMaxStreamDataUni: UInt64 = 0,
        peerInitialMaxStreamsBidi: UInt64 = 0,
        peerInitialMaxStreamsUni: UInt64 = 0,
        maxBufferSize: UInt64 = 16 * 1024 * 1024
    ) {
        let flowController = FlowController(
            isClient: isClient,
            initialMaxData: initialMaxData,
            initialMaxStreamDataBidiLocal: initialMaxStreamDataBidiLocal,
            initialMaxStreamDataBidiRemote: initialMaxStreamDataBidiRemote,
            initialMaxStreamDataUni: initialMaxStreamDataUni,
            initialMaxStreamsBidi: initialMaxStreamsBidi,
            initialMaxStreamsUni: initialMaxStreamsUni,
            peerMaxData: peerInitialMaxData,
            peerMaxStreamsBidi: peerInitialMaxStreamsBidi,
            peerMaxStreamsUni: peerInitialMaxStreamsUni
        )

        self.state = Mutex(StreamManagerState(
            streams: [:],
            flowController: flowController,
            scheduler: StreamScheduler(),
            nextLocalBidiStreamIndex: 0,
            nextLocalUniStreamIndex: 0,
            isClient: isClient,
            initialSendMaxDataBidiLocal: peerInitialMaxStreamDataBidiLocal,
            initialSendMaxDataBidiRemote: peerInitialMaxStreamDataBidiRemote,
            initialSendMaxDataUni: peerInitialMaxStreamDataUni,
            maxBufferSize: maxBufferSize
        ))
    }

    // MARK: - Stream Lifecycle

    /// Open a new locally-initiated stream (type-safe variant).
    /// - Parameters:
    ///   - bidirectional: Whether to create a bidirectional stream
    ///   - priority: Initial stream priority (default: .default)
    /// - Returns: The new stream identifier
    /// - Throws: StreamManagerError if stream limit reached
    public func openTypedStream(bidirectional: Bool, priority: StreamPriority = .default) throws -> StreamIdentifier {
        let rawID = try openStream(bidirectional: bidirectional, priority: priority)
        return StreamIdentifier(rawValue: rawID)
    }

    /// Open a new locally-initiated stream
    /// - Parameters:
    ///   - bidirectional: Whether to create a bidirectional stream
    ///   - priority: Initial stream priority (default: .default)
    /// - Returns: The new stream ID
    /// - Throws: StreamManagerError if stream limit reached
    public func openStream(bidirectional: Bool, priority: StreamPriority = .default) throws -> UInt64 {
        try state.withLock { state in
            // Check stream limit
            guard state.flowController.canOpenStream(bidirectional: bidirectional) else {
                throw StreamManagerError.streamLimitReached(bidirectional: bidirectional)
            }

            // Generate stream ID
            let streamID: UInt64
            if bidirectional {
                streamID = StreamID.make(
                    index: state.nextLocalBidiStreamIndex,
                    isClient: state.isClient,
                    isBidirectional: true
                )
                state.nextLocalBidiStreamIndex += 1
            } else {
                streamID = StreamID.make(
                    index: state.nextLocalUniStreamIndex,
                    isClient: state.isClient,
                    isBidirectional: false
                )
                state.nextLocalUniStreamIndex += 1
            }

            // Create stream
            let sendLimit = getSendLimit(for: streamID, state: state)
            let recvLimit = getRecvLimit(for: streamID, state: state)

            Self.logger.debug("Opening stream \(streamID): sendLimit=\(sendLimit), recvLimit=\(recvLimit)")

            let stream = DataStream(
                id: streamID,
                isClient: state.isClient,
                initialSendMaxData: sendLimit,
                initialRecvMaxData: recvLimit,
                maxBufferSize: state.maxBufferSize,
                priority: priority
            )

            state.streams[streamID] = stream
            state.flowController.recordLocalStreamOpened(bidirectional: bidirectional)
            state.flowController.initializeStream(streamID)

            return streamID
        }
    }

    /// Get or create a stream for incoming data
    /// - Parameter streamID: The stream ID from the received frame
    /// - Returns: The stream ID (same as input)
    /// - Throws: StreamManagerError on validation failures
    public func getOrCreateStream(id streamID: UInt64) throws -> UInt64 {
        try state.withLock { state in
            // If stream exists, return it
            if state.streams[streamID] != nil {
                return streamID
            }

            // Validate stream ID
            let isRemotelyInitiated = isRemoteStream(streamID, isClient: state.isClient)
            guard isRemotelyInitiated else {
                throw StreamManagerError.invalidStreamID(streamID)
            }

            let isBidi = StreamID.isBidirectional(streamID)

            // Check if peer can open more streams
            guard state.flowController.canAcceptRemoteStream(bidirectional: isBidi) else {
                throw StreamManagerError.streamLimitReached(bidirectional: isBidi)
            }

            // Create stream
            let sendLimit = getSendLimit(for: streamID, state: state)
            let recvLimit = getRecvLimit(for: streamID, state: state)

            let stream = DataStream(
                id: streamID,
                isClient: state.isClient,
                initialSendMaxData: sendLimit,
                initialRecvMaxData: recvLimit,
                maxBufferSize: state.maxBufferSize
            )

            state.streams[streamID] = stream
            state.flowController.recordRemoteStreamOpened(bidirectional: isBidi)
            state.flowController.initializeStream(streamID)

            return streamID
        }
    }

    /// Check if a stream exists
    /// - Parameter streamID: The stream ID to check
    /// - Returns: True if the stream exists
    public func hasStream(id streamID: UInt64) -> Bool {
        state.withLock { $0.streams[streamID] != nil }
    }

    /// Close a stream
    /// - Parameter streamID: Stream to close
    public func closeStream(id streamID: UInt64) {
        state.withLock { state in
            guard let stream = state.streams.removeValue(forKey: streamID) else {
                return
            }

            let isBidi = stream.isBidirectional
            let isLocal = stream.isLocallyInitiated

            if isLocal {
                state.flowController.recordLocalStreamClosed(bidirectional: isBidi)
            } else {
                state.flowController.recordRemoteStreamClosed(bidirectional: isBidi)
            }

            state.flowController.removeStream(streamID)
        }
    }

    /// Close all streams (for connection close)
    /// - Parameter errorCode: Optional error code for RESET_STREAM frames
    /// - Returns: Array of RESET_STREAM frames to send for active streams
    public func closeAllStreams(errorCode: UInt64? = nil) -> [ResetStreamFrame] {
        state.withLock { state in
            var resetFrames: [ResetStreamFrame] = []

            // Generate RESET_STREAM for streams that can still send
            if let code = errorCode {
                for (_, stream) in state.streams {
                    if let frame = stream.generateResetStream(errorCode: code) {
                        resetFrames.append(frame)
                    }
                }
            }

            // Clear all streams
            state.streams.removeAll()

            // Reset flow controller stream tracking
            // Note: Connection-level counters remain for any final frames
            for streamID in state.flowController.trackedStreamIDs {
                state.flowController.removeStream(streamID)
            }

            return resetFrames
        }
    }

    // MARK: - Frame Processing

    /// Process incoming STREAM frame
    /// - Parameter frame: The received STREAM frame
    /// - Throws: StreamManagerError on validation failures
    public func receive(frame: StreamFrame) throws {
        try state.withLock { state in
            // Get or create stream
            if state.streams[frame.streamID] == nil {
                _ = try getOrCreateStreamInternal(frame.streamID, state: &state)
            }

            guard let stream = state.streams[frame.streamID] else {
                throw StreamManagerError.streamNotFound(frame.streamID)
            }

            // Calculate end offset for flow control
            let endOffset = frame.offset + UInt64(frame.data.count)

            // Calculate new bytes (not previously counted) for connection-level flow control
            // This correctly handles out-of-order data by counting only the actual new bytes,
            // not the gap. For example:
            //   - currentHighest = 0, frame offset = 100, length = 50
            //   - newBytes = max(0, 150 - max(0, 100)) = 50 (not 150!)
            let currentHighest = state.flowController.streamBytesReceived(for: frame.streamID)
            let newBytes: UInt64
            if endOffset > currentHighest {
                // Only count bytes that extend beyond what we've already counted
                // max(currentHighest, frame.offset) gives the start of the new portion
                newBytes = endOffset - max(currentHighest, frame.offset)
            } else {
                newBytes = 0
            }

            // Check connection-level flow control for new bytes only
            guard state.flowController.canReceive(bytes: newBytes) else {
                throw StreamManagerError.connectionFlowControlViolation
            }

            // Process on stream (DataStream is now a class - no writeback needed)
            do {
                try stream.receive(frame)
            } catch let error as StreamError {
                throw StreamManagerError.streamError(error)
            }

            // Record only new bytes at connection level (avoids double-counting retransmissions)
            let actualNewBytes = state.flowController.recordStreamBytesReceived(frame.streamID, endOffset: endOffset)
            if actualNewBytes > 0 {
                state.flowController.recordBytesReceived(actualNewBytes)
            }
        }
    }

    /// Process RESET_STREAM frame
    /// - Parameter frame: The received RESET_STREAM frame
    public func handleResetStream(_ frame: ResetStreamFrame) throws {
        try state.withLock { state in
            let stream: DataStream
            if let existing = state.streams[frame.streamID] {
                stream = existing
            } else {
                // Create stream if it doesn't exist (peer may have sent RESET before data)
                _ = try getOrCreateStreamInternal(frame.streamID, state: &state)
                guard let newStream = state.streams[frame.streamID] else { return }
                stream = newStream
            }

            // DataStream validates final size against stream-level flow control
            try stream.handleResetStream(errorCode: frame.applicationErrorCode, finalSize: frame.finalSize)

            // Update connection-level flow control with final size
            // Count any new bytes up to the final size
            let currentHighest = state.flowController.streamBytesReceived(for: frame.streamID)
            if frame.finalSize > currentHighest {
                let newBytes = frame.finalSize - currentHighest
                state.flowController.recordBytesReceived(newBytes)
                state.flowController.recordStreamBytesReceived(frame.streamID, endOffset: frame.finalSize)
            }
        }
    }

    /// Process STOP_SENDING frame
    /// - Parameter frame: The received STOP_SENDING frame
    public func handleStopSending(_ frame: StopSendingFrame) {
        state.withLock { state in
            guard let stream = state.streams[frame.streamID] else { return }
            stream.handleStopSending(errorCode: frame.applicationErrorCode)
        }
    }

    /// Process MAX_STREAM_DATA frame
    /// - Parameter frame: The received MAX_STREAM_DATA frame
    public func handleMaxStreamData(_ frame: MaxStreamDataFrame) {
        state.withLock { state in
            guard let stream = state.streams[frame.streamID] else { return }
            stream.updateSendMaxData(frame.maxStreamData)
        }
    }

    /// Process MAX_DATA frame
    /// - Parameter frame: The received MAX_DATA frame
    public func handleMaxData(_ frame: MaxDataFrame) {
        state.withLock { state in
            state.flowController.updateConnectionSendLimit(frame.maxData)
        }
    }

    /// Process MAX_STREAMS frame
    /// - Parameter frame: The received MAX_STREAMS frame
    public func handleMaxStreams(_ frame: MaxStreamsFrame) {
        state.withLock { state in
            state.flowController.updateRemoteStreamLimit(frame.maxStreams, bidirectional: frame.isBidirectional)
        }
    }

    /// Update peer's initial stream data limits (called when peer transport parameters are received)
    /// - Parameters:
    ///   - bidiLocal: Peer's initial_max_stream_data_bidi_local (our send limit for streams we open)
    ///   - bidiRemote: Peer's initial_max_stream_data_bidi_remote (our send limit for streams peer opens)
    ///   - uni: Peer's initial_max_stream_data_uni (our send limit for uni streams)
    public func updatePeerStreamDataLimits(
        bidiLocal: UInt64,
        bidiRemote: UInt64,
        uni: UInt64
    ) {
        state.withLock { state in
            Self.logger.debug("Updating peer stream data limits: bidiLocal=\(bidiLocal), bidiRemote=\(bidiRemote), uni=\(uni)")
            Self.logger.debug("Existing streams before update: \(state.streams.keys.sorted())")
            // Update initial values for new streams
            state.initialSendMaxDataBidiLocal = bidiLocal
            state.initialSendMaxDataBidiRemote = bidiRemote
            state.initialSendMaxDataUni = uni

            // Update existing streams' send limits
            // This is critical for streams opened before handshake completion
            for (streamID, stream) in state.streams {
                let newLimit = getSendLimit(for: streamID, state: state)
                Self.logger.debug("Updating stream \(streamID) send limit to \(newLimit)")
                stream.updateSendMaxData(newLimit)
            }
        }
    }

    // MARK: - Data Access

    /// Read data from a stream
    /// - Parameter streamID: Stream to read from
    /// - Returns: Available data, or nil if none
    public func read(streamID: UInt64) -> Data? {
        state.withLock { state in
            guard let stream = state.streams[streamID] else { return nil }
            return stream.read()
        }
    }

    /// Write data to a stream
    /// - Parameters:
    ///   - streamID: Stream to write to
    ///   - data: Data to write
    /// - Throws: StreamManagerError on failures
    public func write(streamID: UInt64, data: Data) throws {
        try state.withLock { state in
            guard let stream = state.streams[streamID] else {
                throw StreamManagerError.streamNotFound(streamID)
            }

            do {
                try stream.write(data)
            } catch let error as StreamError {
                throw StreamManagerError.streamError(error)
            }
        }
    }

    /// Finish writing to a stream (send FIN)
    /// - Parameter streamID: Stream to finish
    /// - Throws: StreamManagerError on failures
    public func finish(streamID: UInt64) throws {
        try state.withLock { state in
            guard let stream = state.streams[streamID] else {
                throw StreamManagerError.streamNotFound(streamID)
            }

            do {
                try stream.finish()
            } catch let error as StreamError {
                throw StreamManagerError.streamError(error)
            }
        }
    }

    // MARK: - Frame Generation

    /// Generate outgoing STREAM frames
    ///
    /// Streams are scheduled by priority (urgency 0-7, where 0 is highest).
    /// Within the same priority level, fair queuing (round-robin) is used.
    ///
    /// - Parameter maxBytes: Maximum total bytes for frames
    /// - Returns: Array of STREAM frames to send
    public func generateStreamFrames(maxBytes: Int) -> [StreamFrame] {
        state.withLock { state in
            var frames: [StreamFrame] = []
            var remainingBytes = maxBytes

            // Schedule streams by priority with fair queuing
            let orderedStreams = state.scheduler.scheduleStreams(state.streams)

            for (_, stream) in orderedStreams {
                guard stream.hasDataToSend && remainingBytes > 0 else { continue }

                // Check connection-level flow control
                let connectionWindow = state.flowController.connectionSendWindow
                let streamWindow = stream.sendWindow
                let effectiveWindow = min(connectionWindow, streamWindow)

                if effectiveWindow == 0 { continue }

                // Apply both connection and stream window limits
                let maxBytesToSend = min(remainingBytes, Int(effectiveWindow))
                let streamFrames = stream.generateFrames(maxBytes: maxBytesToSend)

                for frame in streamFrames {
                    state.flowController.recordBytesSent(UInt64(frame.data.count))
                    // Use accurate frame size calculation instead of fixed approximation
                    let frameSize = FrameSize.streamFrame(
                        streamID: frame.streamID,
                        offset: frame.offset,
                        dataLength: frame.data.count,
                        hasLength: frame.hasLength
                    )
                    remainingBytes -= frameSize
                }

                // Advance cursor for fairness within this priority level
                if !streamFrames.isEmpty {
                    let urgency = stream.priority.urgency
                    let groupSize = orderedStreams.filter { $0.stream.priority.urgency == urgency }.count
                    state.scheduler.advanceCursor(for: urgency, groupSize: groupSize)
                }

                frames.append(contentsOf: streamFrames)
            }

            return frames
        }
    }

    /// Generate flow control frames (MAX_DATA, MAX_STREAM_DATA, MAX_STREAMS)
    /// - Returns: Array of control frames to send
    public func generateFlowControlFrames() -> [Frame] {
        state.withLock { state in
            var frames: [Frame] = []

            // Connection-level MAX_DATA
            if let maxData = state.flowController.generateMaxData() {
                frames.append(.maxData(maxData.maxData))
            }

            // Stream-level MAX_STREAM_DATA
            for streamID in state.streams.keys {
                if let maxStreamData = state.flowController.generateMaxStreamData(for: streamID) {
                    frames.append(.maxStreamData(maxStreamData))

                    // Sync DataStream's receive limit to match FlowController
                    if let stream = state.streams[streamID] {
                        stream.updateRecvMaxData(maxStreamData.maxStreamData)
                    }
                }
            }

            // MAX_STREAMS
            if let maxStreamsBidi = state.flowController.generateMaxStreams(bidirectional: true) {
                frames.append(.maxStreams(maxStreamsBidi))
            }
            if let maxStreamsUni = state.flowController.generateMaxStreams(bidirectional: false) {
                frames.append(.maxStreams(maxStreamsUni))
            }

            return frames
        }
    }

    /// Generate RESET_STREAM frames for streams that need them
    /// This is called to respond to STOP_SENDING frames from peer
    /// - Returns: Array of RESET_STREAM frames to send
    public func generateResetFrames() -> [ResetStreamFrame] {
        state.withLock { state in
            var frames: [ResetStreamFrame] = []

            for (_, stream) in state.streams {
                // Check if this stream received STOP_SENDING and hasn't sent RESET_STREAM yet
                if stream.needsResetStream,
                   let errorCode = stream.stopSendingErrorCode,
                   let frame = stream.generateResetStream(errorCode: errorCode) {
                    frames.append(frame)
                }
            }

            return frames
        }
    }

    // MARK: - Stream Priority

    /// Set stream priority
    /// - Parameters:
    ///   - priority: New priority
    ///   - streamID: Stream to update
    /// - Throws: StreamManagerError if stream not found
    public func setPriority(_ priority: StreamPriority, for streamID: UInt64) throws {
        try state.withLock { state in
            guard let stream = state.streams[streamID] else {
                throw StreamManagerError.streamNotFound(streamID)
            }
            stream.priority = priority
        }
    }

    /// Get stream priority
    /// - Parameter streamID: Stream to query
    /// - Returns: Current priority
    /// - Throws: StreamManagerError if stream not found
    public func priority(for streamID: UInt64) throws -> StreamPriority {
        try state.withLock { state in
            guard let stream = state.streams[streamID] else {
                throw StreamManagerError.streamNotFound(streamID)
            }
            return stream.priority
        }
    }

    // MARK: - Stream Status

    /// Check if stream has data to read
    /// - Parameter streamID: Stream to check
    /// - Returns: true if data available
    public func hasDataToRead(streamID: UInt64) -> Bool {
        state.withLock { state in
            state.streams[streamID]?.hasDataToRead ?? false
        }
    }

    /// Whether the receive side of a stream is complete (FIN received and all data read)
    ///
    /// Returns `true` when the peer has sent FIN and all contiguous data
    /// has been consumed via `read()`.  Callers can use this to detect
    /// end-of-stream without blocking.
    public func isStreamReceiveComplete(streamID: UInt64) -> Bool {
        state.withLock { state in
            guard let stream = state.streams[streamID] else { return false }
            return stream.isReceiveComplete
        }
    }

    /// Whether the stream was reset by the peer (RESET_STREAM received)
    public func isStreamResetByPeer(streamID: UInt64) -> Bool {
        state.withLock { state in
            guard let stream = state.streams[streamID] else { return false }
            return stream.isResetByPeer
        }
    }

    /// Check if stream has data to send
    /// - Parameter streamID: Stream to check
    /// - Returns: true if data pending
    public func hasDataToSend(streamID: UInt64) -> Bool {
        state.withLock { state in
            state.streams[streamID]?.hasDataToSend ?? false
        }
    }

    /// Checks if any stream has data waiting to be sent
    /// - Returns: true if at least one stream has pending data
    public var hasPendingStreamData: Bool {
        state.withLock { state in
            state.streams.values.contains { $0.hasDataToSend }
        }
    }

    /// Get number of active streams
    public var activeStreamCount: Int {
        state.withLock { $0.streams.count }
    }

    /// Get all active stream IDs
    public var activeStreamIDs: [UInt64] {
        state.withLock { Array($0.streams.keys) }
    }

    /// Get all active stream identifiers (type-safe variant).
    public var activeStreamIdentifiers: [StreamIdentifier] {
        state.withLock { $0.streams.keys.map { StreamIdentifier(rawValue: $0) } }
    }

    // MARK: - Private Helpers

    private func isRemoteStream(_ streamID: UInt64, isClient: Bool) -> Bool {
        let isClientInitiated = StreamID.isClientInitiated(streamID)
        return (isClient && !isClientInitiated) || (!isClient && isClientInitiated)
    }

    private func getSendLimit(for streamID: UInt64, state: StreamManagerState) -> UInt64 {
        let isLocal = !isRemoteStream(streamID, isClient: state.isClient)
        let isBidi = StreamID.isBidirectional(streamID)

        if isBidi {
            return isLocal ? state.initialSendMaxDataBidiLocal : state.initialSendMaxDataBidiRemote
        } else {
            return state.initialSendMaxDataUni
        }
    }

    private func getRecvLimit(for streamID: UInt64, state: StreamManagerState) -> UInt64 {
        let isLocal = !isRemoteStream(streamID, isClient: state.isClient)
        let isBidi = StreamID.isBidirectional(streamID)

        if isBidi {
            // For locally-initiated bidi streams, use our local bidi limit
            // For remotely-initiated bidi streams, use our remote bidi limit
            return isLocal
                ? state.flowController.initialMaxStreamDataBidiLocal
                : state.flowController.initialMaxStreamDataBidiRemote
        } else {
            return state.flowController.initialMaxStreamDataUni
        }
    }

    // MARK: - StreamIdentifier Overloads

    /// Check if a stream exists (type-safe variant).
    public func hasStream(streamIdentifier: StreamIdentifier) -> Bool {
        hasStream(id: streamIdentifier.rawValue)
    }

    /// Read data from a stream (type-safe variant).
    public func read(streamIdentifier: StreamIdentifier) -> Data? {
        read(streamID: streamIdentifier.rawValue)
    }

    /// Write data to a stream (type-safe variant).
    public func write(streamIdentifier: StreamIdentifier, data: Data) throws {
        try write(streamID: streamIdentifier.rawValue, data: data)
    }

    /// Finish writing to a stream (type-safe variant).
    public func finish(streamIdentifier: StreamIdentifier) throws {
        try finish(streamID: streamIdentifier.rawValue)
    }

    /// Close a stream (type-safe variant).
    public func closeStream(streamIdentifier: StreamIdentifier) {
        closeStream(id: streamIdentifier.rawValue)
    }

    /// Set priority for a stream (type-safe variant).
    public func setPriority(_ priority: StreamPriority, forStream streamIdentifier: StreamIdentifier) throws {
        try setPriority(priority, for: streamIdentifier.rawValue)
    }

    /// Get priority for a stream (type-safe variant).
    public func priority(forStream streamIdentifier: StreamIdentifier) throws -> StreamPriority {
        try priority(for: streamIdentifier.rawValue)
    }

    /// Get or create a stream (type-safe variant).
    public func getOrCreateStream(streamIdentifier: StreamIdentifier) throws -> StreamIdentifier {
        let rawID = try getOrCreateStream(id: streamIdentifier.rawValue)
        return StreamIdentifier(rawValue: rawID)
    }

    // MARK: - Internal Helpers

    private func getOrCreateStreamInternal(_ streamID: UInt64, state: inout StreamManagerState) throws -> UInt64 {
        if state.streams[streamID] != nil {
            return streamID
        }

        let isRemotelyInitiated = isRemoteStream(streamID, isClient: state.isClient)
        guard isRemotelyInitiated else {
            throw StreamManagerError.invalidStreamID(streamID)
        }

        let isBidi = StreamID.isBidirectional(streamID)

        guard state.flowController.canAcceptRemoteStream(bidirectional: isBidi) else {
            throw StreamManagerError.streamLimitReached(bidirectional: isBidi)
        }

        let sendLimit = getSendLimit(for: streamID, state: state)
        let recvLimit = getRecvLimit(for: streamID, state: state)

        let stream = DataStream(
            id: streamID,
            isClient: state.isClient,
            initialSendMaxData: sendLimit,
            initialRecvMaxData: recvLimit,
            maxBufferSize: state.maxBufferSize
        )

        state.streams[streamID] = stream
        state.flowController.recordRemoteStreamOpened(bidirectional: isBidi)
        state.flowController.initializeStream(streamID)

        return streamID
    }
}
