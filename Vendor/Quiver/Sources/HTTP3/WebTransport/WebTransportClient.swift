/// WebTransport Client (draft-ietf-webtrans-http3)
///
/// A convenience wrapper around `HTTP3Connection` that handles WebTransport
/// session establishment via Extended CONNECT (RFC 9220).
///
/// ## Overview
///
/// `WebTransportClient` simplifies the client-side WebTransport workflow:
/// 1. Configures HTTP/3 settings for WebTransport (Extended CONNECT, datagrams, max sessions)
/// 2. Sends Extended CONNECT requests with `:protocol = webtransport`
/// 3. Creates and manages `WebTransportSession` instances
///
/// ## Usage
///
/// ```swift
/// // Create the client with a QUIC connection
/// let client = WebTransportClient(quicConnection: quicConn)
/// try await client.initialize()
///
/// // Connect to a WebTransport endpoint
/// let session = try await client.connect(
///     authority: "example.com",
///     path: "/webtransport"
/// )
///
/// // Open a bidirectional stream
/// let stream = try await session.openBidirectionalStream()
/// try await stream.write(Data("Hello, WebTransport!".utf8))
/// let response = try await stream.read()
///
/// // Send a datagram
/// try await session.sendDatagram(Data("ping".utf8))
///
/// // Receive datagrams
/// for await datagram in await session.incomingDatagrams {
///     print("Got datagram: \(datagram.count) bytes")
/// }
///
/// // Close the session
/// try await session.close()
///
/// // Close the client
/// await client.close()
/// ```
///
/// ## Thread Safety
///
/// `WebTransportClient` is an `actor`, ensuring all mutable state is
/// accessed serially. This is consistent with Swift 6 concurrency
/// requirements and the project's design principles.
///
/// ## References
///
/// - [draft-ietf-webtrans-http3](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
/// - [RFC 9220: Bootstrapping WebSockets with HTTP/3](https://www.rfc-editor.org/rfc/rfc9220.html)
/// - [RFC 9297: HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297.html)

import Foundation
import Logging
import QUIC
import QUICCore

// MARK: - WebTransport Client

