/// Data Stream (RFC 9000 Section 2-3)
///
/// Manages a single QUIC stream with send/receive buffers and state tracking.

import Foundation
import Logging
import Synchronization
import QUICCore

/// Error types for DataStream operations
public enum StreamError: Error, Sendable {
    /// Stream is in an invalid state for the operation
    case invalidState(current: String, operation: String)
    /// Flow control violation
    case flowControlViolation(limit: UInt64, requested: UInt64)
    /// Stream has been reset
    case streamReset(errorCode: UInt64)
    /// Cannot send on receive-only stream
    case cannotSendOnReceiveOnlyStream
    /// Cannot receive on send-only stream
    case cannotReceiveOnSendOnlyStream
    /// Data buffer error
    case bufferError(DataBufferError)
    /// Final size mismatch
    case finalSizeMismatch(expected: UInt64, received: UInt64)
    /// Stream ID mismatch (internal error)
    case streamIDMismatch(expected: UInt64, received: UInt64)
}

/// Internal state for DataStream (protected by Mutex)
private struct DataStreamInternalState: Sendable {
    /// Stream state machine
    var state: StreamState

    /// Receive buffer (incoming data reassembly)
    var recvBuffer: DataBuffer

    /// Send buffer (outgoing data queue)
    var sendBuffer: Data

    /// Bytes consumed from the front of sendBuffer (lazy compaction)
    var sendBufferConsumed: Int

    /// Offset of first unconsumed byte in the stream
    var sendBufferOffset: UInt64

    /// Whether FIN has been queued for sending
    var finQueued: Bool

    /// Whether we received STOP_SENDING from peer
    var stopSendingReceived: Bool

    /// Error code if STOP_SENDING received
    var stopSendingErrorCode: UInt64?

    /// Whether we sent RESET_STREAM
    var resetStreamSent: Bool

    /// Error code if we sent RESET_STREAM
    var resetStreamErrorCode: UInt64?

    /// Whether we received RESET_STREAM from peer
    var resetStreamReceived: Bool

    /// Error code if peer sent RESET_STREAM
    var peerResetErrorCode: UInt64?

    /// Stream priority for scheduling
    var priority: StreamPriority
}

/// A single QUIC stream with send/receive buffers
///
/// Bidirectional streams have both send and receive sides.
/// Unidirectional streams have only one side active.
public final class DataStream: Sendable {
    private static let logger = QuiverLogging.logger(label: "quic.stream.data")
    /// Stream identifier
    public let id: UInt64

    /// Whether this is a locally-initiated stream
    public let isLocallyInitiated: Bool

    /// Internal state protected by Mutex
    private let _internal: Mutex<DataStreamInternalState>

    /// Creates a new DataStream
    /// - Parameters:
    ///   - id: Stream identifier
    ///   - isClient: Whether local endpoint is client
    ///   - initialSendMaxData: Initial send flow control limit
    ///   - initialRecvMaxData: Initial receive flow control limit
    ///   - maxBufferSize: Maximum receive buffer size
    ///   - priority: Initial stream priority (default: .default)
    public init(
        id: UInt64,
        isClient: Bool,
        initialSendMaxData: UInt64,
        initialRecvMaxData: UInt64,
        maxBufferSize: UInt64 = 16 * 1024 * 1024,
        priority: StreamPriority = .default
    ) {
        self.id = id

        // Determine if locally initiated
        let isClientInitiated = StreamID.isClientInitiated(id)
        self.isLocallyInitiated = (isClient && isClientInitiated) || (!isClient && !isClientInitiated)

        let state = StreamState(
            id: id,
            initialSendMaxData: initialSendMaxData,
            initialRecvMaxData: initialRecvMaxData
        )

        self._internal = Mutex(DataStreamInternalState(
            state: state,
            recvBuffer: DataBuffer(maxBufferSize: maxBufferSize),
            sendBuffer: Data(),
            sendBufferConsumed: 0,
            sendBufferOffset: 0,
            finQueued: false,
            stopSendingReceived: false,
            stopSendingErrorCode: nil,
            resetStreamSent: false,
            resetStreamErrorCode: nil,
            resetStreamReceived: false,
            peerResetErrorCode: nil,
            priority: priority
        ))
    }

