/// HTTP/3 Connection Manager (RFC 9114, RFC 9218)
///
/// Manages the HTTP/3-specific aspects of a QUIC connection:
///
/// 1. **Control stream** — Opens one unidirectional stream in each direction,
///    exchanges SETTINGS frames
/// 2. **QPACK streams** — Opens encoder/decoder unidirectional streams
/// 3. **Request streams** — Bidirectional streams for HTTP request/response
/// 4. **Stream type identification** — Reads stream type byte from incoming
///    unidirectional streams
/// 5. **GOAWAY** — Graceful shutdown coordination
///
/// ## Connection Establishment Flow
///
/// ```
/// Client                                     Server
///   |                                          |
///   |  === QUIC connection established ===     |
///   |  === ALPN: "h3" negotiated ===           |
///   |                                          |
///   |  Open uni stream: Control (type=0x00)    |
///   |  Send SETTINGS frame                     |
///   |----------------------------------------->|
///   |                                          |
///   |  Open uni stream: QPACK Encoder (0x02)   |
///   |----------------------------------------->|
///   |                                          |
///   |  Open uni stream: QPACK Decoder (0x03)   |
///   |----------------------------------------->|
///   |                                          |
///   |  (Server also opens same 3 uni streams)  |
///   |<-----------------------------------------|
///   |                                          |
///   |  === HTTP/3 connection ready ===         |
///   |                                          |
/// ```
///
/// ## Thread Safety
///
/// `HTTP3Connection` is an `actor`, ensuring all mutable state is
/// accessed serially. This is consistent with Swift 6 concurrency
/// requirements and the project's design principles.

import Foundation
import QUIC
import QUICCore
import QUICStream
import QPACK
import Logging

// MARK: - HTTP/3 Connection

