/// WebTransport Server (draft-ietf-webtrans-http3)
///
/// A convenience wrapper around `HTTP3Server` that automatically handles
/// WebTransport session establishment via Extended CONNECT (RFC 9220).
///
/// ## Overview
///
/// `WebTransportServer` simplifies the server-side WebTransport workflow by
/// delegating to `HTTP3Server.enableWebTransport()` internally. This means:
///
/// 1. **No duplicated logic** — session acceptance, path filtering, and quota
///    enforcement are handled by `HTTP3Server`
/// 2. **Composable** — if you already have an `HTTP3Server`, call
///    `enableWebTransport()` directly instead of creating a `WebTransportServer`
/// 3. **Convenience** — `WebTransportServer` exists purely for the "just start
///    a WebTransport server" use case
///
/// ## Usage
///
/// ### Standalone (Tier 1 — one-call static factory)
///
/// ```swift
/// let config = WebTransportConfiguration(quic: myQuicConfig, maxSessions: 4)
/// let server = try await WebTransportServer.listen(
///     host: "0.0.0.0",
///     port: 4433,
///     configuration: config
/// )
///
/// for await session in server.incomingSessions {
///     Task { await handleSession(session) }
/// }
/// ```
///
/// ### Extending an existing HTTP/3 server
///
/// ```swift
/// let httpServer = HTTP3Server()
/// let sessions = await httpServer.enableWebTransport(
///     WebTransportOptions(maxSessionsPerConnection: 4)
/// )
///
/// Task {
///     for await session in sessions {
///         Task { await handleSession(session) }
///     }
/// }
///
/// try await httpServer.listen(host: "0.0.0.0", port: 443, quicConfiguration: config)
/// ```

import Foundation
import Logging
import QUIC
import QUICCore

// MARK: - WebTransport Server

