/// WebTransport Session (draft-ietf-webtrans-http3)
///
/// The core actor managing a single WebTransport session over HTTP/3.
/// A session is established via an Extended CONNECT request (RFC 9220)
/// and identified by the QUIC stream ID of that CONNECT stream.
///
/// ## Session Lifecycle
///
/// ```
/// Client                                     Server
///   |                                          |
///   |  Extended CONNECT (:protocol=webtransport)|
///   |----------------------------------------->|
///   |                                          |
///   |  200 OK (session accepted)               |
///   |<-----------------------------------------|
///   |                                          |
///   |  === Session Established ===             |
///   |                                          |
///   |  Open bidi/uni streams (session-scoped)  |
///   |<---------------------------------------->|
///   |                                          |
///   |  QUIC DATAGRAMs (quarter-stream-ID)      |
///   |<---------------------------------------->|
///   |                                          |
///   |  CLOSE_WEBTRANSPORT_SESSION capsule      |
///   |<----- or ----->                          |
///   |                                          |
///   |  === Session Closed ===                  |
/// ```
///
/// ## Stream Association
///
/// - **Bidirectional streams**: First varint = session ID, then app data
/// - **Unidirectional streams**: Stream type 0x54, then session ID varint, then app data
///
/// ## Datagram Association (RFC 9297)
///
/// QUIC DATAGRAM frame payload = Quarter Stream ID (varint) + app data,
/// where Quarter Stream ID = CONNECT stream ID / 4.
///
/// ## Thread Safety
///
/// `WebTransportSession` is an `actor`, ensuring all mutable state is
/// accessed serially. This is consistent with Swift 6 concurrency
/// requirements and the project's design principles.
///
/// ## References
///
/// - [draft-ietf-webtrans-http3](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
/// - [RFC 9297: HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297.html)
/// - [RFC 9220: Bootstrapping WebSockets with HTTP/3](https://www.rfc-editor.org/rfc/rfc9220.html)

import Foundation
import QUICCore
import QUICStream
import QUIC
import Logging

// MARK: - WebTransport Session

