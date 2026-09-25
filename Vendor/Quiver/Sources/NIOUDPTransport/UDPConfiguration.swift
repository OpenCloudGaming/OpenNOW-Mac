/// UDP Configuration
///
/// Configuration options for UDP transport.

import Foundation

/// Configuration for UDP transport.
public struct UDPConfiguration: Sendable {

    /// The address to bind to.
    public let bindAddress: BindAddress

    /// Whether to enable address reuse (SO_REUSEADDR).
    public let reuseAddress: Bool

    /// Whether to enable port reuse (SO_REUSEPORT).
    ///
    /// Required for multicast to allow multiple processes to bind to the same port.
    public let reusePort: Bool

    /// Receive buffer size in bytes (must be > 0).
    public let receiveBufferSize: Int

    /// Send buffer size in bytes (must be > 0).
    public let sendBufferSize: Int

    /// Maximum datagram size (must be > 0, max 65507).
    ///
    /// UDP theoretical max is 65507 bytes (65535 - 8 byte UDP header - 20 byte IP header).
    public let maxDatagramSize: Int

    /// Whether to enable Explicit Congestion Notification (ECN) metadata
    /// on the underlying NIO datagram channel.
    ///
    /// When `true`, `ChannelOptions.explicitCongestionNotification` is set
    /// during channel creation.  NIO will then populate
    /// `AddressedEnvelope.Metadata.ecnState` on received datagrams and
    /// honour per-envelope ECN state on outgoing writes.
    public let enableECN: Bool

    /// Network interface to bind to (nil for all interfaces).
    ///
    /// Use interface name like "en0", "eth0", etc.
    public let networkInterface: String?

    /// AsyncStream buffer size for incoming datagrams (must be > 0).
    ///
    /// When the consumer is slower than the producer, oldest datagrams
    /// beyond this limit will be dropped.
    public let streamBufferSize: Int

    /// Bind address specification.
    public enum BindAddress: Sendable, Equatable {
        /// Bind to any address (0.0.0.0) on the specified port.
        case any(port: Int)

        /// Bind to a specific address and port.
        case specific(host: String, port: Int)

        /// Bind to IPv4 any address (0.0.0.0).
        case ipv4Any(port: Int)

        /// Bind to IPv6 any address (::).
        case ipv6Any(port: Int)

        /// The port number for this bind address.
        public var port: Int {
            switch self {
            case .any(let port), .specific(_, let port),
                 .ipv4Any(let port), .ipv6Any(let port):
                return port
            }
        }
    }

    /// Maximum allowed UDP datagram size (65535 - 8 byte UDP header - 20 byte IP header).
    public static let maxAllowedDatagramSize = 65507

    /// Valid port range (0-65535).
    public static let validPortRange = 0...65535

    /// Creates a new UDP configuration.
    ///
    /// - Parameters:
    ///   - bindAddress: Address to bind to
    ///   - reuseAddress: Enable SO_REUSEADDR
    ///   - reusePort: Enable SO_REUSEPORT
    ///   - receiveBufferSize: Receive buffer size (must be > 0)
    ///   - sendBufferSize: Send buffer size (must be > 0)
    ///   - maxDatagramSize: Maximum datagram size (must be > 0, max 65507)
    ///   - networkInterface: Network interface name
    ///   - streamBufferSize: AsyncStream buffer size (must be > 0)

    public init(
        bindAddress: BindAddress,
        reuseAddress: Bool = true,
        reusePort: Bool = false,
        receiveBufferSize: Int = 65536,
        sendBufferSize: Int = 65536,
        maxDatagramSize: Int = 65507,
        networkInterface: String? = nil,
        streamBufferSize: Int = 100,
        enableECN: Bool = false
    ) {
        precondition(
            Self.validPortRange.contains(bindAddress.port),
            "port must be in range \(Self.validPortRange)"
        )
        precondition(receiveBufferSize > 0, "receiveBufferSize must be greater than 0")
        precondition(sendBufferSize > 0, "sendBufferSize must be greater than 0")
        precondition(maxDatagramSize > 0, "maxDatagramSize must be greater than 0")
        precondition(
            maxDatagramSize <= Self.maxAllowedDatagramSize,
            "maxDatagramSize must not exceed \(Self.maxAllowedDatagramSize)"
        )
        precondition(streamBufferSize > 0, "streamBufferSize must be greater than 0")

        self.bindAddress = bindAddress
        self.reuseAddress = reuseAddress
        self.reusePort = reusePort
        self.receiveBufferSize = receiveBufferSize
        self.sendBufferSize = sendBufferSize
        self.maxDatagramSize = maxDatagramSize
        self.networkInterface = networkInterface
        self.streamBufferSize = streamBufferSize
        self.enableECN = enableECN
    }

    /// Default configuration for unicast UDP.
    ///
    /// - Parameter port: The port to bind to
    /// - Returns: Configuration suitable for unicast communication (e.g., SWIM)
    public static func unicast(port: Int, enableECN: Bool = false) -> UDPConfiguration {
        UDPConfiguration(
            bindAddress: .any(port: port),
            reuseAddress: true,
            reusePort: false,
            receiveBufferSize: 65536,
            sendBufferSize: 65536,
            maxDatagramSize: 65507,
            networkInterface: nil,
            streamBufferSize: 100,
            enableECN: enableECN
        )
    }

    /// Default configuration for multicast UDP.
    ///
    /// - Parameter port: The port to bind to
    /// - Returns: Configuration suitable for multicast communication (e.g., mDNS)
    public static func multicast(port: Int, enableECN: Bool = false) -> UDPConfiguration {
        UDPConfiguration(
            bindAddress: .any(port: port),
            reuseAddress: true,
            reusePort: true,  // Required for multicast
            receiveBufferSize: 65536,
            sendBufferSize: 65536,
            maxDatagramSize: 65507,
            networkInterface: nil,
            streamBufferSize: 200,  // Higher for multicast due to burst traffic
            enableECN: enableECN
        )
    }
}