/// A WebTransport server that manages session establishment and lifecycle.
///
/// Delegates to `HTTP3Server.enableWebTransport()` for all session handling.
/// This actor is a thin convenience wrapper for the "just start a WT server"
/// use case. If you already have an `HTTP3Server`, call
/// `enableWebTransport()` on it directly.
public actor WebTransportServer {
    private static let logger = QuiverLogging.logger(label: "webtransport.server")

    // MARK: - Types

    /// Server state
    public enum State: Sendable, Hashable, CustomStringConvertible {
        /// Server created but not listening
        case idle
        /// Server is listening for connections
        case listening
        /// Server is shutting down
        case stopping
        /// Server has stopped
        case stopped

        public var description: String {
            switch self {
            case .idle: return "idle"
            case .listening: return "listening"
            case .stopping: return "stopping"
            case .stopped: return "stopped"
            }
        }
    }

    /// Server-only options (beyond what `WebTransportConfiguration` provides).
    public struct ServerOptions: Sendable {
        /// Maximum number of concurrent HTTP/3 connections.
        ///
        /// 0 means unlimited.
        ///
        /// - Default: 0 (unlimited)
        public var maxConnections: Int

        /// Allowed WebTransport paths.
        ///
        /// If non-empty, only Extended CONNECT requests with a `:path`
        /// matching one of these values will be accepted. All others are
        /// rejected with 404.
        ///
        /// If empty (default), all paths are accepted.
        public var allowedPaths: [String]

        /// Creates server options with sensible defaults.
        public init(
            maxConnections: Int = 0,
            allowedPaths: [String] = []
        ) {
            self.maxConnections = maxConnections
            self.allowedPaths = allowedPaths
        }

        /// Default server options.
        public static let `default` = ServerOptions()
    }

    // MARK: - Properties

    /// Shared WebTransport configuration (QUIC + WT settings).
    public let configuration: WebTransportConfiguration

    /// Server-only options.
    public let serverOptions: ServerOptions

    /// The underlying HTTP/3 server (does the actual work).
    public let httpServer: HTTP3Server

    /// Current server state.
    public private(set) var state: State = .idle

    /// Stream of incoming WebTransport sessions.
    ///
    /// Each element is an established `WebTransportSession` ready for
    /// stream and datagram operations.
    public private(set) var incomingSessions: AsyncStream<WebTransportSession>

    /// Continuation for the incoming sessions stream.
    private var incomingSessionsContinuation: AsyncStream<WebTransportSession>.Continuation?

    /// The QUIC endpoint created by `listen()`.
    private var quicEndpoint: QUICEndpoint?

    /// The I/O loop task created by `listen()`.
    private var quicRunTask: Task<Void, Error>?

    /// Registered request handler for non-WebTransport HTTP/3 requests.
    private var requestHandler: HTTP3Server.RequestHandler?

    /// Whether WebTransport has been enabled on the underlying HTTP3Server.
    private var webTransportEnabled = false

    // MARK: - Initialization

    /// Creates a WebTransport server.
    ///
    /// Internally creates an `HTTP3Server`. The `enableWebTransport()` call
    /// is deferred to `serve()` / `listen()` to satisfy actor isolation.
    ///
    /// - Parameters:
    ///   - configuration: WebTransport configuration (QUIC + WT settings)
    ///   - serverOptions: Server-specific options like max connections and allowed paths
    public init(
        configuration: WebTransportConfiguration,
        serverOptions: ServerOptions = .default
    ) {
        self.configuration = configuration
        self.serverOptions = serverOptions

        // Create the underlying HTTP/3 server
        self.httpServer = HTTP3Server(
            settings: configuration.http3Settings,
            maxConnections: serverOptions.maxConnections
        )

        // Create the incoming sessions stream
        var continuation: AsyncStream<WebTransportSession>.Continuation!
        self.incomingSessions = AsyncStream { cont in
            continuation = cont
        }
        self.incomingSessionsContinuation = continuation
    }

    // MARK: - Configuration

    /// Registers a handler for regular (non-WebTransport) HTTP/3 requests.
    ///
    /// This allows serving both WebTransport sessions and regular HTTP/3
    /// requests on the same server.
    ///
    /// - Parameter handler: The closure to handle incoming requests
    public func onRequest(_ handler: @escaping HTTP3Server.RequestHandler) {
        self.requestHandler = handler
        Task { await httpServer.onRequest(handler) }
    }

    // MARK: - Server Lifecycle

    /// Starts accepting WebTransport connections from a QUIC connection source.
    ///
    /// Delegates directly to the underlying `HTTP3Server.serve()`.
    ///
    /// - Parameter connectionSource: An async stream of incoming QUIC connections
    /// - Throws: `HTTP3Error` if the server cannot start
    public func serve(
        connectionSource: AsyncStream<any QUICConnectionProtocol>
    ) async throws {
        guard state == .idle else {
            throw HTTP3Error(
                code: .internalError,
                reason: "WebTransport server already started (state: \(state))"
            )
        }

        state = .listening

        // Enable WebTransport on the HTTP3Server (deferred from init for actor isolation)
        await enableWebTransportIfNeeded()

        // If no explicit request handler was registered, install a default
        // 404 handler so HTTP3Server.serve() doesn't reject with "no handler"
        if requestHandler == nil {
            await httpServer.onRequest { context in
                try await context.respond(
                    status: 404,
                    headers: [("content-type", "text/plain")],
                    Data("Not Found".utf8)
                )
            }
        }

        do {
            try await httpServer.serve(connectionSource: connectionSource)
        } catch {
            state = .stopped
            throw error
        }

        state = .stopped
    }

    /// Starts the WebTransport server on the specified host and port.
    ///
    /// Creates the full QUIC stack internally and feeds incoming connections
    /// to the WebTransport server. Blocks until `stop()` is called.
    ///
    /// - Parameters:
    ///   - host: The host address to bind to (e.g., `"0.0.0.0"`)
    ///   - port: The port number to listen on
    /// - Throws: `HTTP3Error` if the server cannot start, or QUIC/socket errors
    public func listen(
        host: String,
        port: UInt16
    ) async throws {
        // Enable WebTransport on the HTTP3Server (deferred from init for actor isolation)
        await enableWebTransportIfNeeded()

        let (endpoint, runTask) = try await QUICEndpoint.serve(
            host: host,
            port: port,
            configuration: configuration.quic
        )

        self.quicEndpoint = endpoint
        self.quicRunTask = runTask

        Self.logger.info(
            "WebTransport server listening",
            metadata: [
                "host": "\(host)",
                "port": "\(port)",
                "maxSessions": "\(configuration.maxSessions)",
            ]
        )

        let connectionStream = await endpoint.incomingConnections

        do {
            try await serve(connectionSource: connectionStream)
        } catch {
            await endpoint.stop()
            runTask.cancel()
            self.quicEndpoint = nil
            self.quicRunTask = nil
            throw error
        }
    }

    /// Stops the server gracefully.
    ///
    /// Delegates to the underlying `HTTP3Server.stop()` and also tears
    /// down any QUIC resources created by `listen()`.
    ///
    /// - Parameter gracePeriod: Maximum time to wait for sessions to drain
    public func stop(gracePeriod: Duration = .seconds(5)) async {
        guard state == .listening else { return }

        state = .stopping

        await httpServer.stop(gracePeriod: gracePeriod)

        // Finish the sessions stream
        incomingSessionsContinuation?.finish()
        incomingSessionsContinuation = nil

        // Tear down the QUIC endpoint if we own it (created by listen())
        if let endpoint = quicEndpoint {
            await endpoint.stop()
            quicEndpoint = nil
        }
        quicRunTask?.cancel()
        quicRunTask = nil

        state = .stopped
    }

    // MARK: - Internal Helpers

    /// Enables WebTransport on the underlying `HTTP3Server` (idempotent).
    ///
    /// Called lazily in `serve()` / `listen()` because `HTTP3Server` is an
    /// actor and `enableWebTransport()` must be awaited.
    private func enableWebTransportIfNeeded() async {
        guard !webTransportEnabled else { return }
        webTransportEnabled = true

        let h3Sessions = await httpServer.enableWebTransport(
            WebTransportOptions(
                maxSessionsPerConnection: configuration.maxSessions,
                allowedPaths: serverOptions.allowedPaths
            )
        )

        // Forward sessions from the HTTP3Server stream to our own stream
        let continuation = incomingSessionsContinuation
        Task {
            for await session in h3Sessions {
                continuation?.yield(session)
            }
            continuation?.finish()
        }
    }

    // MARK: - Server Info

    /// Whether the server is currently listening.
    public var isListening: Bool {
        state == .listening
    }

    /// Whether the server has stopped.
    public var isStopped: Bool {
        state == .stopped
    }

    /// The number of active HTTP/3 connections.
    public var activeConnectionCount: Int {
        get async { await httpServer.activeConnectionCount }
    }

    /// A debug description of the server.
    public var debugDescription: String {
        var parts = [String]()
        parts.append("state=\(state)")
        parts.append("maxSessions=\(configuration.maxSessions)")
        return "WebTransportServer(\(parts.joined(separator: ", ")))"
    }
}

