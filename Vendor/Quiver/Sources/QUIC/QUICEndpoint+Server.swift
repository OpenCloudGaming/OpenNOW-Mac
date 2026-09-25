/// QUICEndpoint — Server Operations
///
/// Extension containing server-side functionality:
/// - `listen` — creates a server endpoint bound to an address
/// - `serve` — creates and starts a server endpoint with I/O loop
/// - `handleNewConnection` — processes incoming Initial packets
/// - `handleVersionNegotiationPacket` — handles VN packets (client-side)

import Foundation
import QUICCore
import QUICCrypto
import QUICConnection
import QUICTransport
import NIOUDPTransport

// MARK: - Server API

extension QUICEndpoint {

    /// Creates a server endpoint listening on the specified address
    /// - Parameters:
    ///   - address: The address to bind to
    ///   - configuration: QUIC configuration
    /// - Returns: A listening endpoint
    public static func listen(
        address: SocketAddress,
        configuration: QUICConfiguration
    ) async throws -> QUICEndpoint {
        let endpoint = QUICEndpoint(configuration: configuration, isServer: true)
        await endpoint.setLocalAddress(address)
        return endpoint
    }

    /// Creates a server endpoint with a UDP socket and starts it
    /// - Parameters:
    ///   - socket: The UDP socket to use
    ///   - configuration: QUIC configuration
    /// - Returns: A tuple of (endpoint, runTask) - the task runs the I/O loop
    public static func serve(
        socket: any QUICSocket,
        configuration: QUICConfiguration
    ) async throws -> (endpoint: QUICEndpoint, runTask: Task<Void, Error>) {
        let endpoint = QUICEndpoint(configuration: configuration, isServer: true)

        // Start the I/O loop in a separate task
        let runTask = Task {
            try await endpoint.run(socket: socket)
        }

        // Wait briefly for the socket to start and get the address
        try await Task.sleep(for: .milliseconds(10))
        if let nioAddr = await socket.localAddress,
           let addr = SocketAddress(nioAddr) {
            await endpoint.setLocalAddress(addr)
        }

        return (endpoint, runTask)
    }

    /// Creates a server endpoint bound to the specified host and port, and starts the I/O loop.
    ///
    /// This convenience method creates a `NIOQUICSocket` internally, binds it
    /// to the specified address, and starts the packet processing loop.
    ///
    /// - Parameters:
    ///   - host: The host address to bind to (e.g., `"0.0.0.0"` or `"127.0.0.1"`)
    ///   - port: The port number to bind to
    ///   - configuration: QUIC configuration
    /// - Returns: A tuple of (endpoint, runTask) — the task drives the I/O loop until cancelled
    ///
    /// ## Usage
    ///
    /// ```swift
    /// let (endpoint, runTask) = try await QUICEndpoint.serve(
    ///     host: "0.0.0.0",
    ///     port: 4433,
    ///     configuration: quicConfig
    /// )
    ///
    /// for await connection in endpoint.incomingConnections {
    ///     Task { await handleConnection(connection) }
    /// }
    ///
    /// // Cleanup
    /// await endpoint.stop()
    /// runTask.cancel()
    /// ```
    public static func serve(
        host: String,
        port: UInt16,
        configuration: QUICConfiguration
    ) async throws -> (endpoint: QUICEndpoint, runTask: Task<Void, Error>) {
        // Validate configuration consistency before creating the socket
        try configuration.validate()

        let socketConfig = configuration.socketConfiguration
        let udpConfig = UDPConfiguration(
            bindAddress: .specific(host: host, port: Int(port)),
            reuseAddress: false,
            receiveBufferSize: socketConfig.receiveBufferSize ?? 65536,
            sendBufferSize: socketConfig.sendBufferSize ?? 65536,
            maxDatagramSize: socketConfig.maxDatagramSize,
            enableECN: socketConfig.enableECN
        )

        // Determine address family from the bind host for platform options
        let addrFamily: PlatformSocketOptions.AddressFamily =
            host.contains(":") ? .ipv6 : .ipv4
        let platformOpts = PlatformSocketOptions.forQUIC(
            addressFamily: addrFamily,
            enableECN: socketConfig.enableECN,
            enableDF: socketConfig.enableDF
        )
        let socket = NIOQUICSocket(configuration: udpConfig, platformOptions: platformOpts)
        return try await serve(socket: socket, configuration: configuration)
    }

    // MARK: - New Connection Handling

