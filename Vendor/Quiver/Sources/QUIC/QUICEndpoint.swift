/// QUIC Endpoint
///
/// Main entry point for QUIC connections.
/// Provides both client and server APIs.
///
/// ## ECN Integration
///
/// `processIncomingPacket` accepts an optional `ECNCodepoint` from the
/// socket layer and forwards it to `ManagedConnection.processDatagram`
/// so that ECN counts are tracked per encryption level for ACK frames
/// (RFC 9000 §13.4).

import Foundation
import Synchronization
import Logging
import QUICCore
import QUICCrypto
import QUICConnection
@_exported import QUICTransport
import NIOUDPTransport

// MARK: - QUIC Endpoint

/// A QUIC endpoint that can act as client or server
///
/// Provides a unified API for:
/// - Client connections: `dial(address:)` / `connect(to:)`
/// - Server listening: `serve(host:port:configuration:)`
/// - Packet I/O and routing
/// - Timer management
///
/// ## Usage
///
/// ### Client
/// ```swift
/// let endpoint = QUICEndpoint(configuration: config)
/// let connection = try await endpoint.dial(address: serverAddress)
/// let stream = try await connection.openStream()
/// try await stream.write(data)
/// ```
///
/// ### Server
/// ```swift
/// let (endpoint, runTask) = try await QUICEndpoint.serve(
///     host: "0.0.0.0",
///     port: 4433,
///     configuration: config
/// )
/// for await connection in await endpoint.incomingConnections {
///     // Handle connection
/// }
/// await endpoint.stop()
/// runTask.cancel()
/// ```
public actor QUICEndpoint {
    // MARK: - Properties

    /// Configuration
    let configuration: QUICConfiguration

    /// Connection router
    let router: ConnectionRouter

    /// Timer manager
    let timerManager: TimerManager

    /// Whether this endpoint is a server
    let isServer: Bool

    /// Incoming connections (server mode)
    var incomingConnectionContinuation: AsyncStream<any QUICConnectionProtocol>.Continuation?

    /// Connections that have been created but not yet yielded to incomingConnections.
    /// These are waiting for their QUIC handshake to complete so that peer transport
    /// parameters (stream limits, flow control) are available before higher layers
    /// (e.g. HTTP/3) attempt to open streams.
    var pendingConnections: Set<ObjectIdentifier> = []

    /// Send callback (for testing without real socket)
    var sendCallback: (@Sendable (Data, SocketAddress) async throws -> Void)?

    /// The UDP socket (for real I/O)
    var socket: (any QUICSocket)?

    /// Task running the main I/O loop
    var ioTask: Task<Void, Never>?

    /// Local address
    var _localAddress: SocketAddress?

    /// Whether the endpoint is running
    var isRunning: Bool = false

    /// Stop signal for the I/O loop
    var shouldStop: Bool = false

    /// Logger for endpoint events
    let logger = QuiverLogging.logger(label: "quic.endpoint")

    // MARK: - Initialization

    /// Creates a client endpoint
    /// - Parameter configuration: QUIC configuration
    public init(configuration: QUICConfiguration) {
        self.configuration = configuration
        self.router = ConnectionRouter(isServer: false, dcidLength: 8)
        self.timerManager = TimerManager(idleTimeout: configuration.maxIdleTimeout)
        self.isServer = false
    }

    /// Creates a server endpoint (internal)
    init(configuration: QUICConfiguration, isServer: Bool) {
        self.configuration = configuration
        self.router = ConnectionRouter(isServer: isServer, dcidLength: 8)
        self.timerManager = TimerManager(idleTimeout: configuration.maxIdleTimeout)
        self.isServer = isServer
    }

    // MARK: - TLS Provider Creation

    /// Creates a TLS provider based on the security mode configuration.
    ///
    /// This method enforces the security mode hierarchy:
    /// 1. If `securityMode` is set, use it
    /// 2. Otherwise, if `tlsProviderFactory` is set (legacy), use it
    /// 3. Otherwise, throw `QUICSecurityError.tlsProviderNotConfigured`
    ///
    /// - Parameter isClient: Whether this is for a client connection
    /// - Returns: A configured TLS provider
    /// - Throws: `QUICSecurityError.tlsProviderNotConfigured` if no TLS provider is configured
    func createTLSProvider(isClient: Bool) throws -> any TLS13Provider {
        // Priority 1: Check securityMode (new API)
        if let securityMode = configuration.securityMode {
            switch securityMode {
            case .production(let factory):
                return factory()
            case .development(let factory):
                return factory()
            #if DEBUG
            case .testing:
                logger.warning(
                    "Using MockTLSProvider in testing mode - NOT FOR PRODUCTION USE",
                    metadata: ["isClient": "\(isClient)"]
                )
                return MockTLSProvider(configuration: TLSConfiguration())
            #endif
            }
        }

        // Priority 2: Check legacy tlsProviderFactory
        if let factory = configuration.tlsProviderFactory {
            return factory(isClient)
        }

        // No TLS provider configured - fail safely
        logger.error(
            "TLS provider not configured. Set securityMode or tlsProviderFactory before connecting.",
            metadata: ["isClient": "\(isClient)"]
        )
        throw QUICSecurityError.tlsProviderNotConfigured
    }

    /// Creates a TLS provider with session resumption configuration.
    ///
    /// - Parameters:
    ///   - isClient: Whether this is for a client connection
    ///   - sessionTicket: Optional session ticket for resumption
    ///   - maxEarlyDataSize: Maximum early data size for 0-RTT
    /// - Returns: A configured TLS provider
    /// - Throws: `QUICSecurityError.tlsProviderNotConfigured` if no TLS provider is configured
    func createTLSProvider(
        isClient: Bool,
        sessionTicket: Data?,
        maxEarlyDataSize: UInt32?
    ) throws -> any TLS13Provider {
        // Priority 1: Check securityMode (new API)
        if let securityMode = configuration.securityMode {
            switch securityMode {
            case .production(let factory):
                return factory()
            case .development(let factory):
                return factory()
            #if DEBUG
            case .testing:
                logger.warning(
                    "Using MockTLSProvider in testing mode - NOT FOR PRODUCTION USE",
                    metadata: ["isClient": "\(isClient)"]
                )
                var tlsConfig = TLSConfiguration()
                tlsConfig.sessionTicket = sessionTicket
                if let maxSize = maxEarlyDataSize {
                    tlsConfig.maxEarlyDataSize = maxSize
                }
                return MockTLSProvider(configuration: tlsConfig)
            #endif
            }
        }

        // Priority 2: Check legacy tlsProviderFactory
        if let factory = configuration.tlsProviderFactory {
            return factory(isClient)
        }

        // No TLS provider configured - fail safely
        logger.error(
            "TLS provider not configured. Set securityMode or tlsProviderFactory before connecting.",
            metadata: ["isClient": "\(isClient)"]
        )
        throw QUICSecurityError.tlsProviderNotConfigured
    }

    // MARK: - Address Management

    /// Sets the local address (internal)
    func setLocalAddress(_ address: SocketAddress) {
        _localAddress = address
    }

    /// The local address this endpoint is bound to
    public var localAddress: SocketAddress? {
        _localAddress
    }

    /// Stream of incoming connections (server mode)
    public var incomingConnections: AsyncStream<any QUICConnectionProtocol> {
        AsyncStream { continuation in
            self.incomingConnectionContinuation = continuation
        }
    }

    // MARK: - Packet Processing

    /// Processes an incoming packet
    /// - Parameters:
    ///   - data: The packet data
    ///   - remoteAddress: Where the packet came from
    ///   - ecnCodepoint: ECN codepoint from the IP header (via `IncomingPacket`).
    ///     Defaults to `.notECT` when the transport does not provide ECN metadata.
    /// - Returns: Outbound packets to send
    public func processIncomingPacket(
        _ data: Data,
        from remoteAddress: SocketAddress,
        ecnCodepoint: ECNCodepoint = .notECT
    ) async throws -> [Data] {
        // Check for Version Negotiation packet first (version == 0 in long header)
        // RFC 9000 Section 6: Version Negotiation packets are special and must be
        // handled before normal routing
        if VersionNegotiator.isVersionNegotiationPacket(data) {
            try await handleVersionNegotiationPacket(data, from: remoteAddress)
            return []  // VN packets don't generate responses
        }

        // Route the packet
        switch router.route(data: data, from: remoteAddress) {
        case .routed(let connection):
            // Process packet through the connection
            timerManager.recordActivity(for: connection)
            let responses = try await connection.processDatagram(data, ecnCodepoint: ecnCodepoint)

            // Send responses
            for response in responses {
                try await send(response, to: remoteAddress)
            }

            // Check if this connection was pending handshake completion.
            // Multi-round-trip handshakes (e.g. TLS 1.3 with HRR) may
            // require several packets before isEstablished becomes true.
            let connID = ObjectIdentifier(connection)
            if pendingConnections.contains(connID) && connection.isEstablished {
                pendingConnections.remove(connID)
                incomingConnectionContinuation?.yield(connection)
            }

            return responses

        case .newConnection(let info):
            // Server: Create new connection for Initial packet
            guard isServer else {
                throw QUICEndpointError.unexpectedPacket
            }

            let connection = try await handleNewConnection(info: info)
            let responses = try await connection.processDatagram(data, ecnCodepoint: ecnCodepoint)

            // Send responses
            for response in responses {
                try await send(response, to: remoteAddress)
            }

            // Yield to incomingConnections AFTER processDatagram completes.
            // processDatagram processes the client's Initial CRYPTO frame,
            // runs TLS, and (for most handshakes) completes the server-side
            // handshake — which installs peer transport parameters and sets
            // stream limits.  Yielding before this point causes higher layers
            // (e.g. HTTP/3) to race and fail with streamLimitReached because
            // peer limits are still 0.
            if connection.isEstablished {
                incomingConnectionContinuation?.yield(connection)
            } else {
                // Multi-round-trip handshake (rare with MockTLS, possible with
                // real TLS 1.3 + HRR).  Track as pending — it will be yielded
                // in the .routed branch once the handshake completes on a
                // subsequent packet.
                pendingConnections.insert(ObjectIdentifier(connection))
            }

            return responses

        case .notFound(let dcid):
            throw QUICEndpointError.connectionNotFound(dcid)

        case .invalid(let error):
            throw error
        }
    }

    // MARK: - Timer Processing

    /// Processes expired timers
    /// - Returns: Any packets that need to be sent
    public func processTimers() async throws -> [(Data, SocketAddress)] {
        var outbound: [(Data, SocketAddress)] = []

        let events = timerManager.processTimers()
        for event in events {
            switch event {
            case .sendAck(let connection), .lossDetection(let connection), .probe(let connection):
                let packets = try connection.onTimerExpired()
                for packet in packets {
                    outbound.append((packet, connection.remoteAddress))
                }

            case .idleTimeout(let connection):
                // Close connection due to idle timeout
                await connection.close(error: nil)
                logger.info("Idle timeout: UNREGISTER for SCID=\(connection.sourceConnectionID)")
                router.unregister(connection)
                timerManager.markClosed(connection)
            }
        }

        return outbound
    }

    /// Gets the next timer deadline
    public func nextTimerDeadline() -> ContinuousClock.Instant? {
        timerManager.nextDeadline()
    }

    // MARK: - Event Loop (Testing)

    /// Runs the main event loop (for testing)
    /// Call this with incoming packets and it will process them
    public func runOnce(
        incoming: [(data: Data, address: SocketAddress)]
    ) async throws -> [(data: Data, address: SocketAddress)] {
        var outgoing: [(data: Data, address: SocketAddress)] = []

        // Process incoming packets
        for (data, address) in incoming {
            do {
                let responses = try await processIncomingPacket(data, from: address)
                for response in responses {
                    outgoing.append((response, address))
                }
            } catch {
                // Log error but continue processing
                logger.warning("Error processing packet: \(error)")
            }
        }

        // Process timers
        let timerPackets = try await processTimers()
        outgoing.append(contentsOf: timerPackets)

        return outgoing
    }

    // MARK: - Send Callback

    /// Sets a callback for sending packets (for testing)
    public func setSendCallback(_ callback: @escaping @Sendable (Data, SocketAddress) async throws -> Void) {
        sendCallback = callback
    }

    /// Sends a packet
    func send(_ data: Data, to address: SocketAddress) async throws {
        if let socket = socket {
            // Use the real socket - convert to NIO address
            let nioAddress = try address.toNIOAddress()
            try await socket.send(data, to: nioAddress)
        } else if let callback = sendCallback {
            // Use the callback (for testing)
            try await callback(data, address)
        }
        // If neither, packets are silently dropped (useful for unit testing)
    }

    // MARK: - Connection Management

    /// Closes all connections
    ///
    /// Note: Actual cleanup (router unregister, timer manager) happens
    /// when each connection's outboundSendLoop ends after shutdown.
    public func closeAll() async {
        for connection in router.allConnections {
            await connection.close(error: nil)
        }
    }

    /// Number of active connections
    public var connectionCount: Int {
        router.connectionCount
    }

    /// Gets a connection by its ID
    public func connection(for connectionID: ConnectionID) -> ManagedConnection? {
        router.connection(for: connectionID)
    }
}