/// A WebTransport session over HTTP/3.
///
/// Manages the lifecycle of a single WebTransport session including:
/// - Opening and accepting bidirectional and unidirectional streams
/// - Sending and receiving QUIC datagrams scoped to this session
/// - Graceful and abrupt session closure via capsules
///
/// ## Usage (Server-side)
///
/// ```swift
/// server.onExtendedConnect { context in
///     guard context.request.isWebTransportConnect else {
///         try await context.reject(status: 501)
///         return
///     }
///     try await context.accept()
///
///     let session = WebTransportSession(
///         connectStream: context.stream,
///         connection: h3Connection,
///         role: .server
///     )
///     try await session.start()
///
///     // Accept incoming streams
///     for await stream in session.incomingBidirectionalStreams {
///         let data = try await stream.read()
///         try await stream.write(data)  // Echo
///         try await stream.closeWrite()
///     }
/// }
/// ```
///
/// ## Usage (Client-side)
///
/// ```swift
/// let (response, connectStream) = try await h3Connection.sendExtendedConnect(
///     HTTP3Request.webTransportConnect(authority: "example.com", path: "/wt")
/// )
/// guard response.isSuccess else { return }
///
/// let session = WebTransportSession(
///     connectStream: connectStream,
///     connection: h3Connection,
///     role: .client
/// )
/// try await session.start()
///
/// let stream = try await session.openBidirectionalStream()
/// try await stream.write(Data("Hello".utf8))
/// ```
public actor WebTransportSession {
    private static let logger = QuiverLogging.logger(label: "webtransport.session")

    // MARK: - Types

    /// The role of this endpoint in the session.
    public enum Role: Sendable, Hashable {
        /// Client role — initiated the Extended CONNECT request.
        case client
        /// Server role — accepted the Extended CONNECT request.
        case server
    }

    // MARK: - Properties

    /// The session ID — the QUIC stream ID of the CONNECT stream.
    ///
    /// This value uniquely identifies the session within the HTTP/3
    /// connection and is used to associate streams and datagrams.
    public let sessionID: UInt64

    /// The quarter stream ID for datagram association (RFC 9297).
    ///
    /// Equal to `sessionID / 4`. Used as the prefix varint in
    /// QUIC DATAGRAM frames to associate datagrams with this session.
    public let quarterStreamID: UInt64

    /// The QUIC stream underlying the Extended CONNECT request.
    ///
    /// Capsules (CLOSE, DRAIN) are exchanged on this stream's data
    /// portion after the HTTP headers.
    public let connectStream: any QUICStreamProtocol

    /// The HTTP/3 connection this session belongs to.
    public let connection: HTTP3Connection

    /// The role of this endpoint.
    public let role: Role

    /// The current session state.
    public private(set) var state: WebTransportSessionState = .connecting

    // MARK: - Stream Tracking

    /// Active bidirectional streams belonging to this session.
    private var activeBidiStreams: [UInt64: WebTransportStream] = [:]

    /// Active unidirectional streams belonging to this session.
    private var activeUniStreams: [UInt64: WebTransportStream] = [:]

    // MARK: - Incoming Stream Delivery

    /// Continuation for delivering incoming bidirectional streams.
    private var incomingBidiContinuation: AsyncStream<WebTransportStream>.Continuation?

    /// Continuation for delivering incoming unidirectional streams.
    private var incomingUniContinuation: AsyncStream<WebTransportStream>.Continuation?

    /// Continuation for delivering incoming datagrams.
    private var incomingDatagramContinuation: AsyncStream<Data>.Continuation?

    /// Continuation for delivering capsule events.
    private var capsuleEventContinuation: AsyncStream<WebTransportCapsule>.Continuation?

    /// Stream of incoming bidirectional streams from the peer.
    ///
    /// Use this to receive bidirectional streams initiated by the remote peer:
    /// ```swift
    /// for await stream in session.incomingBidirectionalStreams {
    ///     Task { await handleStream(stream) }
    /// }
    /// ```
    public private(set) var incomingBidirectionalStreams: AsyncStream<WebTransportStream>

    /// Stream of incoming unidirectional streams from the peer.
    ///
    /// Use this to receive unidirectional streams initiated by the remote peer:
    /// ```swift
    /// for await stream in session.incomingUnidirectionalStreams {
    ///     let data = try await stream.read()
    ///     // Process incoming data...
    /// }
    /// ```
    public private(set) var incomingUnidirectionalStreams: AsyncStream<WebTransportStream>

    /// Stream of incoming datagrams from the peer.
    ///
    /// Datagrams are unreliable, unordered messages associated with
    /// this session via the quarter stream ID prefix.
    ///
    /// ```swift
    /// for await datagram in session.incomingDatagrams {
    ///     print("Received \(datagram.count) bytes")
    /// }
    /// ```
    public private(set) var incomingDatagrams: AsyncStream<Data>

    /// Stream of capsule events from the CONNECT stream.
    ///
    /// Primarily used to observe CLOSE and DRAIN capsules.
    /// Most applications should use the higher-level close notification
    /// rather than consuming capsules directly.
    public private(set) var capsuleEvents: AsyncStream<WebTransportCapsule>

    // MARK: - Capsule Buffer

    /// Buffer for incomplete capsule data from the CONNECT stream.
    private var capsuleBuffer: Data = Data()

    // MARK: - Background Tasks

    /// Task for reading capsules from the CONNECT stream.
    private var capsuleReaderTask: Task<Void, Never>?

    // MARK: - Close Info

    /// The close information if the session was closed with a CLOSE capsule.
    public private(set) var closeInfo: WebTransportSessionCloseInfo?

    // MARK: - Initialization

    /// Creates a WebTransport session.
    ///
    /// The session starts in the `.connecting` state. Call `start()` to
    /// transition to `.established` and begin processing capsules.
    ///
    /// - Parameters:
    ///   - connectStream: The QUIC stream of the Extended CONNECT request
    ///   - connection: The HTTP/3 connection this session belongs to
    ///   - role: The endpoint role (client or server)
    public init(
        connectStream: any QUICStreamProtocol,
        connection: HTTP3Connection,
        role: Role
    ) {
        self.connectStream = connectStream
        self.connection = connection
        self.role = role
        self.sessionID = connectStream.id
        self.quarterStreamID = connectStream.id / 4

        // Create incoming bidirectional streams
        var bidiCont: AsyncStream<WebTransportStream>.Continuation!
        self.incomingBidirectionalStreams = AsyncStream { cont in
            bidiCont = cont
        }
        self.incomingBidiContinuation = bidiCont

        // Create incoming unidirectional streams
        var uniCont: AsyncStream<WebTransportStream>.Continuation!
        self.incomingUnidirectionalStreams = AsyncStream { cont in
            uniCont = cont
        }
        self.incomingUniContinuation = uniCont

        // Create incoming datagrams stream
        var datagramCont: AsyncStream<Data>.Continuation!
        self.incomingDatagrams = AsyncStream { cont in
            datagramCont = cont
        }
        self.incomingDatagramContinuation = datagramCont

        // Create capsule events stream
        var capsuleCont: AsyncStream<WebTransportCapsule>.Continuation!
        self.capsuleEvents = AsyncStream { cont in
            capsuleCont = cont
        }
        self.capsuleEventContinuation = capsuleCont

        Self.logger.debug(
            "WebTransport session created",
            metadata: [
                "sessionID": "\(sessionID)",
                "quarterStreamID": "\(quarterStreamID)",
                "role": "\(role)",
            ]
        )
    }

    deinit {
        incomingBidiContinuation?.finish()
        incomingUniContinuation?.finish()
        incomingDatagramContinuation?.finish()
        capsuleEventContinuation?.finish()
    }

    // MARK: - Session Lifecycle

    /// Starts the WebTransport session.
    ///
    /// Transitions the session from `.connecting` to `.established` and
    /// begins reading capsules from the CONNECT stream in the background.
    ///
    /// - Throws: `WebTransportError` if the session is in an invalid state
    public func start() throws {
        guard state == .connecting else {
            throw WebTransportError.internalError(
                "Cannot start session in state \(state)",
                underlying: nil
            )
        }

        state = .established

        // Start reading capsules from the CONNECT stream
        capsuleReaderTask = Task { [weak self] in
            await self?.readCapsuleLoop()
        }

        Self.logger.info(
            "WebTransport session established",
            metadata: ["sessionID": "\(sessionID)"]
        )
    }

    /// Closes the session gracefully by sending a CLOSE_WEBTRANSPORT_SESSION
    /// capsule on the CONNECT stream.
    ///
    /// After calling this:
    /// 1. A CLOSE capsule is sent to the peer
    /// 2. The CONNECT stream's write side is closed (FIN)
    /// 3. All incoming stream continuations are finished
    /// 4. The session transitions to `.closed`
    ///
    /// - Parameter info: The close information (default: no error)
    /// - Throws: If sending the close capsule fails
    public func close(_ info: WebTransportSessionCloseInfo = .noError) async throws {
        guard state == .established || state == .draining else {
            // Already closed or not yet established — no-op
            return
        }

        Self.logger.info(
            "Closing WebTransport session",
            metadata: [
                "sessionID": "\(sessionID)",
                "errorCode": "\(info.errorCode)",
                "reason": "\(info.reason)",
            ]
        )

        // Send CLOSE capsule on the CONNECT stream
        let capsuleData = WebTransportCapsuleCodec.encodeClose(
            errorCode: info.errorCode,
            reason: info.reason
        )

        do {
            try await connectStream.write(capsuleData)
            try await connectStream.closeWrite()
        } catch {
            Self.logger.warning(
                "Failed to send CLOSE capsule: \(error)",
                metadata: ["sessionID": "\(sessionID)"]
            )
        }

        closeInfo = info
        transitionToClosed(info)
    }

    /// Initiates a graceful drain of the session.
    ///
    /// Sends a DRAIN_WEBTRANSPORT_SESSION capsule to inform the peer
    /// that no new streams should be opened. Existing streams can
    /// continue until completion.
    ///
    /// After draining, the session should be closed with `close()`.
    ///
    /// - Throws: If sending the drain capsule fails
    public func drain() async throws {
        guard state == .established else {
            return
        }

        Self.logger.info(
            "Draining WebTransport session",
            metadata: ["sessionID": "\(sessionID)"]
        )

        state = .draining

        let drainData = WebTransportCapsuleCodec.encodeDrain()
        try await connectStream.write(drainData)
    }

    /// Abruptly terminates the session by resetting the CONNECT stream.
    ///
    /// This is a hard close — no capsules are sent. The QUIC layer
    /// sends a RESET_STREAM frame, immediately terminating the session.
    ///
    /// - Parameter applicationErrorCode: Application error code (default: 0)
    public func abort(applicationErrorCode: UInt32 = 0) async {
        Self.logger.info(
            "Aborting WebTransport session",
            metadata: [
                "sessionID": "\(sessionID)",
                "errorCode": "\(applicationErrorCode)",
            ]
        )

        let http3Code = WebTransportStreamErrorCode.toHTTP3ErrorCode(applicationErrorCode)
        await connectStream.reset(errorCode: http3Code)

        let info = WebTransportSessionCloseInfo(
            errorCode: applicationErrorCode,
            reason: "Session aborted"
        )
        transitionToClosed(info)
    }

    // MARK: - Stream Operations

    /// Opens a new bidirectional stream associated with this session.
    ///
    /// Creates a QUIC bidirectional stream and writes the session ID
    /// as the first varint, associating it with this WebTransport session.
    ///
    /// - Parameter priority: The scheduling priority for this stream.
    ///   Defaults to `.webTransportBidi` (urgency 3, incremental).
    /// - Returns: A `WebTransportStream` ready for application data
    /// - Throws: `WebTransportError` if the session is not established
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Default priority
    /// let stream = try await session.openBidirectionalStream()
    /// try await stream.write(Data("request".utf8))
    /// let response = try await stream.read()
    ///
    /// // High priority stream
    /// let urgent = try await session.openBidirectionalStream(priority: .high)
    /// ```
    public func openBidirectionalStream(
        priority: StreamPriority = .webTransportBidi
    ) async throws -> WebTransportStream {
        guard state == .established else {
            throw WebTransportError.sessionNotEstablished
        }

        let quicStream = try await connection.quicConnection.openStream()

        // Write session ID framing
        try await WebTransportStreamFraming.writeBidirectionalHeader(
            to: quicStream,
            sessionID: sessionID
        )

        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: sessionID,
            direction: .bidirectional,
            isLocal: true,
            priority: priority
        )

        activeBidiStreams[quicStream.id] = wtStream

        // Register with the HTTP/3 scheduler so this stream participates
        // in priority-ordered data scheduling (RFC 9218).
        await connection.handlePriorityUpdate(streamID: quicStream.id, priority: priority)
        await connection.registerActiveResponseStream(quicStream.id, priority: priority)

        Self.logger.trace(
            "Opened bidi stream",
            metadata: [
                "sessionID": "\(sessionID)",
                "streamID": "\(quicStream.id)",
                "priority": "\(priority)",
            ]
        )

        return wtStream
    }

    /// Opens a new unidirectional stream associated with this session.
    ///
    /// Creates a QUIC unidirectional stream and writes the WebTransport
    /// stream type (0x54) followed by the session ID varint.
    ///
    /// - Parameter priority: The scheduling priority for this stream.
    ///   Defaults to `.webTransportUni` (urgency 4, non-incremental).
    /// - Returns: A `WebTransportStream` ready for writing application data
    /// - Throws: `WebTransportError` if the session is not established
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Default priority
    /// let stream = try await session.openUnidirectionalStream()
    /// try await stream.write(Data("notification".utf8))
    /// try await stream.closeWrite()
    ///
    /// // Low priority background push
    /// let bg = try await session.openUnidirectionalStream(priority: .background)
    /// ```
    public func openUnidirectionalStream(
        priority: StreamPriority = .webTransportUni
    ) async throws -> WebTransportStream {
        guard state == .established else {
            throw WebTransportError.sessionNotEstablished
        }

        let quicStream = try await connection.quicConnection.openUniStream()

        // Write stream type + session ID framing
        try await WebTransportStreamFraming.writeUnidirectionalHeader(
            to: quicStream,
            sessionID: sessionID
        )

        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: sessionID,
            direction: .unidirectional,
            isLocal: true,
            priority: priority
        )

        activeUniStreams[quicStream.id] = wtStream

        // Register with the HTTP/3 scheduler so this stream participates
        // in priority-ordered data scheduling (RFC 9218).
        await connection.handlePriorityUpdate(streamID: quicStream.id, priority: priority)
        await connection.registerActiveResponseStream(quicStream.id, priority: priority)

        Self.logger.trace(
            "Opened uni stream",
            metadata: [
                "sessionID": "\(sessionID)",
                "streamID": "\(quicStream.id)",
                "priority": "\(priority)",
            ]
        )

        return wtStream
    }

    // MARK: - Datagram Operations

    /// Sends a datagram associated with this session.
    ///
    /// The datagram is framed as a QUIC DATAGRAM frame with the
    /// quarter stream ID prefix (RFC 9297). Datagrams are unreliable
    /// and may be dropped by the network.
    ///
    /// - Parameter data: The datagram payload
    /// - Throws: `WebTransportError` if the session is not established
    ///   or datagrams are not supported
    ///
    /// ## Wire Format
    ///
    /// ```
    /// QUIC DATAGRAM Frame Payload {
    ///   Quarter Stream ID (i),    // sessionID / 4
    ///   Payload (..)              // Application data
    /// }
    /// ```
    ///
    /// ## Example
    ///
    /// ```swift
    /// try await session.sendDatagram(Data("ping".utf8))
    /// ```
    public func sendDatagram(_ data: Data) async throws {
        guard state == .established else {
            throw WebTransportError.sessionNotEstablished
        }

        // Construct the datagram payload: quarter stream ID + data
        var payload = Data()
        Varint(quarterStreamID).encode(to: &payload)
        payload.append(data)

        // Send via the QUIC connection's datagram API (RFC 9221)
        do {
            try await connection.quicConnection.sendDatagram(payload)
        } catch {
            throw WebTransportError.datagramError(
                "Failed to send datagram for session \(sessionID)",
                underlying: error
            )
        }

        Self.logger.trace(
            "Datagram sent",
            metadata: [
                "sessionID": "\(sessionID)",
                "quarterStreamID": "\(quarterStreamID)",
                "payloadSize": "\(data.count)",
                "totalSize": "\(payload.count)",
            ]
        )
    }

    /// Delivers an incoming datagram payload to this session.
    ///
    /// Called by the HTTP/3 connection or WebTransport manager when
    /// a QUIC DATAGRAM is received with a quarter stream ID matching
    /// this session. The quarter stream ID prefix has already been
    /// stripped — `data` is the application payload only.
    ///
    /// - Parameter data: The application datagram payload (without quarter stream ID prefix)
    public func deliverDatagram(_ data: Data) {
        guard state == .established || state == .draining else {
            return
        }

        incomingDatagramContinuation?.yield(data)
    }

    // MARK: - Incoming Stream Delivery

    /// Delivers an incoming bidirectional stream to this session.
    ///
    /// Called by the HTTP/3 connection or WebTransport manager when
    /// a QUIC bidirectional stream arrives with a session ID matching
    /// this session. The session ID framing has already been consumed.
    ///
    /// - Parameters:
    ///   - quicStream: The underlying QUIC stream
    ///   - initialData: Any data already read after the session ID varint
    public func deliverIncomingBidirectionalStream(
        _ quicStream: any QUICStreamProtocol,
        initialData: Data = Data()
    ) {
        guard state == .established || state == .draining else {
            Task {
                await quicStream.reset(
                    errorCode: WebTransportStreamErrorCode.toHTTP3ErrorCode(0)
                )
            }
            return
        }

        let priority = StreamPriority.webTransportBidi
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: sessionID,
            direction: .bidirectional,
            isLocal: false,
            priority: priority,
            initialData: initialData
        )

        activeBidiStreams[quicStream.id] = wtStream

        // Register incoming stream with the HTTP/3 scheduler
        Task {
            await connection.handlePriorityUpdate(streamID: quicStream.id, priority: priority)
            await connection.registerActiveResponseStream(quicStream.id, priority: priority)
        }

        incomingBidiContinuation?.yield(wtStream)

        Self.logger.trace(
            "Delivered incoming bidi stream",
            metadata: [
                "sessionID": "\(sessionID)",
                "streamID": "\(quicStream.id)",
                "priority": "\(priority)",
            ]
        )
    }

    /// Delivers an incoming unidirectional stream to this session.
    ///
    /// Called by the HTTP/3 connection or WebTransport manager when
    /// a QUIC unidirectional stream of type 0x54 arrives with a session
    /// ID matching this session. Both the stream type byte and session
    /// ID have already been consumed.
    ///
    /// - Parameters:
    ///   - quicStream: The underlying QUIC stream
    ///   - initialData: Any data already read after the session ID varint
    public func deliverIncomingUnidirectionalStream(
        _ quicStream: any QUICStreamProtocol,
        initialData: Data = Data()
    ) {
        guard state == .established || state == .draining else {
            Task {
                await quicStream.reset(
                    errorCode: WebTransportStreamErrorCode.toHTTP3ErrorCode(0)
                )
            }
            return
        }

        let priority = StreamPriority.webTransportUni
        let wtStream = WebTransportStream(
            quicStream: quicStream,
            sessionID: sessionID,
            direction: .unidirectional,
            isLocal: false,
            priority: priority,
            initialData: initialData
        )

        activeUniStreams[quicStream.id] = wtStream

        // Register incoming stream with the HTTP/3 scheduler
        Task {
            await connection.handlePriorityUpdate(streamID: quicStream.id, priority: priority)
            await connection.registerActiveResponseStream(quicStream.id, priority: priority)
        }

        incomingUniContinuation?.yield(wtStream)

        Self.logger.trace(
            "Delivered incoming uni stream",
            metadata: [
                "sessionID": "\(sessionID)",
                "streamID": "\(quicStream.id)",
                "priority": "\(priority)",
            ]
        )
    }

    // MARK: - Stream Cleanup

    /// Removes a stream from the session's tracking.
    ///
    /// Called when a stream has been fully closed or reset.
    ///
    /// - Parameter streamID: The QUIC stream ID to remove
    func removeStream(_ streamID: UInt64) {
        activeBidiStreams.removeValue(forKey: streamID)
        activeUniStreams.removeValue(forKey: streamID)

        // Unregister from the HTTP/3 scheduler
        Task {
            await connection.unregisterActiveResponseStream(streamID)
        }
    }

    // MARK: - Session Info

    /// The number of active bidirectional streams.
    public var activeBidirectionalStreamCount: Int {
        activeBidiStreams.count
    }

    /// The number of active unidirectional streams.
    public var activeUnidirectionalStreamCount: Int {
        activeUniStreams.count
    }

    /// The total number of active streams (bidi + uni).
    var activeStreamCount: Int {
        activeBidiStreams.count + activeUniStreams.count
    }

    // MARK: - Priority Management (RFC 9218)

    /// Sets the priority of a WebTransport stream.
    ///
    /// Updates the stream's priority in the HTTP/3 scheduler, which
    /// affects the order in which data is sent for concurrent streams.
    /// If the local endpoint is the client, a PRIORITY_UPDATE frame is
    /// sent on the control stream to inform the server.
    ///
    /// - Parameters:
    ///   - priority: The new priority
    ///   - streamID: The QUIC stream ID of the WebTransport stream
    /// - Throws: `WebTransportError` if the stream is not part of this session
    ///
    /// ## Example
    ///
    /// ```swift
    /// let stream = try await session.openBidirectionalStream()
    /// // ... later, reprioritize
    /// try await session.setStreamPriority(.highest, for: stream.id)
    /// ```
    public func setStreamPriority(
        _ priority: StreamPriority,
        for streamID: UInt64
    ) async throws {
        // Verify the stream belongs to this session
        guard activeBidiStreams[streamID] != nil || activeUniStreams[streamID] != nil else {
            throw WebTransportError.unknownStream(streamID)
        }

        // Update the HTTP/3 connection's priority tracking
        await connection.handlePriorityUpdate(streamID: streamID, priority: priority)
        await connection.registerActiveResponseStream(streamID, priority: priority)

        // If we're the client, send PRIORITY_UPDATE to the server
        if role == .client {
            try await connection.sendPriorityUpdate(streamID: streamID, priority: priority)
        }

        Self.logger.trace(
            "Updated stream priority",
            metadata: [
                "sessionID": "\(sessionID)",
                "streamID": "\(streamID)",
                "priority": "\(priority)",
            ]
        )
    }

    /// Returns the current priority for a WebTransport stream.
    ///
    /// Queries the HTTP/3 connection's priority tracking, which reflects
    /// any dynamic PRIORITY_UPDATE changes.
    ///
    /// - Parameter streamID: The QUIC stream ID of the WebTransport stream
    /// - Returns: The stream's effective priority, or `.default` if not tracked
    public func streamPriority(for streamID: UInt64) async -> StreamPriority {
        await connection.priority(for: streamID)
    }

    /// Returns all active WebTransport streams ordered by scheduling priority.
    ///
    /// Streams are ordered according to RFC 9218 rules:
    /// 1. Lower urgency values first (urgency 0 = highest priority)
    /// 2. Non-incremental streams before incremental at same urgency
    /// 3. Fair round-robin within same urgency group
    ///
    /// This is useful for applications that want to inspect or log
    /// the current scheduling order.
    ///
    /// - Returns: Array of `WebTransportStream` in scheduling order
    public func priorityOrderedStreams() async -> [WebTransportStream] {
        let orderedIDs = await connection.priorityOrderedStreamIDs()

        // Filter to only streams belonging to this session
        let sessionStreamIDs = Set(activeBidiStreams.keys).union(activeUniStreams.keys)
        var result: [WebTransportStream] = []

        for streamID in orderedIDs {
            guard sessionStreamIDs.contains(streamID) else { continue }
            if let stream = activeBidiStreams[streamID] {
                result.append(stream)
            } else if let stream = activeUniStreams[streamID] {
                result.append(stream)
            }
        }

        return result
    }

    /// Whether the session is established and operational.
    public var isEstablished: Bool {
        state == .established
    }

    /// Whether the session is draining (no new streams allowed).
    public var isDraining: Bool {
        state == .draining
    }

    /// Whether the session has been closed.
    public var isClosed: Bool {
        if case .closed = state { return true }
        return false
    }

    /// A debug description of the session.
    public var debugDescription: String {
        var parts = [String]()
        parts.append("sessionID=\(sessionID)")
        parts.append("state=\(state)")
        parts.append("role=\(role)")
        parts.append("bidiStreams=\(activeBidiStreams.count)")
        parts.append("uniStreams=\(activeUniStreams.count)")
        return "WebTransportSession(\(parts.joined(separator: ", ")))"
    }

    // MARK: - Capsule Reading Loop

    /// Background loop that reads capsules from the CONNECT stream.
    ///
    /// Capsules are framed messages on the CONNECT stream's data portion.
    /// This loop accumulates data and decodes capsules incrementally.
    private func readCapsuleLoop() async {
        Self.logger.trace(
            "Capsule reader started",
            metadata: ["sessionID": "\(sessionID)"]
        )

        var receivedFIN = false

        while state == .established || state == .draining {
            let data: Data
            do {
                data = try await connectStream.read()
            } catch {
                Self.logger.trace(
                    "CONNECT stream read error (session may be closing): \(error)",
                    metadata: ["sessionID": "\(sessionID)"]
                )
                break
            }

            if data.isEmpty {
                // FIN received on CONNECT stream — session is ending
                Self.logger.debug(
                    "CONNECT stream FIN received",
                    metadata: ["sessionID": "\(sessionID)"]
                )
                receivedFIN = true
                break
            }

            capsuleBuffer.append(data)

            // Decode all complete capsules from the buffer
            do {
                let (capsules, consumed) = try WebTransportCapsuleCodec.decodeAll(from: capsuleBuffer)

                if consumed > 0 {
                    capsuleBuffer = Data(capsuleBuffer.dropFirst(consumed))
                }

                for capsule in capsules {
                    await handleCapsule(capsule)
                }
            } catch {
                Self.logger.warning(
                    "Capsule decode error: \(error)",
                    metadata: ["sessionID": "\(sessionID)"]
                )
                // On decode error, close the session
                let info = WebTransportSessionCloseInfo(
                    errorCode: WebTransportErrorCode.protocolViolation,
                    reason: "Capsule decode error"
                )
                transitionToClosed(info)
                break
            }
        }

        // If we exited the loop without an explicit close, decide what to do.
        guard !isClosed else {
            // Already closed by handleCapsule or a decode-error path above — nothing to do.
            Self.logger.trace(
                "Capsule reader: session already closed",
                metadata: ["sessionID": "\(sessionID)"]
            )
            return
        }

        if receivedFIN {
            // RFC 9297: When the CONNECT stream is closed (FIN received),
            // the associated WebTransport session MUST be terminated.
            Self.logger.debug(
                "Capsule reader: FIN received, closing session",
                metadata: ["sessionID": "\(sessionID)"]
            )
            transitionToClosed(nil)
            return
        }

        // The loop exited for an unexpected reason (e.g. read error while the
        // session was still active). Transition to closed.
        transitionToClosed(nil)

        Self.logger.trace(
            "Capsule reader stopped",
            metadata: ["sessionID": "\(sessionID)"]
        )
    }

    /// Handles a decoded capsule received on the CONNECT stream.
    ///
    /// - Parameter capsule: The decoded capsule
    private func handleCapsule(_ capsule: WebTransportCapsule) async {
        Self.logger.debug(
            "Received capsule: \(capsule)",
            metadata: ["sessionID": "\(sessionID)"]
        )

        // Deliver to the capsule events stream
        capsuleEventContinuation?.yield(capsule)

        switch capsule {
        case .close(let info):
            Self.logger.info(
                "Received CLOSE capsule",
                metadata: [
                    "sessionID": "\(sessionID)",
                    "errorCode": "\(info.errorCode)",
                    "reason": "\(info.reason)",
                ]
            )
            closeInfo = info
            transitionToClosed(info)

        case .drain:
            Self.logger.info(
                "Received DRAIN capsule",
                metadata: ["sessionID": "\(sessionID)"]
            )
            if state == .established {
                state = .draining
            }

        case .unknown(let type, _):
            // Per RFC 9297, unknown capsule types MUST be ignored
            Self.logger.trace(
                "Ignoring unknown capsule type 0x\(String(type, radix: 16))",
                metadata: ["sessionID": "\(sessionID)"]
            )
        }
    }

    // MARK: - State Transitions

    /// Transitions the session to the closed state and cleans up resources.
    ///
    /// - Parameter info: Optional close information
    private func transitionToClosed(_ info: WebTransportSessionCloseInfo?) {
        guard !isClosed else { return }

        state = .closed(info)

        // Cancel background tasks
        capsuleReaderTask?.cancel()
        capsuleReaderTask = nil

        // Finish all continuations
        incomingBidiContinuation?.finish()
        incomingBidiContinuation = nil

        incomingUniContinuation?.finish()
        incomingUniContinuation = nil

        incomingDatagramContinuation?.finish()
        incomingDatagramContinuation = nil

        capsuleEventContinuation?.finish()
        capsuleEventContinuation = nil

        // Unregister all active streams from the HTTP/3 scheduler
        let allStreamIDs = Array(activeBidiStreams.keys) + Array(activeUniStreams.keys)
        if !allStreamIDs.isEmpty {
            Task {
                for streamID in allStreamIDs {
                    await connection.unregisterActiveResponseStream(streamID)
                }
            }
        }

        // Clear active streams
        activeBidiStreams.removeAll()
        activeUniStreams.removeAll()

        Self.logger.info(
            "WebTransport session closed",
            metadata: [
                "sessionID": "\(sessionID)",
                "closeInfo": "\(info?.description ?? "none")",
            ]
        )
    }
}

