/// HTTP/3 Client (RFC 9114)
///
/// A high-level HTTP/3 client that manages QUIC connections and provides
/// a simple API for making HTTP/3 requests.
///
/// ## Features
///
/// - **Connection pooling** — Reuses connections to the same authority
/// - **Automatic HTTP/3 setup** — Opens control and QPACK streams automatically
/// - **QPACK header compression** — Uses literal-only mode for simplicity
/// - **Concurrent requests** — Multiple requests can be in-flight simultaneously
///
/// ## Usage
///
/// ```swift
/// let client = HTTP3Client()
///
/// // Simple GET request
/// let response = try await client.request(
///     HTTP3Request(method: .get, url: "https://example.com/api/data")
/// )
/// print("Status: \(response.status)")
/// print("Body: \(String(data: response.body, encoding: .utf8) ?? "")")
///
/// // POST request with body
/// let postResponse = try await client.request(
///     HTTP3Request(
///         method: .post,
///         url: "https://example.com/api/submit",
///         headers: [("content-type", "application/json")],
///         body: Data("{\"key\": \"value\"}".utf8)
///     )
/// )
///
/// // Clean up
/// await client.close()
/// ```
///
/// ## Connection Lifecycle
///
/// When a request is made, the client:
/// 1. Checks for an existing connection to the target authority
/// 2. If none exists, establishes a new QUIC connection
/// 3. Initializes the HTTP/3 layer (control stream, QPACK streams, SETTINGS)
/// 4. Sends the request on a new bidirectional stream
/// 5. Returns the response
///
/// Connections are kept alive for subsequent requests to the same authority.

import Foundation
import QUIC
import QUICCore
import QPACK

// MARK: - HTTP/3 Client

