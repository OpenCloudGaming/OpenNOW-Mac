/// UDP Transport Protocol
///
/// Defines the interface for UDP communication.

import Foundation
import NIOCore

/// An incoming datagram with data and sender address.
public struct IncomingDatagram: Sendable {
    /// The received data as ByteBuffer (zero-copy from NIO).
    public let buffer: ByteBuffer

    /// The remote address that sent this datagram.
    public let remoteAddress: SocketAddress

    /// ECN state extracted from the IP TOS / traffic-class byte via
    /// `recvmsg()` ancillary data.
    ///
    /// Populated when `ChannelOptions.explicitCongestionNotification`
    /// is enabled on the NIO datagram channel.  `nil` when unavailable.
    public let ecnState: NIOExplicitCongestionNotificationState?

    /// Creates a new incoming datagram.
    ///
    /// - Parameters:
    ///   - buffer: The received data as ByteBuffer
    ///   - remoteAddress: The sender's address
    ///   - ecnState: ECN state from NIO metadata (nil when unavailable)
    public init(
        buffer: ByteBuffer,
        remoteAddress: SocketAddress,
        ecnState: NIOExplicitCongestionNotificationState? = nil
    ) {
        self.buffer = buffer
        self.remoteAddress = remoteAddress
        self.ecnState = ecnState
    }

    /// The received data as Data (convenience, copies bytes).
    @inlinable
    public var data: Data {
        Data(buffer: buffer)
    }
}

/// Cross-platform UDP transport protocol.
///
/// Provides a simple async/await interface for UDP communication.
///
/// ## Example
/// ```swift
/// let transport = NIOUDPTransport(configuration: .unicast(port: 7946))
/// try await transport.start()
///
/// // Receive datagrams
/// Task {
///     for await datagram in transport.incomingDatagrams {
///         print("Received \(datagram.data.count) bytes")
///     }
/// }
///
/// // Send datagram
/// let address = try SocketAddress(ipAddress: "192.168.1.10", port: 7946)
/// try await transport.send(Data("Hello".utf8), to: address)
/// ```
public protocol UDPTransport: Sendable {

    /// The local address this transport is bound to.
    ///
    /// Returns `nil` if the transport is not started.
    var localAddress: SocketAddress? { get async }

    /// Stream of incoming datagrams.
    ///
    /// Each element is a tuple of (data, sender address).
    /// The stream completes when the transport is stopped.
    var incomingDatagrams: AsyncStream<IncomingDatagram> { get }

    /// Sends data to the specified address.
    ///
    /// - Parameters:
    ///   - data: The data to send
    ///   - address: The destination address
    /// - Throws: `UDPError` if the send fails
    func send(_ data: Data, to address: SocketAddress) async throws

    /// Sends a ByteBuffer to the specified address (zero-copy).
    ///
    /// - Parameters:
    ///   - buffer: The buffer to send
    ///   - address: The destination address
    /// - Throws: `UDPError` if the send fails
    func send(_ buffer: ByteBuffer, to address: SocketAddress) async throws

    /// Starts the transport.
    ///
    /// Binds to the configured address and begins receiving datagrams.
    ///
    /// - Throws: `UDPError.alreadyStarted` if already started,
    ///           `UDPError.bindFailed` if binding fails
    func start() async throws

    /// Stops the transport.
    ///
    /// Closes the socket and stops receiving datagrams.
    /// The `incomingDatagrams` stream will complete.
    func stop() async
}

/// Extension protocol for multicast support.
///
/// Used by mDNS and other multicast-based protocols.
///
/// ## Example
/// ```swift
/// let transport = NIOUDPTransport(configuration: .multicast(port: 5353))
/// try await transport.start()
///
/// // Join mDNS multicast group
/// try await transport.joinMulticastGroup("224.0.0.251", on: nil)
///
/// // Send to multicast group
/// try await transport.sendMulticast(data, to: "224.0.0.251", port: 5353)
/// ```
public protocol MulticastCapable: UDPTransport {

    /// Joins a multicast group.
    ///
    /// - Parameters:
    ///   - group: The multicast group address (e.g., "224.0.0.251" for IPv4,
    ///            "ff02::fb" for IPv6)
    ///   - interface: The network interface name (nil for default interface)
    /// - Throws: `UDPError.multicastError` if joining fails
    func joinMulticastGroup(
        _ group: String,
        on interface: String?
    ) async throws

    /// Leaves a multicast group.
    ///
    /// - Parameters:
    ///   - group: The multicast group address
    ///   - interface: The network interface name (nil for default interface)
    /// - Throws: `UDPError.multicastError` if leaving fails
    func leaveMulticastGroup(
        _ group: String,
        on interface: String?
    ) async throws

    /// Sends data to a multicast group.
    ///
    /// - Parameters:
    ///   - data: The data to send
    ///   - group: The multicast group address
    ///   - port: The destination port
    /// - Throws: `UDPError` if sending fails
    func sendMulticast(
        _ data: Data,
        to group: String,
        port: Int
    ) async throws

    /// Sends a ByteBuffer to a multicast group (zero-copy).
    ///
    /// - Parameters:
    ///   - buffer: The buffer to send
    ///   - group: The multicast group address
    ///   - port: The destination port
    /// - Throws: `UDPError` if sending fails
    func sendMulticast(
        _ buffer: ByteBuffer,
        to group: String,
        port: Int
    ) async throws
}