    // MARK: - Stream Properties

    /// Stream state machine
    public var state: StreamState {
        _internal.withLock { $0.state }
    }

    /// Stream priority for scheduling (mutable)
    ///
    /// Streams with lower urgency values are scheduled first.
    public var priority: StreamPriority {
        get { _internal.withLock { $0.priority } }
        set { _internal.withLock { $0.priority = newValue } }
    }

    /// Whether this stream is bidirectional
    public var isBidirectional: Bool {
        StreamID.isBidirectional(id)
    }

    /// Whether this stream is unidirectional
    public var isUnidirectional: Bool {
        StreamID.isUnidirectional(id)
    }

    /// Whether this stream can send data (based on type and initiator)
    public var canSend: Bool {
        _internal.withLock { `internal` in
            // Bidirectional: both sides can send
            // Unidirectional: only initiator can send
            if StreamID.isBidirectional(id) {
                return `internal`.state.canSend
            } else {
                return isLocallyInitiated && `internal`.state.canSend
            }
        }
    }

    /// Whether this stream can receive data (based on type and initiator)
    public var canReceive: Bool {
        _internal.withLock { `internal` in
            // Bidirectional: both sides can receive
            // Unidirectional: only non-initiator can receive
            if StreamID.isBidirectional(id) {
                return `internal`.state.canReceive
            } else {
                return !isLocallyInitiated && `internal`.state.canReceive
            }
        }
    }

    /// Whether the stream is fully closed
    public var isClosed: Bool {
        _internal.withLock { `internal` in
            let sendClosed = `internal`.state.sendState == .dataRecvd || `internal`.state.sendState == .resetRecvd
            let recvClosed = `internal`.state.recvState == .dataRead || `internal`.state.recvState == .resetRead

            if StreamID.isBidirectional(id) {
                return sendClosed && recvClosed
            } else if isLocallyInitiated {
                return sendClosed  // Send-only
            } else {
                return recvClosed  // Receive-only
            }
        }
    }

    /// Available send window
    public var sendWindow: UInt64 {
        _internal.withLock { `internal` in
            guard `internal`.state.sendMaxData > `internal`.state.sendOffset else { return 0 }
            return `internal`.state.sendMaxData - `internal`.state.sendOffset
        }
    }

    /// Bytes pending to send
    public var pendingSendBytes: Int {
        _internal.withLock { `internal` in
            `internal`.sendBuffer.count - `internal`.sendBufferConsumed
        }
    }

    /// Whether there's data to send
    public var hasDataToSend: Bool {
        _internal.withLock { `internal` in
            let pending = `internal`.sendBuffer.count - `internal`.sendBufferConsumed
            return pending > 0 || (`internal`.finQueued && !`internal`.state.finSent)
        }
    }

    /// Whether there is data available to read
    public var hasDataToRead: Bool {
        _internal.withLock { $0.recvBuffer.contiguousBytesAvailable > 0 }
    }

    /// Whether the receive side is complete (FIN received and all data read)
    ///
    /// Returns `true` when the peer has sent FIN and all contiguous data
    /// has been consumed via `read()`.  Callers can use this to detect
    /// end-of-stream without blocking.
    public var isReceiveComplete: Bool {
        _internal.withLock { `internal` in
            // Stream received FIN and the application has read everything
            `internal`.state.finReceived &&
                (`internal`.state.recvState == .dataRead ||
                 `internal`.state.recvState == .dataRecvd ||
                 `internal`.recvBuffer.isComplete)
        }
    }

    /// Whether the stream was reset by the peer
    public var isResetByPeer: Bool {
        _internal.withLock { `internal` in
            `internal`.resetStreamReceived
        }
    }