/// HTTP/3 client for making requests over QUIC connections.
///
/// The client manages a pool of HTTP/3 connections, one per authority
/// (host:port). Connections are reused for multiple requests to the
/// same authority.
///
/// The client is an `actor` for thread-safe access to its internal
/// connection pool and state.
public actor HTTP3Client {

    // MARK: - Configuration

    /// Configuration for the HTTP/3 client
    public struct Configuration: Sendable {
        /// HTTP/3 settings to advertise to the server
        public var settings: HTTP3Settings

        /// Maximum number of concurrent requests per connection
        public var maxConcurrentRequests: Int

        /// Idle connection timeout before automatic closure
        public var idleTimeout: Duration

        /// Whether to automatically retry failed requests on new connections
        public var autoRetry: Bool

        /// Maximum number of connections to maintain in the pool
        public var maxConnections: Int

        /// Creates a client configuration with default values.
        ///
        /// - Parameters:
        ///   - settings: HTTP/3 settings (default: literal-only QPACK)
        ///   - maxConcurrentRequests: Max concurrent requests per connection (default: 100)
        ///   - idleTimeout: Idle timeout (default: 30 seconds)
        ///   - autoRetry: Whether to auto-retry on connection failure (default: true)
        ///   - maxConnections: Maximum pooled connections (default: 16)
        public init(
            settings: HTTP3Settings = HTTP3Settings(),
            maxConcurrentRequests: Int = 100,
            idleTimeout: Duration = .seconds(30),
            autoRetry: Bool = true,
            maxConnections: Int = 16
        ) {
            self.settings = settings
            self.maxConcurrentRequests = maxConcurrentRequests
            self.idleTimeout = idleTimeout
            self.autoRetry = autoRetry
            self.maxConnections = maxConnections
        }

        /// Default client configuration
        public static let `default` = Configuration()
    }

    // MARK: - Properties

    /// Client configuration
    public let configuration: Configuration

    /// Connection pool: authority → HTTP3Connection
    private var connections: [String: HTTP3Connection] = [:]

    /// QUIC connection factory for creating new QUIC connections.
    ///
    /// This is a closure that creates a new QUIC connection to the given
    /// address. It is injected at initialization to decouple the HTTP/3
    /// client from the specific QUIC implementation.
    private let connectionFactory: (@Sendable (String, UInt16) async throws -> any QUICConnectionProtocol)?

    /// Whether the client has been closed
    private var isClosed: Bool = false

    // MARK: - Initialization

    /// Creates an HTTP/3 client with default configuration.
    ///
    /// - Parameter connectionFactory: Optional factory for creating QUIC connections.
    ///   If nil, the client requires connections to be provided via `setConnection(_:for:)`.
    public init(
        configuration: Configuration = .default,
        connectionFactory: (@Sendable (String, UInt16) async throws -> any QUICConnectionProtocol)? = nil
    ) {
        self.configuration = configuration
        self.connectionFactory = connectionFactory
    }

    // MARK: - Request API

    /// Performs an HTTP/3 request and returns the response.
    ///
    /// The response body is always stream-backed. Consume it with
    /// `response.body.data()`, `.text()`, `.json()`, or `.stream()`.
    ///
    /// If a connection to the target authority already exists and is ready,
    /// it is reused. Otherwise, a new connection is established.
    ///
    /// - Parameter request: The HTTP/3 request to send
    /// - Returns: The HTTP/3 response with stream-backed body
    /// - Throws: `HTTP3Error` if the request fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let client = HTTP3Client()
    /// let response = try await client.request(
    ///     HTTP3Request(method: .get, url: "https://example.com/")
    /// )
    /// let body = try await response.body.data()
    /// ```
    public func request(_ request: HTTP3Request) async throws -> HTTP3Response {
        guard !isClosed else {
            throw HTTP3Error(code: .internalError, reason: "Client is closed")
        }

        let authority = request.authority
        let connection = try await getOrCreateConnection(for: authority)
        return try await connection.sendRequest(request)
    }

    /// Performs a GET request to the given URL.
    ///
    /// Response body is stream-backed. Consume however you want:
    /// ```swift
    /// let response = try await client.get("https://example.com/data")
    /// let data = try await response.body.data()
    /// // OR
    /// for await chunk in try response.body.stream() { ... }
    /// ```
    ///
    /// - Parameters:
    ///   - url: The URL to request
    ///   - headers: Additional headers (default: empty)
    /// - Returns: The HTTP/3 response with stream-backed body
    /// - Throws: `HTTP3Error` if the request fails
    public func get(_ url: String, headers: [(String, String)] = []) async throws -> HTTP3Response {
        let request = HTTP3Request(method: .get, url: url, headers: headers)
        return try await self.request(request)
    }

    /// Performs a POST request with a `Data` body.
    ///
    /// The entire body is sent in one shot. Response body is stream-backed.
    ///
    /// - Parameters:
    ///   - url: The URL to request
    ///   - body: The request body data
    ///   - headers: Additional headers (default: empty)
    /// - Returns: The HTTP/3 response with stream-backed body
    /// - Throws: `HTTP3Error` if the request fails
    public func post(
        _ url: String,
        body: Data,
        headers: [(String, String)] = []
    ) async throws -> HTTP3Response {
        let request = HTTP3Request(method: .post, url: url, headers: headers, body: body)
        return try await self.request(request)
    }

    /// Performs a POST request with a streaming upload body.
    ///
    /// The request body is written in chunks via the writer closure.
    /// Each `writer.write()` sends a DATA frame directly on the QUIC stream.
    /// Memory usage is flat regardless of total body size.
    ///
    /// The response is returned after the upload completes (half-duplex).
    /// For full-duplex, use `open(method:url:headers:)` (planned).
    ///
    /// ```swift
    /// let response = try await client.post(
    ///     "https://example.com/upload",
    ///     headers: [("content-type", "application/octet-stream")]
    /// ) { writer in
    ///     for chunk in fileChunks {
    ///         try await writer.write(chunk)
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - url: The URL to POST to
    ///   - headers: Additional headers (default: empty)
    ///   - writer: Closure that writes body chunks via ``HTTP3BodyWriter``
    /// - Returns: The HTTP/3 response with stream-backed body
    /// - Throws: `HTTP3Error` if the request fails
    public func post(
        _ url: String,
        headers: [(String, String)] = [],
        _ writer: @escaping @Sendable (HTTP3BodyWriter) async throws -> Void
    ) async throws -> HTTP3Response {
        guard !isClosed else {
            throw HTTP3Error(code: .internalError, reason: "Client is closed")
        }

        let request = HTTP3Request(method: .post, url: url, headers: headers)
        let connection = try await getOrCreateConnection(for: request.authority)
        return try await connection.sendRequestWithBodyWriter(request, bodyWriter: writer)
    }

    /// Performs a PUT request with a `Data` body.
    ///
    /// - Parameters:
    ///   - url: The URL to request
    ///   - body: The request body data
    ///   - headers: Additional headers (default: empty)
    /// - Returns: The HTTP/3 response with stream-backed body
    /// - Throws: `HTTP3Error` if the request fails
    public func put(
        _ url: String,
        body: Data,
        headers: [(String, String)] = []
    ) async throws -> HTTP3Response {
        let request = HTTP3Request(method: .put, url: url, headers: headers, body: body)
        return try await self.request(request)
    }

    /// Performs a DELETE request to the given URL.
    ///
    /// - Parameters:
    ///   - url: The URL to request
    ///   - headers: Additional headers (default: empty)
    /// - Returns: The HTTP/3 response with stream-backed body
    /// - Throws: `HTTP3Error` if the request fails
    public func delete(_ url: String, headers: [(String, String)] = []) async throws -> HTTP3Response {
        let request = HTTP3Request(method: .delete, url: url, headers: headers)
        return try await self.request(request)
    }

    // MARK: - Connection Management

    /// Gets an existing connection or creates a new one for the given authority.
    ///
    /// - Parameter authority: The authority (host:port) to connect to
    /// - Returns: An initialized HTTP3Connection
    /// - Throws: `HTTP3Error` if connection creation or initialization fails
    private func getOrCreateConnection(for authority: String) async throws -> HTTP3Connection {
        // Check for an existing ready connection
        if let existing = connections[authority] {
            let isReady = await existing.isReady
            let isClosed = await existing.isClosed
            if isReady && !isClosed {
                return existing
            }
            // Connection is no longer usable — remove it
            connections.removeValue(forKey: authority)
        }

        // Check pool size limit
        if connections.count >= configuration.maxConnections {
            // Evict the oldest/least-used connection
            // For simplicity, remove the first one found
            if let firstKey = connections.keys.first {
                let conn = connections.removeValue(forKey: firstKey)
                if let conn = conn {
                    await conn.close()
                }
            }
        }

        // Create a new connection
        let connection = try await createConnection(to: authority)
        connections[authority] = connection
        return connection
    }

    /// Creates a new HTTP/3 connection to the given authority.
    ///
    /// - Parameter authority: The authority (host:port) to connect to
    /// - Returns: An initialized HTTP3Connection
    /// - Throws: `HTTP3Error` if connection creation fails
    private func createConnection(to authority: String) async throws -> HTTP3Connection {
        // Parse authority into host and port
        let (host, port) = parseAuthority(authority)

        guard let factory = connectionFactory else {
            throw HTTP3Error(
                code: .internalError,
                reason: "No connection factory configured. Provide a connectionFactory or use setConnection(_:for:)."
            )
        }

        // Create the QUIC connection
        let quicConnection = try await factory(host, port)

        // Wrap in HTTP/3 connection
        let h3Connection = HTTP3Connection(
            quicConnection: quicConnection,
            role: .client,
            settings: configuration.settings
        )

        // Initialize HTTP/3 (control streams, SETTINGS)
        try await h3Connection.initialize()

        return h3Connection
    }

    /// Manually sets an HTTP/3 connection for a given authority.
    ///
    /// This is useful for testing or when connection creation is managed
    /// externally (e.g., by a QUIC endpoint).
    ///
    /// - Parameters:
    ///   - connection: The HTTP/3 connection to use
    ///   - authority: The authority (host:port) this connection serves
    public func setConnection(_ connection: HTTP3Connection, for authority: String) {
        connections[authority] = connection
    }

    /// Removes and closes the connection for a given authority.
    ///
    /// - Parameter authority: The authority whose connection to remove
    public func removeConnection(for authority: String) async {
        if let connection = connections.removeValue(forKey: authority) {
            await connection.close()
        }
    }

    /// Returns the number of active connections in the pool.
    public var connectionCount: Int {
        connections.count
    }

    /// Returns the authorities for which connections exist.
    public var connectedAuthorities: [String] {
        Array(connections.keys)
    }

    // MARK: - Lifecycle

    /// Closes the client and all its connections.
    ///
    /// After calling this method, no more requests can be made.
    /// All pooled connections are closed gracefully.
    public func close() async {
        guard !isClosed else { return }
        isClosed = true

        // Close all pooled connections
        for (_, connection) in connections {
            await connection.close()
        }
        connections.removeAll()
    }

    // MARK: - Utility

    /// Parses an authority string into host and port.
    ///
    /// Supports formats:
    /// - `host:port` (e.g., "example.com:443")
    /// - `host` (defaults to port 443)
    /// - `[ipv6]:port` (e.g., "[::1]:443")
    ///
    /// - Parameter authority: The authority string to parse
    /// - Returns: A tuple of (host, port)
    private func parseAuthority(_ authority: String) -> (host: String, port: UInt16) {
        // Handle IPv6 addresses in brackets
        if authority.hasPrefix("[") {
            if let bracketEnd = authority.firstIndex(of: "]") {
                let host = String(authority[authority.index(after: authority.startIndex)...authority.index(before: bracketEnd)])
                let afterBracket = authority[authority.index(after: bracketEnd)...]
                if afterBracket.hasPrefix(":"), let port = UInt16(afterBracket.dropFirst()) {
                    return (host, port)
                }
                return (host, 443)
            }
        }

        // Handle host:port
        let parts = authority.split(separator: ":", maxSplits: 1)
        if parts.count == 2, let port = UInt16(parts[1]) {
            return (String(parts[0]), port)
        }

        // Default to port 443
        return (authority, 443)
    }
}

// MARK: - Client Builder Pattern

extension HTTP3Client {
    /// Creates a client with a custom configuration using a builder pattern.
    ///
    /// - Parameter configure: A closure that modifies the configuration
    /// - Returns: A configured HTTP3Client
    public static func build(
        connectionFactory: (@Sendable (String, UInt16) async throws -> any QUICConnectionProtocol)? = nil,
        configure: (inout Configuration) -> Void
    ) -> HTTP3Client {
        var config = Configuration.default
        configure(&config)
        return HTTP3Client(configuration: config, connectionFactory: connectionFactory)
    }
}