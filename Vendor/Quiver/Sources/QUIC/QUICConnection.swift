/// QUIC Connection Public API
///
/// High-level interface for QUIC connections.

import Foundation
import QUICCore

// MARK: - QUIC Connection Protocol

/// A multiplexed QUIC connection
public protocol QUICConnectionProtocol: Sendable {
    /// The local address
    var localAddress: SocketAddress? { get }

    /// The remote address
    var remoteAddress: SocketAddress { get }

    /// Whether the connection is established
    var isEstablished: Bool { get }

    /// Whether 0-RTT early data was accepted by the server.
    ///
    /// Only meaningful after handshake completes. Before that, always `false`.
    var is0RTTAccepted: Bool { get }

    /// Suspends the caller until the QUIC handshake completes.
    ///
    /// - If the handshake is already complete, returns immediately.
    /// - If the connection is closed before the handshake finishes, throws.
    /// - Multiple concurrent callers are supported; all are resumed when
    ///   the handshake completes (or fails).
    ///
    /// ## Usage
    /// ```swift
    /// let connection = try await endpoint.connect(to: serverAddress)
    /// // connection is already established here — connect() awaits internally
    ///
    /// // But you can also call it explicitly if you obtained a connection
    /// // through a lower-level API:
    /// try await connection.waitForHandshake()
    /// ```
    func waitForHandshake() async throws

    /// Opens a new bidirectional stream
    func openStream() async throws -> any QUICStreamProtocol

    /// Opens a new unidirectional stream
    func openUniStream() async throws -> any QUICStreamProtocol

    /// Stream of incoming streams from the remote peer.
    ///
    /// Use this to receive streams initiated by the remote peer.
    ///
    /// ## Usage
    /// ```swift
    /// // Process all incoming streams
    /// for await stream in connection.incomingStreams {
    ///     Task { await handleStream(stream) }
    /// }
    ///
    /// // Accept a single stream
    /// var iterator = connection.incomingStreams.makeAsyncIterator()
    /// if let stream = await iterator.next() {
    ///     // handle stream
    /// }
    /// ```
    var incomingStreams: AsyncStream<any QUICStreamProtocol> { get }

    // MARK: - QUIC DATAGRAM Support (RFC 9221)

    /// Sends a QUIC DATAGRAM frame with the given payload.
    ///
    /// Datagrams are unreliable, unordered messages sent outside of
    /// any stream. Both endpoints must have negotiated datagram support
    /// via the `max_datagram_frame_size` transport parameter.
    ///
    /// - Parameter data: The datagram payload to send
    /// - Throws: If datagrams are not supported or the payload exceeds
    ///   the peer's `max_datagram_frame_size`
    ///
    /// ## Usage
    /// ```swift
    /// try await connection.sendDatagram(Data("ping".utf8))
    /// ```
    func sendDatagram(_ data: Data) async throws

    /// Stream of incoming QUIC DATAGRAM frame payloads.
    ///
    /// Use this to receive datagrams from the remote peer. Datagrams
    /// are unreliable and may arrive out of order or not at all.
    ///
    /// ## Usage
    /// ```swift
    /// for await datagram in connection.incomingDatagrams {
    ///     print("Received datagram: \(datagram.count) bytes")
    /// }
    /// ```
    var incomingDatagrams: AsyncStream<Data> { get }

    /// Closes the connection
    /// - Parameter error: Optional error code to send to peer
    func close(error: UInt64?) async

    /// Closes the connection with an application error
    /// - Parameters:
    ///   - errorCode: Application error code
    ///   - reason: Human-readable reason
    func close(applicationError errorCode: UInt64, reason: String) async
}

// MARK: - Datagram Errors

/// Errors related to QUIC DATAGRAM operations (RFC 9221).
public enum QUICDatagramError: Error, Sendable, CustomStringConvertible {
    /// Datagrams are not supported by this connection.
    ///
    /// Neither endpoint advertised the `max_datagram_frame_size`
    /// transport parameter, or the negotiated size is 0.
    case datagramsNotSupported

    /// The datagram payload exceeds the peer's maximum datagram frame size.
    case datagramTooLarge(size: Int, maxAllowed: Int)

    /// The connection is not in a state that allows sending datagrams.
    case connectionNotReady

    public var description: String {
        switch self {
        case .datagramsNotSupported:
            return "QUIC datagrams are not supported by this connection"
        case .datagramTooLarge(let size, let maxAllowed):
            return "Datagram payload too large: \(size) bytes (max: \(maxAllowed))"
        case .connectionNotReady:
            return "Connection is not ready for datagram operations"
        }
    }
}

// MARK: - QUIC Stream Protocol

/// A single QUIC stream
public protocol QUICStreamProtocol: Sendable {
    /// The stream ID
    var id: UInt64 { get }

    /// Whether this is a unidirectional stream
    var isUnidirectional: Bool { get }

    /// Whether this is a bidirectional stream
    var isBidirectional: Bool { get }

    /// Reads data from the stream
    /// - Returns: The data read (empty if stream is finished)
    func read() async throws -> Data

    /// Reads up to a maximum number of bytes
    /// - Parameter maxBytes: Maximum bytes to read
    /// - Returns: The data read
    func read(maxBytes: Int) async throws -> Data

    /// Writes data to the stream
    /// - Parameter data: The data to write
    func write(_ data: Data) async throws

    /// Closes the write side of the stream (sends FIN)
    func closeWrite() async throws

    /// Resets the stream with an error code
    /// - Parameter errorCode: Application error code
    func reset(errorCode: UInt64) async

    /// Signals that no more data will be read
    func stopSending(errorCode: UInt64) async throws
}

// MARK: - Socket Address (placeholder until NIO integration)

/// A network socket address
public struct SocketAddress: Sendable, Hashable {
    /// The IP address
    public let ipAddress: String

    /// The port number
    public let port: UInt16

    /// Creates a socket address
    public init(ipAddress: String, port: UInt16) {
        self.ipAddress = ipAddress
        self.port = port
    }

    /// Creates a socket address from a string like "192.168.1.1:8080"
    public init?(string: String) {
        let parts = string.split(separator: ":")
        guard parts.count == 2,
              let port = UInt16(parts[1]) else {
            return nil
        }
        self.ipAddress = String(parts[0])
        self.port = port
    }
}

extension SocketAddress: CustomStringConvertible {
    public var description: String {
        "\(ipAddress):\(port)"
    }
}

// MARK: - NIO Integration

import NIOCore

extension SocketAddress {
    /// Creates a SocketAddress from a NIOCore.SocketAddress
    public init?(_ nioAddress: NIOCore.SocketAddress) {
        guard let port = nioAddress.port else {
            return nil
        }

        switch nioAddress {
        case .v4(let addr):
            self.ipAddress = addr.host
            self.port = UInt16(port)
        case .v6(let addr):
            self.ipAddress = addr.host
            self.port = UInt16(port)
        case .unixDomainSocket:
            return nil
        }
    }

    /// Converts to NIOCore.SocketAddress
    public func toNIOAddress() throws -> NIOCore.SocketAddress {
        try NIOCore.SocketAddress(ipAddress: ipAddress, port: Int(port))
    }
}