    /// Bytes buffered for reading
    public var bufferedReadBytes: Int {
        _internal.withLock { $0.recvBuffer.bufferedBytes }
    }

    /// Whether this stream needs to generate a RESET_STREAM (due to STOP_SENDING received)
    public var needsResetStream: Bool {
        _internal.withLock { `internal` in
            `internal`.stopSendingReceived && !`internal`.resetStreamSent
        }
    }

    /// The error code received in STOP_SENDING (if any)
    public var stopSendingErrorCode: UInt64? {
        _internal.withLock { `internal` in
            `internal`.stopSendingReceived ? `internal`.stopSendingErrorCode : nil
        }
    }

    // MARK: - Receive Side

    /// Process incoming STREAM frame
    /// - Parameter frame: The received STREAM frame
    /// - Throws: StreamError on validation failures
    public func receive(_ frame: StreamFrame) throws {
        try _internal.withLock { `internal` in
            guard frame.streamID == id else {
                throw StreamError.streamIDMismatch(expected: id, received: frame.streamID)
            }

            // Check if we can receive on this stream
            if StreamID.isUnidirectional(id) && isLocallyInitiated {
                throw StreamError.cannotReceiveOnSendOnlyStream
            }

            // RFC 9000 §3.2: In terminal receive states the peer's data has
            // already been fully received (or the stream was reset).  Late or
            // retransmitted STREAM frames are harmless — silently discard them
            // so we don't abort processing of the entire QUIC packet (which
            // may carry frames for other, still-active streams).
            switch `internal`.state.recvState {
            case .dataRecvd, .dataRead, .resetRecvd, .resetRead:
                return
            default:
                break
            }

            guard `internal`.state.canReceive else {
                throw StreamError.invalidState(
                    current: String(describing: `internal`.state.recvState),
                    operation: "receive"
                )
            }

            // Check receive flow control
            let endOffset = frame.offset + UInt64(frame.data.count)
            if endOffset > `internal`.state.recvMaxData {
                throw StreamError.flowControlViolation(
                    limit: `internal`.state.recvMaxData,
                    requested: endOffset
                )
            }

            // Insert into buffer
            do {
                try `internal`.recvBuffer.insert(offset: frame.offset, data: frame.data, fin: frame.fin)
            } catch let error as DataBufferError {
                throw StreamError.bufferError(error)
            }

            // Update state for FIN
            if frame.fin {
                `internal`.state.finReceived = true
                `internal`.state.finalSize = endOffset
                `internal`.state.recvState = .sizeKnown
            }

            // Update receive offset tracking (highest byte received)
            if endOffset > `internal`.state.recvOffset {
                `internal`.state.recvOffset = endOffset
            }
        }
    }

    /// Read available contiguous data
    /// - Returns: Data if available, nil otherwise
    public func read() -> Data? {
        _internal.withLock { `internal` in
            let canRecv = StreamID.isBidirectional(id)
                ? `internal`.state.canReceive
                : (!isLocallyInitiated && `internal`.state.canReceive)

            guard canRecv || `internal`.state.recvState == .sizeKnown || `internal`.state.recvState == .dataRecvd else {
                return nil
            }

            let data = `internal`.recvBuffer.readAllContiguous()

            // Update state if all data has been read
            if `internal`.recvBuffer.isComplete && `internal`.state.finReceived {
                `internal`.state.recvState = .dataRead
            } else if data != nil && `internal`.state.recvState == .sizeKnown && `internal`.recvBuffer.isEmpty {
                `internal`.state.recvState = .dataRecvd
            }

            return data
        }
    }

    /// Peek at available contiguous data without consuming
    /// - Returns: Data if available, nil otherwise
    public func peek() -> Data? {
        _internal.withLock { $0.recvBuffer.peekContiguous() }
    }

    // MARK: - Send Side