/// A WebTransport client that establishes sessions over HTTP/3.
///
/// Wraps an `HTTP3Connection` and provides a simple API for creating
/// WebTransport sessions via Extended CONNECT.
public actor WebTransportClient {
    private static let logger = QuiverLogging.logger(label: "webtransport.client")

    // MARK: - Types

    /// Client state.
    public enum State: Sendable, Hashable, CustomStringConvertible {
        /// Client created but not initialized
        case idle
        /// Client is initializing (HTTP/3 setup in progress)
        case initializing
        /// Client is ready for session establishment
        case ready
        /// Client is closed
        case closed

        public var description: String {
            switch self {
            case .idle: return "idle"
            case .initializing: return "initializing"
            case .ready: return "ready"
            case .closed: return "closed"
            }
        }
    }

    /// Configuration for the WebTransport client.
    public struct Configuration: Sendable {
        /// HTTP/3 settings to advertise to the server.
        ///
        /// WebTransport-required settings are always merged in:
        /// `enableConnectProtocol`, `enableH3Datagram`, `webtransportMaxSessions`.
        public var settings: HTTP3Settings

        /// Maximum number of concurrent WebTransport sessions to advertise.
        ///
        /// - Default: 1
        public var maxSessions: UInt64

        /// Timeout for waiting for the HTTP/3 connection to become ready.
        ///
        /// - Default: 10 seconds
        public var connectionReadyTimeout: Duration

        /// Timeout for the Extended CONNECT request/response exchange.
        ///
        /// - Default: 10 seconds
        public var connectTimeout: Duration

        /// Creates a WebTransport client configuration.
        ///
        /// - Parameters:
        ///   - settings: Base HTTP/3 settings (default: literal-only QPACK)
        ///   - maxSessions: Max concurrent sessions to advertise (default: 1)
        ///   - connectionReadyTimeout: Ready timeout (default: 10s)
        ///   - connectTimeout: CONNECT timeout (default: 10s)
        public init(
            settings: HTTP3Settings = HTTP3Settings(),
            maxSessions: UInt64 = 1,
            connectionReadyTimeout: Duration = .seconds(10),
            connectTimeout: Duration = .seconds(10)
        ) {
            self.settings = settings
            self.maxSessions = maxSessions
            self.connectionReadyTimeout = connectionReadyTimeout
            self.connectTimeout = connectTimeout
        }

        /// Default configuration.
        public static let `default` = Configuration()
    }

    // MARK: - Properties

    /// Client configuration.
    public let configuration: Configuration

    /// The underlying HTTP/3 connection.
    public private(set) var h3Connection: HTTP3Connection?

    /// The underlying QUIC connection.
    private let quicConnection: any QUICConnectionProtocol

    /// Current client state.
    public private(set) var state: State = .idle

    /// Active WebTransport sessions, keyed by session ID.
    private var activeSessions: [UInt64: WebTransportSession] = [:]

    /// Total sessions established.
    private var totalSessionsCreated: UInt64 = 0

    // MARK: - Initialization

    /// Creates a WebTransport client wrapping a QUIC connection.
    ///
    /// The QUIC connection should already be established (handshake complete).
    /// Call `initialize()` to set up the HTTP/3 layer before creating sessions.
    ///
    /// - Parameters:
    ///   - quicConnection: The underlying QUIC connection
    ///   - configuration: Client configuration (default: `.default`)
    public init(
        quicConnection: any QUICConnectionProtocol,
        configuration: Configuration = .default
    ) {
        self.quicConnection = quicConnection
        self.configuration = configuration
    }

    // MARK: - Connection Lifecycle

    /// Initializes the HTTP/3 layer on the QUIC connection.
    ///
    /// This sets up the HTTP/3 control stream, QPACK streams, and
    /// exchanges SETTINGS with the server. Must be called before
    /// `connect()`.
    ///
    /// - Throws: `HTTP3Error` if initialization fails
    public func initialize() async throws {
        guard state == .idle else {
            throw WebTransportError.internalError(
                "Client already initialized (state: \(state))",
                underlying: nil
            )
        }

        state = .initializing

        // Build HTTP/3 settings with WebTransport requirements
        var settings = configuration.settings
        settings.enableConnectProtocol = true
        settings.enableH3Datagram = true
        settings.webtransportMaxSessions = configuration.maxSessions

        // Create and initialize the HTTP/3 connection
        let connection = HTTP3Connection(
            quicConnection: quicConnection,
            role: .client,
            settings: settings
        )
        self.h3Connection = connection

        do {
            try await connection.initialize()
        } catch {
            state = .idle
            self.h3Connection = nil
            throw WebTransportError.http3Error(
                "Failed to initialize HTTP/3 connection",
                underlying: error
            )
        }

        // Wait for the connection to be ready (SETTINGS exchanged)
        do {
            try await connection.waitForReady(timeout: configuration.connectionReadyTimeout)
        } catch {
            // Connection may still work even if waitForReady times out
            // (some implementations send SETTINGS lazily)
            Self.logger.warning("waitForReady timed out, proceeding anyway: \(error)")
        }

        state = .ready

        Self.logger.info(
            "WebTransport client initialized",
            metadata: ["remote": "\(quicConnection.remoteAddress)"]
        )
    }

    // MARK: - Session Establishment

    /// Establishes a WebTransport session with the server.
    ///
    /// Sends an Extended CONNECT request with `:protocol = webtransport`
    /// and waits for a 200 response. If successful, creates and returns
    /// a `WebTransportSession` that is ready for stream and datagram
    /// operations.
    ///
    /// - Parameters:
    ///   - scheme: The URI scheme (default: "https")
    ///   - authority: The authority (host:port) to connect to
    ///   - path: The path for the WebTransport endpoint (default: "/")
    ///   - headers: Additional headers to include (default: [])
    /// - Returns: An established `WebTransportSession`
    /// - Throws: `WebTransportError` if the session cannot be established
    ///
    /// ## Example
    ///
    /// ```swift
    /// let session = try await client.connect(
    ///     authority: "example.com:4433",
    ///     path: "/webtransport/echo"
    /// )
    /// ```
    public func connect(
        scheme: String = "https",
        authority: String,
        path: String = "/",
        headers: [(String, String)] = []
    ) async throws -> WebTransportSession {
        guard state == .ready else {
            throw WebTransportError.internalError(
                "Client not ready (state: \(state)). Call initialize() first.",
                underlying: nil
            )
        }

        guard let connection = h3Connection else {
            throw WebTransportError.internalError(
                "No HTTP/3 connection available",
                underlying: nil
            )
        }

        // Verify peer supports WebTransport
        let peerSettings = await connection.peerSettings
        if let peer = peerSettings {
            if !peer.enableConnectProtocol {
                throw WebTransportError.peerDoesNotSupportWebTransport(
                    "Peer has not enabled SETTINGS_ENABLE_CONNECT_PROTOCOL"
                )
            }
            if !peer.enableH3Datagram {
                Self.logger.warning(
                    "Peer has not enabled SETTINGS_H3_DATAGRAM — datagrams may not work")
            }
            if let maxSessions = peer.webtransportMaxSessions, maxSessions == 0 {
                throw WebTransportError.maxSessionsExceeded(limit: 0)
            }
        }

        // Build the Extended CONNECT request
        let request = HTTP3Request.webTransportConnect(
            scheme: scheme,
            authority: authority,
            path: path,
            headers: headers
        )

        Self.logger.debug(
            "Sending WebTransport CONNECT",
            metadata: [
                "authority": "\(authority)",
                "path": "\(path)",
            ]
        )

        // Send the Extended CONNECT request
        let (response, connectStream): (HTTP3ResponseHead, any QUICStreamProtocol)
        do {
            (response, connectStream) = try await connection.sendExtendedConnect(request)
        } catch {
            throw WebTransportError.http3Error(
                "Extended CONNECT failed",
                underlying: error
            )
        }

        // Check the response
        guard response.isSuccess else {
            throw WebTransportError.sessionRejected(
                status: response.status,
                reason: response.statusText
            )
        }

        Self.logger.info(
            "WebTransport session accepted by server",
            metadata: [
                "streamID": "\(connectStream.id)",
                "status": "\(response.status)",
            ]
        )

        // Create the session
        let session: WebTransportSession
        do {
            session = try await connection.createClientWebTransportSession(
                connectStream: connectStream,
                response: response
            )
        } catch {
            throw WebTransportError.internalError(
                "Failed to create WebTransport session",
                underlying: error
            )
        }

        // Track the session
        let sessionID = session.sessionID
        activeSessions[sessionID] = session
        totalSessionsCreated += 1

        Self.logger.info(
            "WebTransport session established",
            metadata: [
                "sessionID": "\(sessionID)",
                "authority": "\(authority)",
                "path": "\(path)",
            ]
        )

        return session
    }

    /// Establishes a WebTransport session using a URL string.
    ///
    /// Parses the URL to extract scheme, authority, and path, then
    /// calls `connect(scheme:authority:path:headers:)`.
    ///
    /// - Parameters:
    ///   - url: The WebTransport URL (e.g., "https://example.com:4433/wt")
    ///   - headers: Additional headers to include (default: [])
    /// - Returns: An established `WebTransportSession`
    /// - Throws: `WebTransportError` if the URL is invalid or session fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let session = try await client.connect(url: "https://example.com/wt")
    /// ```
    public func connect(
        url: String,
        headers: [(String, String)] = []
    ) async throws -> WebTransportSession {
        // Parse the URL
        guard let components = URLComponents(string: url) else {
            throw WebTransportError.internalError(
                "Invalid URL: \(url)",
                underlying: nil
            )
        }

        let scheme = components.scheme ?? "https"
        let host = components.host ?? "localhost"
        let port = components.port
        let path = components.path.isEmpty ? "/" : components.path

        let authority: String
        if let port = port {
            authority = "\(host):\(port)"
        } else {
            authority = host
        }

        return try await connect(
            scheme: scheme,
            authority: authority,
            path: path,
            headers: headers
        )
    }

    // MARK: - Session Management

    /// Returns the active session for the given session ID, if any.
    ///
    /// - Parameter sessionID: The session ID to look up
    /// - Returns: The session, or `nil` if not found
    public func session(for sessionID: UInt64) -> WebTransportSession? {
        activeSessions[sessionID]
    }

    /// Removes a session from the active sessions registry.
    ///
    /// Call this after a session has been closed to release resources.
    ///
    /// - Parameter sessionID: The session ID to remove
    /// - Returns: The removed session, or `nil` if not found
    @discardableResult
    public func removeSession(_ sessionID: UInt64) -> WebTransportSession? {
        activeSessions.removeValue(forKey: sessionID)
    }

    /// The number of currently active sessions.
    public var activeSessionCount: Int {
        activeSessions.count
    }

    /// The total number of sessions created by this client.
    public var totalSessions: UInt64 {
        totalSessionsCreated
    }

    // MARK: - Client Lifecycle

    /// Closes all active sessions and the underlying HTTP/3 connection.
    ///
    /// After calling this, no more sessions can be created.
    public func close() async {
        guard state != .closed else { return }
        state = .closed

        // Close all active sessions
        for (_, session) in activeSessions {
            do {
                try await session.close(.noError)
            } catch {
                // Best-effort close
                await session.abort(applicationErrorCode: 0)
            }
        }
        activeSessions.removeAll()

        // Close the HTTP/3 connection
        if let connection = h3Connection {
            await connection.close()
        }
        h3Connection = nil

        Self.logger.info("WebTransport client closed")
    }

    // MARK: - Connection Info

    /// Whether the client is ready to establish sessions.
    public var isReady: Bool {
        state == .ready
    }

    /// Whether the client has been closed.
    public var isClosed: Bool {
        state == .closed
    }

    /// The remote address of the underlying QUIC connection.
    public var remoteAddress: SocketAddress {
        quicConnection.remoteAddress
    }

    /// The local address of the underlying QUIC connection.
    public var localAddress: SocketAddress? {
        quicConnection.localAddress
    }

    /// Whether the peer supports WebTransport (based on received SETTINGS).
    ///
    /// Returns `nil` if SETTINGS have not been received yet.
    public var peerSupportsWebTransport: Bool? {
        get async {
            guard let connection = h3Connection else { return nil }
            let settings = await connection.peerSettings
            return settings?.isWebTransportReady
        }
    }

    /// A debug description of the client.
    public var debugDescription: String {
        var parts = [String]()
        parts.append("state=\(state)")
        parts.append("remote=\(quicConnection.remoteAddress)")
        parts.append("activeSessions=\(activeSessions.count)")
        parts.append("totalSessions=\(totalSessionsCreated)")
        return "WebTransportClient(\(parts.joined(separator: ", ")))"
    }
}

