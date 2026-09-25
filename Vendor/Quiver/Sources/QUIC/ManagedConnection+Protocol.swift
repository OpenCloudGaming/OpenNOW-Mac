/// ManagedConnection — QUICConnectionProtocol Conformance
///
/// Extension providing the public QUICConnectionProtocol API including
/// stream management, datagrams, session tickets, and shutdown.

import Foundation
import Logging
import Synchronization
import QUICCore
import QUICCrypto
import QUICConnection
import QUICStream
import QUICRecovery

// MARK: - QUICConnectionProtocol

extension ManagedConnection: QUICConnectionProtocol {
    public var isEstablished: Bool {
        state.withLock { $0.handshakeState == .established }
    }

    public func openStream() async throws -> any QUICStreamProtocol {
        let streamID = try handler.openStream(bidirectional: true)
        return ManagedStream(
            id: streamID,
            connection: self,
            isUnidirectional: false
        )
    }

    public func openUniStream() async throws -> any QUICStreamProtocol {
        let streamID = try handler.openStream(bidirectional: false)
        return ManagedStream(
            id: streamID,
            connection: self,
            isUnidirectional: true
        )
    }

    public var incomingStreams: AsyncStream<any QUICStreamProtocol> {
        incomingStreamState.withLock { state in
            // If shutdown, return existing finished stream or create a finished one
            // This prevents new iterators from hanging after shutdown
            if state.isShutdown {
                if let existing = state.stream { return existing }
                // Create an already-finished stream
                let (stream, continuation) = AsyncStream<any QUICStreamProtocol>.makeStream()
                continuation.finish()
                state.stream = stream
                return stream
            }

            // Return existing stream if already created (lazy initialization)
            if let existing = state.stream { return existing }

            // Create new stream using makeStream() pattern (per coding guidelines)
            let (stream, continuation) = AsyncStream<any QUICStreamProtocol>.makeStream()
            state.stream = stream
            state.continuation = continuation

            // Drain any pending streams that arrived before this was accessed
            for pendingStream in state.pendingStreams {
                continuation.yield(pendingStream)
            }
            state.pendingStreams.removeAll()

            return stream
        }
    }

    /// Stream of session tickets received from the server
    ///
    /// Use this to receive `NewSessionTicket` messages for session resumption.
    /// Store these tickets in a `ClientSessionCache` for future 0-RTT connections.
    ///
    /// ## Usage
    /// ```swift
    /// let sessionCache = ClientSessionCache()
    /// Task {
    ///     for await ticketInfo in connection.sessionTickets {
    ///         sessionCache.storeTicket(
    ///             ticketInfo.ticket,
    ///             resumptionMasterSecret: ticketInfo.resumptionMasterSecret,
    ///             cipherSuite: ticketInfo.cipherSuite,
    ///             alpn: ticketInfo.alpn,
    ///             serverIdentity: "\(connection.remoteAddress)"
    ///         )
    ///     }
    /// }
    /// ```
    public var sessionTickets: AsyncStream<NewSessionTicketInfo> {
        sessionTicketState.withLock { state in
            // If shutdown, return existing finished stream or create a finished one
            if state.isShutdown {
                if let existing = state.stream { return existing }
                let (stream, continuation) = AsyncStream<NewSessionTicketInfo>.makeStream()
                continuation.finish()
                state.stream = stream
                return stream
            }

            // Return existing stream if already created
            if let existing = state.stream { return existing }

            // Create new stream
            let (stream, continuation) = AsyncStream<NewSessionTicketInfo>.makeStream()
            state.stream = stream
            state.continuation = continuation

            // Drain any pending tickets
            for pendingTicket in state.pendingTickets {
                continuation.yield(pendingTicket)
            }
            state.pendingTickets.removeAll()

            return stream
        }
    }

    /// Notifies that a session ticket was received (internal helper)
    func notifySessionTicketReceived(_ ticketInfo: NewSessionTicketInfo) {
        sessionTicketState.withLock { state in
            guard !state.isShutdown else { return }

            if let continuation = state.continuation {
                // Stream is active, yield directly
                continuation.yield(ticketInfo)
            } else {
                // Buffer until sessionTickets is accessed
                state.pendingTickets.append(ticketInfo)
            }
        }
    }

    public func sendDatagram(_ data: Data) async throws {
        guard isEstablished else {
            throw QUICDatagramError.connectionNotReady
        }

        // Check that datagrams are supported via transport parameters
        let maxSize = transportParameters.maxDatagramFrameSize ?? 0
        guard maxSize > 0 else {
            throw QUICDatagramError.datagramsNotSupported
        }

        // Check payload size (the max includes framing overhead; be conservative)
        guard data.count <= Int(maxSize) else {
            throw QUICDatagramError.datagramTooLarge(size: data.count, maxAllowed: Int(maxSize))
        }

        // Write datagram payload through the handler
        // The handler encodes it as a DATAGRAM frame on the wire
        try handler.sendDatagram(data)
        signalNeedsSend()
    }