    /// Queue data for sending
    /// - Parameter data: Data to send
    /// - Throws: StreamError if stream cannot send
    public func write(_ data: Data) throws {
        try _internal.withLock { `internal` in
            // Check if we can send on this stream
            if StreamID.isUnidirectional(id) && !isLocallyInitiated {
                throw StreamError.cannotSendOnReceiveOnlyStream
            }

            guard `internal`.state.canSend else {
                throw StreamError.invalidState(
                    current: String(describing: `internal`.state.sendState),
                    operation: "write"
                )
            }

            if `internal`.stopSendingReceived {
                throw StreamError.streamReset(errorCode: `internal`.stopSendingErrorCode ?? 0)
            }

            `internal`.sendBuffer.append(data)

            // Transition to send state
            if `internal`.state.sendState == .ready {
                `internal`.state.sendState = .send
            }
        }
    }

    /// Mark stream as finished (queue FIN)
    /// - Throws: StreamError if stream cannot send
    public func finish() throws {
        try _internal.withLock { `internal` in
            if StreamID.isUnidirectional(id) && !isLocallyInitiated {
                throw StreamError.cannotSendOnReceiveOnlyStream
            }

            guard `internal`.state.canSend else {
                throw StreamError.invalidState(
                    current: String(describing: `internal`.state.sendState),
                    operation: "finish"
                )
            }

            `internal`.finQueued = true
        }
    }

    /// Generate STREAM frames up to maxBytes
    /// - Parameter maxBytes: Maximum total bytes for frames
    /// - Returns: Array of STREAM frames to send
    public func generateFrames(maxBytes: Int) -> [StreamFrame] {
        _internal.withLock { `internal` in
            let pending = `internal`.sendBuffer.count - `internal`.sendBufferConsumed
            guard pending > 0 || (`internal`.finQueued && !`internal`.state.finSent) else { return [] }

            let sendMaxData = `internal`.state.sendMaxData
            let sendOffset = `internal`.state.sendOffset
            let availableWindow = sendMaxData > sendOffset ? sendMaxData - sendOffset : 0
            Self.logger.trace("Stream \(self.id) generateFrames: pending=\(pending), sendMaxData=\(sendMaxData), sendOffset=\(sendOffset), availableWindow=\(availableWindow)")

            var frames: [StreamFrame] = []
            var remainingBytes = maxBytes

            // Compute actual STREAM frame overhead using varint sizes
            // Frame layout: type (1 byte) + streamID (varint) + offset (varint) + length (varint)
            // The offset field is omitted when offset == 0, but we conservatively include it.
            @inline(__always)
            func varintSize(_ value: UInt64) -> Int {
                if value < 64 { return 1 }
                if value < 16384 { return 2 }
                if value < 1_073_741_824 { return 4 }
                return 8
            }

            let currentSendOffset = `internal`.state.sendOffset
            let streamOverhead = 1  // frame type byte
                + varintSize(id)
                + (currentSendOffset > 0 ? varintSize(currentSendOffset) : 0)
                + 2  // length field (varint, typically 1-2 bytes for data < 16384)
            let minOverhead = max(streamOverhead, 3)  // at least type + streamID(1) + length(1)

            while remainingBytes > minOverhead {
                let currentPending = `internal`.sendBuffer.count - `internal`.sendBufferConsumed

                guard currentPending > 0 || (`internal`.finQueued && !`internal`.state.finSent) else { break }

                // Calculate how much data we can send
                let sendMaxData = `internal`.state.sendMaxData
                let sendOffset = `internal`.state.sendOffset
                let availableWindow = sendMaxData > sendOffset ? sendMaxData - sendOffset : 0
                let dataInBuffer = UInt64(currentPending)
                // Use saturating subtraction to prevent underflow if remainingBytes < minOverhead
                let adjustedRemaining = SafeConversions.saturatingSubtract(remainingBytes, minOverhead)
                let maxDataToSend = min(availableWindow, dataInBuffer, UInt64(adjustedRemaining))

                let dataToSend: Data
                let sendFin: Bool

                if maxDataToSend > 0 {
                    // Extract data using consume offset (O(1) slice operation)
                    let startIndex = `internal`.sendBuffer.startIndex.advanced(by: `internal`.sendBufferConsumed)
                    let endIndex = startIndex.advanced(by: Int(maxDataToSend))
                    dataToSend = `internal`.sendBuffer[startIndex..<endIndex]
                    `internal`.sendBufferConsumed += Int(maxDataToSend)
                    let newPending = `internal`.sendBuffer.count - `internal`.sendBufferConsumed
                    sendFin = `internal`.finQueued && newPending == 0
                } else if `internal`.finQueued && !`internal`.state.finSent && currentPending == 0 {
                    // Send FIN-only frame
                    dataToSend = Data()
                    sendFin = true
                } else {
                    break  // No window or data
                }

                let currentOffset = `internal`.sendBufferOffset
                `internal`.sendBufferOffset += UInt64(dataToSend.count)

                let frame = StreamFrame(
                    streamID: id,
                    offset: currentOffset,
                    data: dataToSend,
                    fin: sendFin,
                    hasLength: true
                )
                frames.append(frame)

                // Update state
                `internal`.state.sendOffset = `internal`.sendBufferOffset
                if sendFin {
                    `internal`.state.finSent = true
                    `internal`.state.sendState = .dataSent
                }

                // Recalculate actual overhead for this frame using precise varint sizes
                let actualFrameOverhead = 1  // frame type byte
                    + varintSize(id)
                    + (currentOffset > 0 ? varintSize(currentOffset) : 0)
                    + varintSize(UInt64(dataToSend.count))
                // Safely subtract to track remaining bytes (saturate at 0)
                remainingBytes = SafeConversions.saturatingSubtract(
                    remainingBytes,
                    actualFrameOverhead + dataToSend.count
                )
            }

            // Compact buffer when consumed portion exceeds half the total size
            // This amortizes the O(n) compaction cost
            if `internal`.sendBufferConsumed > `internal`.sendBuffer.count / 2 && `internal`.sendBufferConsumed > 4096 {
                `internal`.sendBuffer.removeFirst(`internal`.sendBufferConsumed)
                `internal`.sendBufferConsumed = 0
            }

            return frames
        }
    }