// MARK: - Convenience API (Three-Tier)

extension WebTransportClient {

    // MARK: - Tier 1: Simple (Web API style)

    /// Establishes a WebTransport session from a URL in a single call.
    ///
    /// This is the simplest way to connect. Internally creates a QUIC endpoint,
    /// dials the server, initializes HTTP/3, sends Extended CONNECT, and returns
    /// a ready-to-use session.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let config = WebTransportConfiguration(quic: .testing())
    /// let session = try await WebTransportClient.connect(
    ///     url: "https://example.com:4433/wt",
    ///     configuration: config
    /// )
    ///
    /// let stream = try await session.openBidirectionalStream()
    /// try await stream.write(Data("Hello!".utf8))
    /// ```
    ///
    /// - Parameters:
    ///   - url: The WebTransport URL (e.g. `"https://example.com:4433/wt"`)
    ///   - configuration: WebTransport configuration (QUIC + WT options)
    /// - Returns: An established `WebTransportSession`
    /// - Throws: `WebTransportError` if the URL is invalid, connection fails,
    ///   or the server rejects the session
    public static func connect(
        url: String,
        configuration: WebTransportConfiguration
    ) async throws -> WebTransportSession {
        // Parse URL
        guard let components = URLComponents(string: url) else {
            throw WebTransportError.internalError(
                "Invalid URL: \(url)",
                underlying: nil
            )
        }

        let host = components.host ?? "localhost"
        let port = components.port.map { UInt16($0) } ?? 443
        let scheme = components.scheme ?? "https"
        let path = components.path.isEmpty ? "/" : components.path

        let authority: String
        if let explicitPort = components.port {
            authority = "\(host):\(explicitPort)"
        } else {
            authority = host
        }

        // Create QUIC endpoint and dial
        let endpoint = QUICEndpoint(configuration: configuration.quic)
        let address = SocketAddress(ipAddress: host, port: port)
        let quicConnection = try await endpoint.dial(address: address)

        // Delegate to the shared implementation
        return try await connect(
            scheme: scheme,
            authority: authority,
            path: path,
            over: quicConnection,
            configuration: configuration
        )
    }