/// HTTP/3 connection wrapping a QUIC connection (RFC 9114 Section 3)
///
/// Manages the HTTP/3 layer on top of a QUIC connection, including
/// control stream setup, SETTINGS exchange, request multiplexing,
/// and graceful shutdown via GOAWAY.
///
/// ## Usage
///
/// ```swift
/// // Client-side
/// let h3conn = HTTP3Connection(
///     quicConnection: quicConn,
///     role: .client,
///     settings: HTTP3Settings()
/// )
/// try await h3conn.initialize()
/// let response = try await h3conn.sendRequest(request)
///
/// // Server-side
/// let h3conn = HTTP3Connection(
///     quicConnection: quicConn,
///     role: .server,
///     settings: HTTP3Settings()
/// )
/// try await h3conn.initialize()
/// for await context in h3conn.incomingRequests {
///     try await context.respond(response)
/// }
/// ```
public actor HTTP3Connection {

    static let logger = QuiverLogging.logger(label: "http3.connection")


    // MARK: - Types

    /// The role of this endpoint in the HTTP/3 connection
    public enum Role: Sendable {
        /// Client role — initiates requests
        case client
        /// Server role — responds to requests
        case server
    }

    /// Connection states
    enum State: Sendable, Hashable {
        /// Connection not yet initialized
        case idle
        /// Initialization in progress (control streams being opened)
        case initializing
        /// Connection is ready for requests
        case ready
        /// GOAWAY received/sent — no new requests
        case goingAway(lastStreamID: UInt64)
        /// Connection is closed
        case closed
    }

    // MARK: - Properties

    /// The underlying QUIC connection
    let quicConnection: any QUICConnectionProtocol

    /// Our role (client or server)
    let role: Role

    /// Local HTTP/3 settings
    let localSettings: HTTP3Settings

    /// Peer's HTTP/3 settings (set after SETTINGS received)
    var peerSettings: HTTP3Settings?

    /// Connection state
    var state: State = .idle

    /// QPACK encoder (for outgoing headers)
    let qpackEncoder: QPACKEncoder

    /// QPACK decoder (for incoming headers)
    let qpackDecoder: QPACKDecoder

    // MARK: - Streams

    /// Our local control stream
    var localControlStream: (any QUICStreamProtocol)?

    /// Peer's control stream
    var peerControlStream: (any QUICStreamProtocol)?

    /// Our local QPACK encoder stream
    var localQPACKEncoderStream: (any QUICStreamProtocol)?

    /// Our local QPACK decoder stream
    var localQPACKDecoderStream: (any QUICStreamProtocol)?

    /// Peer's QPACK encoder stream
    var peerQPACKEncoderStream: (any QUICStreamProtocol)?

    /// Peer's QPACK decoder stream
    var peerQPACKDecoderStream: (any QUICStreamProtocol)?

    /// GOAWAY stream ID (last stream/push ID to process)
    var goawayStreamID: UInt64?

    // MARK: - WebTransport Session Registry

    /// Active WebTransport sessions, keyed by session ID (= CONNECT stream ID).
    var webTransportSessions: [UInt64: WebTransportSession] = [:]

    /// Continuation for delivering newly created WebTransport sessions.
    var incomingWebTransportSessionContinuation: AsyncStream<WebTransportSession>.Continuation?

    /// Stream of incoming WebTransport sessions (server-side).
    ///
    /// When an Extended CONNECT with `:protocol = webtransport` is accepted
    /// and a `WebTransportSession` is created, it is delivered here.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// for await session in connection.incomingWebTransportSessions {
    ///     Task { await handleSession(session) }
    /// }
    /// ```
    public private(set) var incomingWebTransportSessions: AsyncStream<WebTransportSession>

    /// Task for the datagram routing loop (routes QUIC DATAGRAMs to WT sessions).
    var datagramRoutingTask: Task<Void, Never>?

    /// The next client-initiated bidirectional stream ID to use
    /// Client bidi streams: 0, 4, 8, 12, ...
    /// Server bidi streams: 1, 5, 9, 13, ...
    var nextStreamID: UInt64

    /// Whether the peer's control stream has been received
    var peerControlStreamReceived: Bool = false

    /// Whether the peer's QPACK encoder stream has been received
    var peerQPACKEncoderStreamReceived: Bool = false

    /// Whether the peer's QPACK decoder stream has been received
    var peerQPACKDecoderStreamReceived: Bool = false

    // MARK: - Priority Tracking (RFC 9218)

    /// Stream priorities received via PRIORITY_UPDATE frames.
    ///
    /// Maps stream IDs to their dynamically-updated priorities.
    /// These override the initial priority from the Priority header.
    var streamPriorities: [UInt64: StreamPriority] = [:]

    /// Pending PRIORITY_UPDATE frames for streams not yet created.
    ///
    /// Per RFC 9218 Section 7, a client can send PRIORITY_UPDATE for
    /// a stream ID before that stream is opened. The server stores
    /// these and applies them when the stream is created.
    var pendingPriorityUpdates: [UInt64: StreamPriority] = [:]

    // MARK: - Priority Scheduling (RFC 9218)

    /// Stream scheduler for priority-ordered data sending.
    ///
    /// Implements RFC 9218 Extensible Priority Scheme scheduling:
    /// - Urgency levels 0-7 (lower = higher priority)
    /// - Incremental vs non-incremental delivery
    /// - Round-robin within same urgency level
    var streamScheduler: StreamScheduler = StreamScheduler()

    /// Active response streams awaiting data send, keyed by stream ID.
    ///
    /// When a server has multiple concurrent responses to send, the
    /// scheduler determines the order based on priority.
    var activeResponseStreams: [UInt64: StreamPriority] = [:]

    // MARK: - Incoming Request Handling

    /// Continuation for the incoming requests stream
    var incomingRequestsContinuation: AsyncStream<HTTP3RequestContext>.Continuation?

    /// The async stream of incoming requests (server-side)
    public private(set) var incomingRequests: AsyncStream<HTTP3RequestContext>

    // MARK: - Incoming Extended CONNECT Handling (RFC 9220)

    /// Continuation for the incoming Extended CONNECT requests stream
    var incomingExtendedConnectContinuation: AsyncStream<ExtendedConnectContext>.Continuation?

    /// The async stream of incoming Extended CONNECT requests (server-side).
    ///
    /// Extended CONNECT requests (those with a `:protocol` pseudo-header)
    /// are routed here instead of to `incomingRequests`. This allows
    /// separate handling of WebTransport and other tunneled protocols.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// for await context in connection.incomingExtendedConnect {
    ///     if context.request.isWebTransportConnect {
    ///         try await context.accept()
    ///         // Use context.stream for WebTransport session
    ///     } else {
    ///         try await context.reject(status: 501)
    ///     }
    /// }
    /// ```
    public private(set) var incomingExtendedConnect: AsyncStream<ExtendedConnectContext>

    // MARK: - Initialization

    /// Creates an HTTP/3 connection manager.
    ///
    /// - Parameters:
    ///   - quicConnection: The underlying QUIC connection
    ///   - role: The role of this endpoint (client or server)
    ///   - settings: Local HTTP/3 settings (default: literal-only QPACK)
    public init(
        quicConnection: any QUICConnectionProtocol,
        role: Role,
        settings: HTTP3Settings = HTTP3Settings()
    ) {
        self.quicConnection = quicConnection
        self.role = role
        self.localSettings = settings
        self.qpackEncoder = QPACKEncoder()
        self.qpackDecoder = QPACKDecoder()

        // Client bidi streams start at 0, server at 1
        self.nextStreamID = (role == .client) ? 0 : 1

        // Create the incoming requests stream
        var continuation: AsyncStream<HTTP3RequestContext>.Continuation!
        self.incomingRequests = AsyncStream { cont in
            continuation = cont
        }
        self.incomingRequestsContinuation = continuation

        // Create the incoming Extended CONNECT stream
        var extConnectContinuation: AsyncStream<ExtendedConnectContext>.Continuation!
        self.incomingExtendedConnect = AsyncStream { cont in
            extConnectContinuation = cont
        }
        self.incomingExtendedConnectContinuation = extConnectContinuation

        // Create the incoming WebTransport sessions stream
        var wtSessionContinuation: AsyncStream<WebTransportSession>.Continuation!
        self.incomingWebTransportSessions = AsyncStream { cont in
            wtSessionContinuation = cont
        }
        self.incomingWebTransportSessionContinuation = wtSessionContinuation
    }

    deinit {
        incomingRequestsContinuation?.finish()
        incomingExtendedConnectContinuation?.finish()
        incomingWebTransportSessionContinuation?.finish()
        datagramRoutingTask?.cancel()
    }

    // MARK: - Connection Lifecycle

    /// Initializes the HTTP/3 connection.
    ///
    /// Opens the control stream (with SETTINGS), QPACK encoder and decoder
    /// streams, and starts processing incoming streams in the background.
    ///
    /// - Throws: `HTTP3Error` if initialization fails
    public func initialize() async throws {
        guard state == .idle else {
            throw HTTP3Error(code: .internalError, reason: "Connection already initialized")
        }

        state = .initializing

        // 0. Wait for QUIC handshake to complete before opening streams.
        //    Peer transport parameters (including stream limits) are only
        //    available after the handshake finishes.  Without this wait,
        //    openUniStream() will fail with streamLimitReached because the
        //    peer's max_streams values are still 0.
        let handshakeDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !quicConnection.isEstablished {
            if ContinuousClock.now >= handshakeDeadline {
                state = .closed
                throw HTTP3Error(
                    code: .internalError,
                    reason: "QUIC handshake did not complete within timeout"
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        // 1. Open control stream and send SETTINGS
        try await openControlStream()

        // 2. Open QPACK encoder and decoder streams (required even in literal-only mode)
        try await openQPACKStreams()

        // 3. Start background task to process incoming streams
        let connection = self.quicConnection
        Task { [weak self] in
            await self?.processIncomingStreams(from: connection)
        }
    }

    /// Waits until the connection transitions to the ready state.
    ///
    /// The connection is ready once peer SETTINGS have been received.
    /// This typically happens during the initial stream exchange.
    ///
    /// - Parameter timeout: Maximum time to wait (default: 10 seconds)
    /// - Throws: `HTTP3Error` if the timeout expires or connection closes
    public func waitForReady(timeout: Duration = .seconds(10)) async throws {
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            if state == .ready || peerSettings != nil {
                state = .ready
                return
            }
            if case .closed = state {
                throw HTTP3Error(code: .internalError, reason: "Connection closed before ready")
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        throw HTTP3Error(code: .missingSettings, reason: "Timed out waiting for peer SETTINGS")
    }

    /// Sends a GOAWAY frame to initiate graceful shutdown.
    ///
    /// For a client, `lastStreamID` is the last push ID to accept.
    /// For a server, `lastStreamID` is the last client-initiated
    /// stream ID that was or might be processed.
    ///
    /// - Parameter lastStreamID: The last stream/push ID to process
    /// - Throws: `HTTP3Error` if the GOAWAY frame cannot be sent
    public func goaway(lastStreamID: UInt64) async throws {
        guard let controlStream = localControlStream else {
            throw HTTP3Error(code: .closedCriticalStream, reason: "Control stream not open")
        }

        let frame = HTTP3Frame.goaway(streamID: lastStreamID)
        let encoded = HTTP3FrameCodec.encode(frame)
        try await controlStream.write(encoded)

        state = .goingAway(lastStreamID: lastStreamID)
    }

    /// Closes the HTTP/3 connection.
    ///
    /// Sends a GOAWAY if not already sent, then closes the underlying
    /// QUIC connection.
    ///
    /// - Parameter error: Optional HTTP/3 error code (default: no error)
    public func close(error: HTTP3ErrorCode = .noError) async {
        // Send GOAWAY if we haven't already
        if case .ready = state {
            let lastID: UInt64 = (role == .server) ? nextStreamID : 0
            try? await goaway(lastStreamID: lastID)
        }

        state = .closed
        incomingRequestsContinuation?.finish()
        incomingExtendedConnectContinuation?.finish()
        incomingWebTransportSessionContinuation?.finish()
        datagramRoutingTask?.cancel()
        datagramRoutingTask = nil

        // Close all active WebTransport sessions
        for (_, session) in webTransportSessions {
            await session.abort(applicationErrorCode: 0)
        }
        webTransportSessions.removeAll()

        // Close the QUIC connection
        await quicConnection.close(applicationError: error.rawValue, reason: error.reason)
    }

    // MARK: - Connection Info

    /// Whether the connection is ready for requests
    public var isReady: Bool {
        state == .ready
    }

    /// Whether the connection is in the process of shutting down
    public var isGoingAway: Bool {
        if case .goingAway = state { return true }
        return false
    }

    /// Whether the connection is closed
    public var isClosed: Bool {
        state == .closed
    }

    /// The remote address of the underlying QUIC connection
    public var remoteAddress: SocketAddress {
        quicConnection.remoteAddress
    }

    /// The local address of the underlying QUIC connection
    public var localAddress: SocketAddress? {
        quicConnection.localAddress
    }

    /// A summary of the connection's current state
    public var debugDescription: String {
        var parts = [String]()
        parts.append("role=\(role)")
        parts.append("state=\(state)")
        if let peer = peerSettings {
            parts.append("peerSettings=\(peer)")
        }
        parts.append("localSettings=\(localSettings)")
        return "HTTP3Connection(\(parts.joined(separator: ", ")))"
    }

    // MARK: - Buffered Frame Helpers

    /// Reads the next complete HTTP/3 frame from a stream, buffering across
    /// multiple reads if necessary.
    ///
    /// This is used for the first SETTINGS frame on the control stream where
    /// we need exactly one complete frame and must tolerate fragmentation.
    ///
    /// - Parameters:
    ///   - stream: The QUIC stream to read from
    ///   - buffer: A mutable buffer that accumulates unconsumed bytes.
    ///     On entry it may contain leftover data from a previous read;
    ///     on exit it contains any bytes remaining after the decoded frame.
    /// - Returns: The decoded HTTP/3 frame
    /// - Throws: `HTTP3Error` if the stream ends before a complete frame
    ///   is available, or if the frame is malformed
    func readNextFrame(
        from stream: any QUICStreamProtocol,
        buffer: inout Data
    ) async throws -> HTTP3Frame {
        // Try to decode from what we already have
        while true {
            if !buffer.isEmpty {
                do {
                    var offset = 0
                    let frame = try HTTP3FrameCodec.decode(from: buffer, offset: &offset)
                    // Successfully decoded — remove consumed bytes from buffer
                    buffer = Data(buffer.dropFirst(offset))
                    return frame
                } catch HTTP3FrameCodecError.insufficientData {
                    // Need more data — fall through to read
                } catch {
                    // Malformed frame
                    throw error
                }
            }

            // Read more data from the stream
            let data = try await stream.read()
            if data.isEmpty {
                throw HTTP3Error.missingSettings
            }
            buffer.append(data)
        }
    }

    /// Decodes as many complete HTTP/3 frames as possible from the buffer,
    /// removing consumed bytes.
    ///
    /// Uses `HTTP3FrameCodec.decodeAll` which stops at the first incomplete
    /// frame boundary. The unconsumed bytes remain in the buffer for the
    /// next read cycle.
    ///
    /// - Parameter buffer: A mutable buffer of accumulated stream data.
    ///   Consumed bytes are removed; unconsumed bytes remain.
    /// - Returns: A tuple of (decoded frames, bytes consumed)
    /// - Throws: `HTTP3FrameCodecError` for malformed frames (not for
    ///   insufficient data at the boundary — that's handled internally)
    func decodeFramesFromBuffer(_ buffer: inout Data) throws -> ([HTTP3Frame], Int) {
        guard !buffer.isEmpty else { return ([], 0) }

        let (frames, consumed) = try HTTP3FrameCodec.decodeAll(from: buffer)

        if consumed > 0 {
            buffer = Data(buffer.dropFirst(consumed))
        }

        return (frames, consumed)
    }
}