    // MARK: - Flow Control Updates

    /// Update send flow control limit (from MAX_STREAM_DATA)
    /// - Parameter maxData: New maximum data limit
    public func updateSendMaxData(_ maxData: UInt64) {
        _internal.withLock { `internal` in
            if maxData > `internal`.state.sendMaxData {
                `internal`.state.sendMaxData = maxData
            }
        }
    }

    /// Update receive flow control limit
    /// - Parameter maxData: New maximum data limit
    public func updateRecvMaxData(_ maxData: UInt64) {
        _internal.withLock { `internal` in
            if maxData > `internal`.state.recvMaxData {
                `internal`.state.recvMaxData = maxData
            }
        }
    }

    // MARK: - Stream Control Frames

    /// Handle STOP_SENDING from peer
    /// - Parameter errorCode: Application error code
    ///
    /// RFC 9000 Section 3.5: An endpoint that receives a STOP_SENDING frame MUST send a RESET_STREAM frame.
    /// This method sets the flag; RESET_STREAM is generated via generateResetStream().
    public func handleStopSending(errorCode: UInt64) {
        _internal.withLock { `internal` in
            `internal`.stopSendingReceived = true
            `internal`.stopSendingErrorCode = errorCode

            // Clear send buffer (we won't be sending this data)
            `internal`.sendBuffer.removeAll()
            `internal`.sendBufferConsumed = 0

            // NOTE: Do NOT transition sendState here!
            // The state transition happens when RESET_STREAM is actually generated via generateResetStream().
            // This ensures the RESET_STREAM can be generated (canSend check passes).
        }
    }