// MARK: - Datagram Framing Helpers

extension WebTransportSession {

    /// Parses a received QUIC DATAGRAM frame payload to extract the
    /// quarter stream ID and application payload.
    ///
    /// This is a static helper used by the HTTP/3 connection or
    /// WebTransport manager to route datagrams to the correct session.
    ///
    /// ## Wire Format
    ///
    /// ```
    /// QUIC DATAGRAM Payload {
    ///   Quarter Stream ID (i),
    ///   Application Payload (..)
    /// }
    /// ```
    ///
    /// - Parameter datagramPayload: The full QUIC DATAGRAM frame payload
    /// - Returns: A tuple of (quarter stream ID, application payload),
    ///   or `nil` if the payload is too short
    /// - Throws: If the varint is malformed
    public static func parseDatagram(
        _ datagramPayload: Data
    ) throws -> (quarterStreamID: UInt64, payload: Data)? {
        guard !datagramPayload.isEmpty else { return nil }

        let (varint, consumed) = try Varint.decode(from: datagramPayload)
        let appPayload: Data
        if consumed < datagramPayload.count {
            appPayload = Data(datagramPayload.dropFirst(consumed))
        } else {
            appPayload = Data()
        }

        return (varint.value, appPayload)
    }

    /// Frames an application datagram for sending as a QUIC DATAGRAM.
    ///
    /// Prepends the quarter stream ID varint to the application payload.
    ///
    /// - Parameters:
    ///   - payload: The application datagram payload
    ///   - quarterStreamID: The quarter stream ID for this session
    /// - Returns: The framed datagram payload ready for the QUIC DATAGRAM frame
    public static func frameDatagram(
        payload: Data,
        quarterStreamID: UInt64
    ) -> Data {
        var framed = Data()
        Varint(quarterStreamID).encode(to: &framed)
        framed.append(payload)
        return framed
    }
}