    public var incomingDatagrams: AsyncStream<Data> {
        incomingDatagramState.withLock { state in
            // If shutdown, return existing finished stream or create a finished one
            if state.isShutdown {
                if let existing = state.stream { return existing }
                let (stream, continuation) = AsyncStream<Data>.makeStream()
                continuation.finish()
                state.stream = stream
                return stream
            }

            // Return existing stream if already created (lazy initialization)
            if let existing = state.stream { return existing }

            // Create new stream
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            state.stream = stream
            state.continuation = continuation

            // Drain any pending datagrams that arrived before this was accessed
            for pendingDatagram in state.pendingDatagrams {
                continuation.yield(pendingDatagram)
            }
            state.pendingDatagrams.removeAll()

            return stream
        }
    }

    /// Delivers an incoming datagram payload (internal helper called by packet processing)
    public func notifyDatagramReceived(_ data: Data) {
        incomingDatagramState.withLock { state in
            guard !state.isShutdown else { return }

            if let continuation = state.continuation {
                // Stream is active, yield directly
                continuation.yield(data)
            } else {
                // Buffer until incomingDatagrams is accessed
                state.pendingDatagrams.append(data)
            }
        }
    }

    public func close(error: UInt64?) async {
        let scid = state.withLock { $0.sourceConnectionID }
        Self.logger.debug("close(error: \(String(describing: error))) called for SCID=\(scid)")
        handler.close(error: error.map { ConnectionCloseError(code: $0) })
        state.withLock { $0.handshakeState = .closing }
        shutdown()
    }

    public func close(applicationError errorCode: UInt64, reason: String) async {
        let scid = state.withLock { $0.sourceConnectionID }
        Self.logger.info("close(applicationError: \(errorCode), reason: \(reason)) called for SCID=\(scid)")
        handler.close(error: ConnectionCloseError(code: errorCode, reason: reason))
        state.withLock { $0.handshakeState = .closing }
        shutdown()
    }

    /// Shuts down the connection and finishes all async streams
    ///
    /// This is required per coding guidelines: AsyncStream services MUST
    /// call continuation.finish() to prevent for-await loops from hanging.
    ///
    /// Note: We set isShutdown=true but keep the stream reference.
    /// This allows existing iterators to complete normally while preventing
    /// new iterators from hanging (they get an already-finished stream).
    public func shutdown() {
        let (scid, handshakeWaiters) = state.withLock { s -> (ConnectionID, [(id: UUID, continuation: CheckedContinuation<Void, any Error>)]) in
            let w = s.handshakeCompletionContinuations
            s.handshakeCompletionContinuations.removeAll()
            return (s.sourceConnectionID, w)
        }
        Self.logger.debug("shutdown() called for SCID=\(scid)")

        // Resume any callers waiting in waitForHandshake() with an error
        // This prevents them from hanging indefinitely when the connection
        // is torn down before handshake completes.
        for waiter in handshakeWaiters {
            waiter.continuation.resume(throwing: ManagedConnectionError.connectionClosed)
        }

        // Finish incoming stream continuation and mark as shutdown
        // Guard against concurrent calls - finish() is idempotent but we avoid duplicate work
        incomingStreamState.withLock { state in
            guard !state.isShutdown else { return }  // Already shutdown
            state.isShutdown = true  // Mark as shutdown FIRST
            state.continuation?.finish()
            state.continuation = nil
            state.pendingStreams.removeAll()  // Clear any buffered streams
            // DO NOT set stream = nil - existing iterators need it
        }

        // Finish session ticket stream and mark as shutdown
        sessionTicketState.withLock { state in
            guard !state.isShutdown else { return }  // Already shutdown
            state.isShutdown = true
            state.continuation?.finish()
            state.continuation = nil
            state.pendingTickets.removeAll()
        }

        // Finish incoming datagram stream and mark as shutdown
        incomingDatagramState.withLock { state in
            guard !state.isShutdown else { return }  // Already shutdown
            state.isShutdown = true
            state.continuation?.finish()
            state.continuation = nil
            state.pendingDatagrams.removeAll()
        }

        // Resume any waiting stream readers with connection closed error
        // and mark as shutdown to prevent new readers from hanging
        streamContinuationsState.withLock { state in
            guard !state.isShutdown else { return }  // Already shutdown
            state.isShutdown = true  // Mark as shutdown FIRST
            for (_, continuation) in state.continuations {
                continuation.resume(throwing: ManagedConnectionError.connectionClosed)
            }
            state.continuations.removeAll()
        }

        // Finish send signal stream to stop outboundSendLoop in QUICEndpoint
        state.withLock { s in
            guard !s.isSendSignalShutdown else { return }  // Already shutdown
            Self.logger.debug("shutdown() finishing sendSignal for SCID=\(s.sourceConnectionID), hasContinuation=\(s.sendSignalContinuation != nil)")
            s.isSendSignalShutdown = true
            s.sendSignalContinuation?.finish()
            s.sendSignalContinuation = nil
        }
    }
}