    /// Handle RESET_STREAM from peer
    /// - Parameters:
    ///   - errorCode: Application error code
    ///   - finalSize: Final size of the stream
    /// - Throws: StreamError if final size exceeds flow control limit or mismatches
    public func handleResetStream(errorCode: UInt64, finalSize: UInt64) throws {
        try _internal.withLock { `internal` in
            // RFC 9000 Section 4.5: Validate final size against flow control limit
            if finalSize > `internal`.state.recvMaxData {
                throw StreamError.flowControlViolation(
                    limit: `internal`.state.recvMaxData,
                    requested: finalSize
                )
            }

            // Validate final size if already known
            if let knownFinalSize = `internal`.state.finalSize {
                guard finalSize == knownFinalSize else {
                    throw StreamError.finalSizeMismatch(
                        expected: knownFinalSize,
                        received: finalSize
                    )
                }
            }

            `internal`.resetStreamReceived = true
            `internal`.peerResetErrorCode = errorCode
            `internal`.state.finalSize = finalSize

            // Clear receive buffer
            `internal`.recvBuffer.reset()

            // Transition receive state
            `internal`.state.recvState = .resetRecvd
        }
    }

    /// Generate RESET_STREAM frame if needed
    /// - Parameter errorCode: Application error code
    /// - Returns: RESET_STREAM frame to send
    ///
    /// RFC 9000 Section 3.5: RESET_STREAM can be generated when:
    /// - Stream is in a send-capable state (canSend)
    /// - Stream has sent all data (dataSent)
    /// - Peer sent STOP_SENDING (stopSendingReceived) - MUST respond with RESET_STREAM
    public func generateResetStream(errorCode: UInt64) -> ResetStreamFrame? {
        _internal.withLock { `internal` in
            guard !`internal`.resetStreamSent else { return nil }

            // Can generate RESET_STREAM if:
            // - Stream can still send (canSend)
            // - Stream has finished sending data (dataSent)
            // - Peer requested we stop sending (stopSendingReceived)
            let canGenerate = `internal`.state.canSend
                || `internal`.state.sendState == .dataSent
                || `internal`.stopSendingReceived
            guard canGenerate else { return nil }

            `internal`.resetStreamSent = true
            `internal`.resetStreamErrorCode = errorCode

            // Clear send buffer (may have been cleared by handleStopSending, but safe to repeat)
            `internal`.sendBuffer.removeAll()
            `internal`.sendBufferConsumed = 0

            // Transition to resetSent state
            `internal`.state.sendState = .resetSent

            return ResetStreamFrame(
                streamID: id,
                applicationErrorCode: errorCode,
                finalSize: `internal`.state.sendOffset
            )
        }
    }

    /// Generate STOP_SENDING frame
    /// - Parameter errorCode: Application error code
    /// - Returns: STOP_SENDING frame to send
    public func generateStopSending(errorCode: UInt64) -> StopSendingFrame? {
        _internal.withLock { `internal` in
            let canRecv = StreamID.isBidirectional(id)
                ? `internal`.state.canReceive
                : (!isLocallyInitiated && `internal`.state.canReceive)

            guard canRecv else { return nil }

            return StopSendingFrame(
                streamID: id,
                applicationErrorCode: errorCode
            )
        }
    }

    /// Acknowledge that peer received our data up to this offset
    /// - Parameter offset: Acknowledged offset
    public func acknowledgeData(upTo offset: UInt64) {
        _internal.withLock { `internal` in
            // If all sent data is acknowledged and FIN was sent
            if offset >= `internal`.state.sendOffset && `internal`.state.finSent {
                `internal`.state.sendState = .dataRecvd
            }
        }
    }

    /// Acknowledge that peer received our RESET_STREAM
    public func acknowledgeReset() {
        _internal.withLock { `internal` in
            if `internal`.resetStreamSent {
                `internal`.state.sendState = .resetRecvd
            }
        }
    }
}