    // MARK: - Tier 2: Configurable (bring your own QUIC connection)

    /// Establishes a WebTransport session over an existing QUIC connection.
    ///
    /// HTTP/3 initialization and Extended CONNECT are handled automatically.
    /// Use this when you manage your own QUIC endpoint (e.g. for connection
    /// pooling or custom TLS configuration).
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let quicConn = try await endpoint.dial(address: serverAddress)
    ///
    /// let session = try await WebTransportClient.connect(
    ///     authority: "example.com:4433",
    ///     path: "/wt",
    ///     over: quicConn
    /// )
    /// ```
    ///
    /// - Parameters:
    ///   - authority: The authority (host:port) for the `:authority` pseudo-header
    ///   - path: The path for the WebTransport endpoint (default: `"/"`)
    ///   - quicConnection: An established QUIC connection
    ///   - configuration: WebTransport options (default: sensible defaults with a dummy QUIC config — `.quic` is ignored since you provide the connection)
    /// - Returns: An established `WebTransportSession`
    /// - Throws: `WebTransportError` if HTTP/3 init or session establishment fails
    public static func connect(
        authority: String,
        path: String = "/",
        over quicConnection: any QUICConnectionProtocol,
        configuration: WebTransportConfiguration? = nil
    ) async throws -> WebTransportSession {
        // Use provided config or defaults (QUIC config is unused in Tier 2)
        let config = configuration ?? WebTransportConfiguration(quic: QUICConfiguration())
        return try await connect(
            scheme: "https",
            authority: authority,
            path: path,
            over: quicConnection,
            configuration: config
        )
    }

