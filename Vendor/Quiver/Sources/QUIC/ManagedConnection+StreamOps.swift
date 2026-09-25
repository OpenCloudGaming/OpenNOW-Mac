/// ManagedConnection — Stream Operations
///
/// Internal stream read/write/finish/reset helpers used by ManagedStream.

import Foundation
import QUICCore
import QUICConnection

// MARK: - Internal Stream Access

extension ManagedConnection {
    /// Writes data to a stream (called by ManagedStream)
    func writeToStream(_ streamID: UInt64, data: Data) throws {
        try handler.writeToStream(streamID, data: data)
        signalNeedsSend()
    }

    /// Reads data from a stream (called by ManagedStream)
    ///
    /// Thread-safe: Prevents concurrent reads on the same stream.
    /// Only one reader can wait for data at a time per stream.
    /// Returns connectionClosed error if called after shutdown.
    ///
    /// Data sources (in priority order):
    /// 1. Pending data buffer (from processFrameResult)
    /// 2. Handler's stream buffer
    /// 3. Wait for data via continuation
    func readFromStream(_ streamID: UInt64) async throws -> Data {
        // Try to get data atomically - check buffer first, then handler
        return try await withCheckedThrowingContinuation { continuation in
            streamContinuationsState.withLock { state in
                // Check if shutdown
                guard !state.isShutdown else {
                    continuation.resume(throwing: ManagedConnectionError.connectionClosed)
                    return
                }

                // Priority 1: Check pending data buffer
                if var pending = state.pendingData[streamID], !pending.isEmpty {
                    let data = pending.removeFirst()
                    if pending.isEmpty {
                        state.pendingData.removeValue(forKey: streamID)
                    } else {
                        state.pendingData[streamID] = pending
                    }
                    continuation.resume(returning: data)
                    return
                }

                // Priority 2: Check handler's stream buffer
                if let data = handler.readFromStream(streamID) {
                    continuation.resume(returning: data)
                    return
                }

                // Priority 3: Check if stream receive side is complete (FIN)
                // or was reset by the peer.  Return empty Data to signal
                // end-of-stream so that callers break out of read loops.
                //
                // IMPORTANT: We intentionally do NOT check
                // `handler.isStreamReceiveComplete(streamID)` here.
                // processFrames() reads (consumes) data from the DataStream
                // buffer inline, then processFrameResult() delivers it to
                // pendingData / a continuation *later*.  Between those two
                // steps the DataStream buffer is empty and
                // isStreamReceiveComplete returns true — but the data has
                // not been delivered yet.  A concurrent reader hitting this
                // window would get a premature EOS (0 bytes).
                //
                // `state.finishedStreams` is populated by processFrameResult
                // AFTER delivering data, so it is the safe signal for FIN.
                // `isStreamResetByPeer` is safe because a reset carries no
                // data — the reader should return empty immediately.
                if state.finishedStreams.contains(streamID)
                    || handler.isStreamResetByPeer(streamID)
                {
                    state.finishedStreams.insert(streamID)
                    continuation.resume(returning: Data())
                    return
                }

                // Priority 4: Wait for data
                // Prevent concurrent reads on the same stream
                guard state.continuations[streamID] == nil else {
                    continuation.resume(throwing: ManagedConnectionError.invalidState("Concurrent read on stream \(streamID)"))
                    return
                }
                state.continuations[streamID] = continuation
            }
        }
    }

    /// Finishes a stream (sends FIN)
    func finishStream(_ streamID: UInt64) throws {
        try handler.finishStream(streamID)
        signalNeedsSend()
    }

    /// Resets a stream
    func resetStream(_ streamID: UInt64, errorCode: UInt64) {
        handler.closeStream(streamID)
    }

    /// Stops sending on a stream
    func stopSending(_ streamID: UInt64, errorCode: UInt64) {
        // Handler will generate STOP_SENDING frame
        handler.closeStream(streamID)
    }
}