// MARK: - Convenience API (Static Factory)

extension WebTransportServer {

    /// Creates and starts a WebTransport server in a single call.
    ///
    /// This static factory creates the full QUIC stack, begins listening, and
    /// returns the server immediately. Incoming sessions are available via
    /// `incomingSessions` without blocking.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let config = WebTransportConfiguration(quic: quicConfig, maxSessions: 4)
    /// let server = try await WebTransportServer.listen(
    ///     host: "0.0.0.0",
    ///     port: 4433,
    ///     configuration: config
    /// )
    ///
    /// for await session in server.incomingSessions {
    ///     Task { await handleSession(session) }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - host: The host address to bind to (e.g. `"0.0.0.0"`)
    ///   - port: The port number to listen on
    ///   - configuration: WebTransport configuration (includes QUIC config)
    ///   - serverOptions: Server-specific options (default: `.default`)
    /// - Returns: A `WebTransportServer` that is already listening
    /// - Throws: `HTTP3Error` if the QUIC endpoint cannot start
    public static func listen(
        host: String,
        port: UInt16,
        configuration: WebTransportConfiguration,
        serverOptions: ServerOptions = .default
    ) async throws -> WebTransportServer {
        let server = WebTransportServer(
            configuration: configuration,
            serverOptions: serverOptions
        )

        // Start the QUIC endpoint so we fail fast on bind errors
        let (endpoint, runTask) = try await QUICEndpoint.serve(
            host: host,
            port: port,
            configuration: configuration.quic
        )

        await server.storeQuicResources(endpoint: endpoint, runTask: runTask)

        Self.logger.info(
            "WebTransport server listening",
            metadata: [
                "host": "\(host)",
                "port": "\(port)",
                "maxSessions": "\(configuration.maxSessions)",
            ]
        )

        // Start serve() in a background task so we return immediately.
        let connectionStream = await endpoint.incomingConnections

        Task {
            do {
                try await server.serve(connectionSource: connectionStream)
            } catch {
                Self.logger.warning("WebTransport server serve loop ended with error: \(error)")
            }
        }

        return server
    }

    // MARK: - Internal Helpers

    /// Stores QUIC resources so `stop()` can tear them down.
    private func storeQuicResources(endpoint: QUICEndpoint, runTask: Task<Void, Error>) {
        self.quicEndpoint = endpoint
        self.quicRunTask = runTask
    }
}