    /// Handles a new incoming connection (server mode)
    func handleNewConnection(info: ConnectionRouter.IncomingConnectionInfo) async throws -> ManagedConnection {
        // Generate our source connection ID
        // Note: length 8 is always valid (0-20 allowed), so random() will never return nil
        guard let sourceConnectionID = ConnectionID.random(length: 8) else {
            throw QUICError.internalError("Failed to generate connection ID")
        }

        // Create TLS provider (fails if not configured)
        let tlsProvider = try createTLSProvider(isClient: false)

        // Create transport parameters from configuration
        // For servers, we MUST include original_destination_connection_id (RFC 9000 Section 18.2)
        let transportParameters = TransportParameters(
            from: configuration,
            sourceConnectionID: sourceConnectionID,
            originalDestinationConnectionID: info.destinationConnectionID
        )

        // Create connection
        // For servers:
        // - sourceConnectionID: Our randomly chosen SCID
        // - destinationConnectionID: Client's SCID (for future packets to the client)
        // - originalConnectionID: DCID from client's Initial (for Initial key derivation)
        let connection = ManagedConnection(
            role: .server,
            version: configuration.version,
            sourceConnectionID: sourceConnectionID,
            destinationConnectionID: info.sourceConnectionID,
            originalConnectionID: info.destinationConnectionID,
            transportParameters: transportParameters,
            tlsProvider: tlsProvider,
            congestionControllerFactory: configuration.congestionControllerFactory,
            localAddress: _localAddress,
            remoteAddress: info.remoteAddress,
            maxDatagramSize: configuration.maxUDPPayloadSize
        )

        // Enable ECN if the socket was created with ECN support
        if let nioSocket = self.socket as? NIOQUICSocket,
           nioSocket.platformOptions?.ecnEnabled == true {
            connection.enableECN()
        }

        // Enable DPLPMTUD if the socket has the DF bit set
        if let nioSocket = self.socket as? NIOQUICSocket,
           nioSocket.platformOptions?.dfEnabled == true {
            connection.enablePMTUD()
        }

        // Register with both our SCID and the client's DCID
        router.register(connection, for: [
            sourceConnectionID,
            info.destinationConnectionID
        ])
        timerManager.register(connection)

        // Initialize sendSignal stream before starting the loop
        // This ensures the continuation is set up before any writes can occur
        let sendSignal = connection.sendSignal

        // Start outbound send loop for this connection
        // This runs in the background and monitors sendSignal to send packets
        // when stream data is written
        if let socket = self.socket {
            Task { [weak self] in
                guard let self = self else { return }
                await self.outboundSendLoop(connection: connection, sendSignal: sendSignal, socket: socket)
            }
        }

        // Start handshake (server doesn't send first)
        _ = try await connection.start()

        // NOTE: Do NOT yield to incomingConnectionContinuation here.
        // The handshake is not yet complete — peer transport parameters
        // have not been received, so stream limits are all 0.
        // If we yield now, higher layers (e.g. HTTP/3) will race to open
        // streams and fail with streamLimitReached.
        //
        // Instead, the caller (processIncomingPacket) will yield the
        // connection AFTER processDatagram() completes the handshake.

        return connection
    }

    // MARK: - Version Negotiation

    /// Handles a Version Negotiation packet
    ///
    /// RFC 9000 Section 6.2: When a client receives a Version Negotiation packet,
    /// it must validate the packet and may retry with a different version.
    ///
    /// - Parameters:
    ///   - data: The Version Negotiation packet data
    ///   - remoteAddress: Where the packet came from
    func handleVersionNegotiationPacket(_ data: Data, from remoteAddress: SocketAddress) async throws {
        // Only clients process Version Negotiation packets
        guard !isServer else {
            // Servers ignore VN packets (RFC 9000 Section 6)
            return
        }

        // Find the connection that might be waiting for a response from this address
        // VN packets have DCID = our SCID and SCID = our DCID
        guard data.count >= 7 else { return }

        // Extract DCID from VN packet (which should be our SCID)
        let dcidLength = Int(data[5])
        guard dcidLength <= ConnectionID.maxLength else { return }
        guard data.count >= 6 + dcidLength else { return }
        let dcidBytes = data[6..<(6 + dcidLength)]
        let vnDCID = try ConnectionID(bytes: dcidBytes)  // Slice is already Data

        // Try to find a connection with this SCID
        guard let connection = router.connection(for: vnDCID) else {
            // No connection found - possibly spoofed packet
            return
        }

        // RFC 9000 Section 6.2: A client MUST discard any Version Negotiation packet
        // if it has received and successfully processed any other packet
        // (This check should be done in the connection)
        if await connection.hasReceivedValidPacket {
            return  // Discard late VN packets
        }

        // Validate and parse the packet
        let offeredVersions: [QUICVersion]
        do {
            offeredVersions = try VersionNegotiator.validateAndParseVersionNegotiation(
                data,
                originalDCID: connection.destinationConnectionID,
                originalSCID: connection.sourceConnectionID
            )
        } catch {
            // Invalid VN packet, discard
            return
        }

        // Try to select a common version
        if let newVersion = VersionNegotiator.selectVersion(
            offered: offeredVersions,
            supported: QUICVersion.supportedVersions
        ) {
            // We can retry with the new version
            try await connection.retryWithVersion(newVersion)
        } else {
            // No common version - close connection gracefully
            // RFC 9000: This isn't a protocol error, just an incompatibility
            await connection.close(error: nil)
            logger.debug("UNREGISTER from handleVersionNegotiationPacket for SCID=\(connection.sourceConnectionID)")
            router.unregister(connection)
            timerManager.markClosed(connection)
        }
    }
}