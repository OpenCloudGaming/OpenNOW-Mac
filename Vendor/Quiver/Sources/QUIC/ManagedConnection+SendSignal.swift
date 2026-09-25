/// ManagedConnection — Send Signal Extension
///
/// Provides the `sendSignal` AsyncStream and `signalNeedsSend()` mechanism
/// used by QUICEndpoint to know when outbound packets need to be generated.

import Foundation
import Logging
import Synchronization
import QUICCore
import QUICCrypto
import QUICConnection
import QUICStream
import QUICRecovery

// MARK: - Send Signal

extension ManagedConnection {
    /// Whether any stream still has data waiting to be sent.
    ///
    /// The outbound send loop uses this after generating a batch of packets
    /// to decide whether another `generateOutboundPackets()` round is needed
    /// (the single call is capped at the configured `maxDatagramSize` bytes
    /// of stream frames, so large or multi-stream writes may require
    /// several rounds).
    internal var hasPendingStreamData: Bool {
        handler.hasPendingStreamData
    }

    /// Signal that packets need to be sent.
    ///
    /// QUICEndpoint monitors this stream and, upon receiving a signal,
    /// calls `generateOutboundPackets()` to send packets.
    ///
    /// Multiple writes before signal processing will be coalesced into
    /// a single packet generation (efficient batching via `bufferingNewest(1)`).
    ///
    /// ## Usage
    /// ```swift
    /// // In QUICEndpoint
    /// Task {
    ///     for await _ in connection.sendSignal {
    ///         let packets = try connection.generateOutboundPackets()
    ///         for packet in packets {
    ///             socket.send(packet, to: address)
    ///         }
    ///     }
    /// }
    /// ```
    public var sendSignal: AsyncStream<Void> {
        state.withLock { s in
            // After shutdown, return an already-finished stream
            if s.isSendSignalShutdown {
                Self.logger.trace("sendSignal accessed AFTER shutdown for SCID=\(s.sourceConnectionID)")
                if let existing = s.sendSignalStream { return existing }
                let (stream, continuation) = AsyncStream<Void>.makeStream(
                    bufferingPolicy: .bufferingNewest(1)
                )
                continuation.finish()
                s.sendSignalStream = stream
                return stream
            }

            // Return existing stream if already created (lazy initialization)
            if let existing = s.sendSignalStream {
                Self.logger.trace("sendSignal returning EXISTING stream for SCID=\(s.sourceConnectionID), hasContinuation=\(s.sendSignalContinuation != nil)")
                return existing
            }

            // Create new stream with bufferingNewest(1) for coalescing
            // Multiple yields before consumption result in only one signal
            let (stream, continuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            s.sendSignalStream = stream
            s.sendSignalContinuation = continuation
            Self.logger.trace("sendSignal CREATED new stream for SCID=\(s.sourceConnectionID)")
            return stream
        }
    }

    /// Notifies that packets need to be sent.
    ///
    /// Called after `writeToStream()` or `finishStream()` to trigger
    /// packet generation and transmission in QUICEndpoint.
    public func signalNeedsSend() {
        state.withLock { s in
            guard !s.isSendSignalShutdown else {
                Self.logger.trace("signalNeedsSend SKIPPED (shutdown) for SCID=\(s.sourceConnectionID)")
                return
            }
            let hasContinuation = s.sendSignalContinuation != nil
            if !hasContinuation {
                Self.logger.warning("signalNeedsSend: no continuation for SCID=\(s.sourceConnectionID), streamExists=\(s.sendSignalStream != nil)")
            }
            s.sendSignalContinuation?.yield(())
        }
    }
}