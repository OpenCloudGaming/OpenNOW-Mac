/// QUICConnectionHandler — Stream Operations
///
/// Extension containing all stream management forwarding methods:
/// - openStream, writeToStream, finishStream, readFromStream, closeStream
/// - Stream state queries (isReceiveComplete, isResetByPeer, hasData, etc.)
/// - Datagram support (RFC 9221)

import Foundation
import QUICCore
import QUICStream

// MARK: - Stream Management

extension QUICConnectionHandler {

    /// Opens a new stream
    /// - Parameter bidirectional: Whether to create a bidirectional stream
    /// - Returns: The new stream ID
    /// - Throws: StreamManagerError if stream limit reached
    package func openStream(bidirectional: Bool) throws -> UInt64 {
        try streamManager.openStream(bidirectional: bidirectional)
    }

    /// Writes data to a stream
    /// - Parameters:
    ///   - streamID: Stream to write to
    ///   - data: Data to write
    /// - Throws: StreamManagerError on failures
    package func writeToStream(_ streamID: UInt64, data: Data) throws {
        try streamManager.write(streamID: streamID, data: data)
    }

    /// Finishes writing to a stream (sends FIN)
    /// - Parameter streamID: Stream to finish
    /// - Throws: StreamManagerError on failures
    package func finishStream(_ streamID: UInt64) throws {
        try streamManager.finish(streamID: streamID)
    }

    /// Reads data from a stream
    /// - Parameter streamID: Stream to read from
    /// - Returns: Available data, or nil if none
    package func readFromStream(_ streamID: UInt64) -> Data? {
        streamManager.read(streamID: streamID)
    }

    /// Closes a stream
    /// - Parameter streamID: Stream to close
    package func closeStream(_ streamID: UInt64) {
        streamManager.closeStream(id: streamID)
    }

    /// Whether the receive side of a stream is complete (FIN received, all data read)
    ///
    /// Use this to detect end-of-stream without blocking.  Returns `true`
    /// when the peer has sent FIN and all contiguous data has been consumed.
    package func isStreamReceiveComplete(_ streamID: UInt64) -> Bool {
        streamManager.isStreamReceiveComplete(streamID: streamID)
    }

    /// Whether the stream was reset by the peer (RESET_STREAM received)
    package func isStreamResetByPeer(_ streamID: UInt64) -> Bool {
        streamManager.isStreamResetByPeer(streamID: streamID)
    }

    /// Checks if a stream has data to read
    /// - Parameter streamID: Stream to check
    /// - Returns: true if data available
    package func streamHasDataToRead(_ streamID: UInt64) -> Bool {
        streamManager.hasDataToRead(streamID: streamID)
    }

    /// Checks if a stream has data to send
    /// - Parameter streamID: Stream to check
    /// - Returns: true if data pending
    package func streamHasDataToSend(_ streamID: UInt64) -> Bool {
        streamManager.hasDataToSend(streamID: streamID)
    }

    /// Gets all active stream IDs
    package var activeStreamIDs: [UInt64] {
        streamManager.activeStreamIDs
    }

    /// Gets the number of active streams
    package var activeStreamCount: Int {
        streamManager.activeStreamCount
    }

    /// Whether any stream has data waiting to be sent
    ///
    /// Use this to check if outbound packets need to be generated and sent.
    package var hasPendingStreamData: Bool {
        streamManager.hasPendingStreamData
    }

    // MARK: - Datagram Support (RFC 9221)

    /// Sends a QUIC DATAGRAM frame with the given payload.
    ///
    /// Queues a DATAGRAM frame (with explicit length) to be sent in the
    /// next outbound packet at the application encryption level.
    ///
    /// - Parameter data: The datagram payload
    /// - Throws: `QUICConnectionHandlerError.cryptoError` if the connection is not established
    package func sendDatagram(_ data: Data) throws {
        let status = connectionState.withLock { $0.status }
        guard status == .established else {
            throw QUICConnectionHandlerError.cryptoError("Connection not established for datagram send")
        }

        let frame = Frame.datagram(DatagramFrame(data: data, hasLength: true))
        queueFrame(frame, level: .application)
    }
}