    // MARK: - Internal shared implementation

    /// Shared implementation for Tier 1 and Tier 2 connect.
    ///
    /// Goes directly to `HTTP3Connection` — no intermediate `WebTransportClient`
    /// actor is created. The call chain is:
    ///
    /// 1. `HTTP3Connection.initialize()` — opens control + QPACK streams, sends SETTINGS
    /// 2. `HTTP3Connection.waitForReady()` — waits for peer SETTINGS
    /// 3. `HTTP3Connection.sendExtendedConnect()` — sends CONNECT, reads response
    /// 4. `HTTP3Connection.createClientWebTransportSession()` — creates session
    private static func connect(
        scheme: String,
        authority: String,
        path: String,
        over quicConnection: any QUICConnectionProtocol,
        configuration: WebTransportConfiguration
    ) async throws -> WebTransportSession {
        // Build HTTP/3 settings with WebTransport requirements
        var settings = configuration.http3Settings
        settings.enableConnectProtocol = true
        settings.enableH3Datagram = true
        settings.webtransportMaxSessions = configuration.maxSessions

        // Create and initialize the HTTP/3 connection directly
        let h3 = HTTP3Connection(
            quicConnection: quicConnection,
            role: .client,
            settings: settings
        )

        do {
            try await h3.initialize()
        } catch {
            throw WebTransportError.http3Error(
                "Failed to initialize HTTP/3 connection",
                underlying: error
            )
        }

        // Wait for SETTINGS exchange
        do {
            try await h3.waitForReady(timeout: configuration.connectionReadyTimeout)
        } catch {
            // Some implementations send SETTINGS lazily — proceed anyway
            logger.warning("waitForReady timed out, proceeding anyway: \(error)")
        }

        // Verify peer supports WebTransport
        let peerSettings = await h3.peerSettings
        if let peer = peerSettings {
            if !peer.enableConnectProtocol {
                throw WebTransportError.peerDoesNotSupportWebTransport(
                    "Peer has not enabled SETTINGS_ENABLE_CONNECT_PROTOCOL"
                )
            }
            if !peer.enableH3Datagram {
                logger.warning("Peer has not enabled SETTINGS_H3_DATAGRAM — datagrams may not work")
            }
            if let maxSessions = peer.webtransportMaxSessions, maxSessions == 0 {
                throw WebTransportError.maxSessionsExceeded(limit: 0)
            }
        }

        // Build and send Extended CONNECT
        let request = HTTP3Request.webTransportConnect(
            scheme: scheme,
            authority: authority,
            path: path,
            headers: configuration.headers
        )

        let (response, connectStream): (HTTP3ResponseHead, any QUICStreamProtocol)
        do {
            (response, connectStream) = try await h3.sendExtendedConnect(request)
        } catch {
            throw WebTransportError.http3Error(
                "Extended CONNECT failed",
                underlying: error
            )
        }

        guard response.isSuccess else {
            throw WebTransportError.sessionRejected(
                status: response.status,
                reason: response.statusText
            )
        }

        // Create the session directly on the HTTP/3 connection
        do {
            return try await h3.createClientWebTransportSession(
                connectStream: connectStream,
                response: response
            )
        } catch {
            throw WebTransportError.internalError(
                "Failed to create WebTransport session",
                underlying: error
            )
        }
    }
}
