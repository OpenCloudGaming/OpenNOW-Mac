/// QUIC Configuration
///
/// Configuration options for QUIC connections.

import Foundation
import QUICCore
import QUICCrypto
import QUICRecovery

// MARK: - Security Mode

/// QUIC security mode for TLS provider configuration
///
/// This enum enforces explicit security configuration, preventing
/// accidental use of insecure defaults in production environments.
///
/// ## Usage
///
/// ```swift
/// // Production: TLS required
/// let config = QUICConfiguration.production {
///     MyTLSProvider()
/// }
///
/// // Development: TLS with self-signed certificates
/// let devConfig = QUICConfiguration.development {
///     MyTLSProvider(allowSelfSigned: true)
/// }
///
/// // Testing only: Mock TLS (explicit opt-in)
/// let testConfig = QUICConfiguration.testing()
/// ```
public enum QUICSecurityMode: Sendable {
    /// Production environment: TLS required with proper certificate validation
    case production(tlsProviderFactory: @Sendable () -> any TLS13Provider)

    /// Development environment: TLS required but self-signed certificates allowed
    case development(tlsProviderFactory: @Sendable () -> any TLS13Provider)

    #if DEBUG
    /// Testing environment: Uses MockTLSProvider
    /// - Warning: Never use in production. This mode disables encryption.
    /// - Note: This case is only available in DEBUG builds, matching the
    ///   `QUICConfiguration.testing()` factory method guard.
    case testing
    #endif
}

// MARK: - Security Errors

/// QUIC security-related errors
public enum QUICSecurityError: Error, Sendable {
    /// TLS provider is not configured. Set `securityMode` before connecting.
    case tlsProviderNotConfigured

    /// Certificate validation failed
    case certificateValidationFailed(reason: String)

    /// Security mode is not appropriate for the operation
    case inappropriateSecurityMode(String)
}

// MARK: - TLS Provider Factory

/// Factory for creating TLS 1.3 providers.
///
/// This allows custom TLS implementations (with custom X.509 certificate
/// extensions or validation logic) to be injected into QUIC connections.
///
/// ## Example
///
/// ```swift
/// var config = QUICConfiguration()
/// config.tlsProviderFactory = { isClient in
///     MyCustomTLSProvider(isClient: isClient)
/// }
/// ```
public typealias TLSProviderFactory = @Sendable (_ isClient: Bool) -> any TLS13Provider

// MARK: - Socket Configuration

/// UDP socket-level tuning for a QUIC endpoint.
///
/// These values are applied when the endpoint creates its underlying
/// `NIOQUICSocket`.  They do **not** affect the QUIC protocol itself
/// but control OS-level buffer sizing and the maximum datagram the
/// socket layer will accept.
///
/// ## Relationship to `QUICConfiguration.maxUDPPayloadSize`
///
/// `maxDatagramSize` is the **OS/NIO transport ceiling** — the largest
/// UDP payload the socket will accept or send.  It must always be
/// `>= QUICConfiguration.maxUDPPayloadSize` (the QUIC-level path MTU).
///
/// Typical values:
/// - `maxDatagramSize = 65507` (UDP theoretical max — the default)
/// - `maxUDPPayloadSize = 1200` (RFC 9000 minimum, safe default)
///
/// After DPLPMTUD probing discovers a larger path MTU,
/// `maxUDPPayloadSize` can be raised without touching this value.
///
/// ## Platform Notes
///
/// - **Linux**: `SO_RCVBUF` / `SO_SNDBUF` are capped by
///   `net.core.rmem_max` / `net.core.wmem_max`.  If the requested
///   value exceeds the kernel limit the actual buffer may be smaller.
/// - **macOS / iOS**: The kernel may silently round buffer sizes.
public struct SocketConfiguration: Sendable {
    /// Receive buffer size in bytes (`SO_RCVBUF`).
    ///
    /// A larger buffer reduces the chance of packet drops under burst
    /// load.  Set to `nil` to use the OS default.
    ///
    /// - Default: `65536`
    public var receiveBufferSize: Int?

    /// Send buffer size in bytes (`SO_SNDBUF`).
    ///
    /// - Default: `65536`
    public var sendBufferSize: Int?

    /// Maximum datagram size the socket layer will accept or send.
    ///
    /// This is an **OS/NIO transport limit**, not the QUIC-level path MTU.
    /// It must be `>= QUICConfiguration.maxUDPPayloadSize`.
    /// Typically left at the UDP theoretical maximum (`65507`).
    ///
    /// - Default: `65507`
    public var maxDatagramSize: Int

    /// Whether to enable ECN (Explicit Congestion Notification) on the socket.
    ///
    /// When `true`, the socket layer will:
    /// - Set `IP_RECVTOS` / `IPV6_RECVTCLASS` to receive ECN codepoints
    ///   on incoming packets via ancillary data.
    /// - Set `IP_TOS` / `IPV6_TCLASS` to mark outgoing packets with
    ///   the ECN codepoint chosen by `ECNManager`.
    ///
    /// Requires platform support (`PlatformSocketConstants.isECNSupported`).
    ///
    /// - Default: `true`
    public var enableECN: Bool

    /// Whether to set the Don't Fragment (DF) bit on outgoing packets.
    ///
    /// Required for DPLPMTUD (RFC 8899) to function correctly.
    /// Without DF, intermediate routers may silently fragment packets,
    /// making path MTU discovery impossible.
    ///
    /// - Linux: sets `IP_MTU_DISCOVER = IP_PMTUDISC_DO`
    /// - macOS/iOS: sets `IP_DONTFRAG = 1`
    ///
    /// Requires platform support (`PlatformSocketConstants.isDFSupported`).
    ///
    /// - Default: `true`
    public var enableDF: Bool

    /// Creates a default socket configuration.
    public init() {
        self.receiveBufferSize = 65536
        self.sendBufferSize = 65536
        self.maxDatagramSize = 65507
        self.enableECN = true
        self.enableDF = true
    }

    /// Creates a custom socket configuration.
    ///
    /// - Parameters:
    ///   - receiveBufferSize: `SO_RCVBUF` value, or `nil` for OS default.
    ///   - sendBufferSize: `SO_SNDBUF` value, or `nil` for OS default.
    ///   - maxDatagramSize: Maximum datagram the socket will handle.
    ///     Must be `>= ProtocolLimits.minimumMaximumDatagramSize`.
    ///   - enableECN: Enable ECN socket options. Default `true`.
    ///   - enableDF: Enable Don't Fragment bit. Default `true`.
    public init(
        receiveBufferSize: Int?,
        sendBufferSize: Int?,
        maxDatagramSize: Int = 65507,
        enableECN: Bool = true,
        enableDF: Bool = true
    ) {
        self.receiveBufferSize = receiveBufferSize
        self.sendBufferSize = sendBufferSize
        self.maxDatagramSize = maxDatagramSize
        self.enableECN = enableECN
        self.enableDF = enableDF
    }
}

// MARK: - QUIC Configuration

/// Configuration for a QUIC endpoint
public struct QUICConfiguration: Sendable {
    // MARK: - Connection Settings

    /// Maximum idle timeout (default: 30 seconds)
    public var maxIdleTimeout: Duration

    /// Maximum UDP payload size — the QUIC-level path MTU used for
    /// packet construction, congestion-window calculations, stream-frame
    /// sizing, and Initial-packet padding.
    ///
    /// RFC 9000 Section 14 mandates a minimum of 1200 bytes
    /// (`ProtocolLimits.minimumMaximumDatagramSize`).  Larger values
    /// (e.g. 1452 for typical Ethernet) can be used when the path is
    /// known to support them, or after DPLPMTUD probing.
    ///
    /// This single value is the **source of truth** that flows into
    /// `PacketProcessor`, `CongestionController`, `StreamManager`,
    /// and `CoalescedPacketBuilder`.  Changing it here propagates
    /// everywhere — no other file should hard-code a datagram size.
    ///
    /// - Default: `ProtocolLimits.minimumMaximumDatagramSize` (1200)
    public var maxUDPPayloadSize: Int

    // MARK: - Flow Control

    /// Initial maximum data the peer can send on the connection (default: 10 MB)
    public var initialMaxData: UInt64

    /// Initial max data for locally-initiated bidirectional streams (default: 1 MB)
    public var initialMaxStreamDataBidiLocal: UInt64

    /// Initial max data for remotely-initiated bidirectional streams (default: 1 MB)
    public var initialMaxStreamDataBidiRemote: UInt64

    /// Initial max data for unidirectional streams (default: 1 MB)
    public var initialMaxStreamDataUni: UInt64

    /// Initial max bidirectional streams (default: 100)
    public var initialMaxStreamsBidi: UInt64

    /// Initial max unidirectional streams (default: 100)
    public var initialMaxStreamsUni: UInt64

    // MARK: - Datagram Support (RFC 9221)

    /// Whether to enable QUIC DATAGRAM frame support (RFC 9221).
    ///
    /// When `true`, the `max_datagram_frame_size` transport parameter is
    /// advertised during the handshake, indicating willingness to receive
    /// DATAGRAM frames. Required for WebTransport datagram support.
    ///
    /// - Default: `false`
    public var enableDatagrams: Bool

    /// Maximum DATAGRAM frame payload size this endpoint will accept.
    ///
    /// Only meaningful when `enableDatagrams` is `true`. The value is
    /// advertised as the `max_datagram_frame_size` transport parameter
    /// (RFC 9221 §3). A value of 65535 is the typical maximum.
    ///
    /// - Default: `65535`
    public var maxDatagramFrameSize: UInt64

    // MARK: - ACK Delay

    /// Maximum ack delay in milliseconds (default: 25ms)
    public var maxAckDelay: Duration

    /// ACK delay exponent (default: 3)
    public var ackDelayExponent: UInt64

    // MARK: - Connection ID

    /// Preferred connection ID length (default: 8)
    public var connectionIDLength: Int

    // MARK: - Version

    /// QUIC version to use
    public var version: QUICVersion

    // MARK: - ALPN

    /// Application Layer Protocol Negotiation protocols.
    ///
    /// Used for QUIC transport parameter negotiation. For TLS-level ALPN
    /// configuration, use `TLSConfiguration.alpnProtocols` instead.
    public var alpn: [String]

    // MARK: - TLS Provider

    /// Custom TLS provider factory (legacy).
    ///
    /// When set, this factory is used to create TLS providers for new connections
    /// instead of the default MockTLSProvider. This enables custom TLS
    /// implementations with application-specific certificate authentication.
    ///
    /// - Note: Prefer using `securityMode` for new code. This property is
    ///   maintained for backward compatibility.
    ///
    /// - Parameter isClient: `true` for client connections, `false` for server connections
    /// - Returns: A TLS 1.3 provider instance
    public var tlsProviderFactory: TLSProviderFactory?

    // MARK: - Security Mode

    /// Security mode for TLS configuration.
    ///
    /// This property enforces explicit security configuration to prevent
    /// accidental deployment with insecure defaults.
    ///
    /// - Important: If neither `securityMode` nor `tlsProviderFactory` is set,
    ///   connection attempts will fail with `QUICSecurityError.tlsProviderNotConfigured`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// var config = QUICConfiguration()
    /// config.securityMode = .production { MyTLSProvider() }
    /// ```
    public var securityMode: QUICSecurityMode?

    // MARK: - Congestion Control

    /// Factory for creating congestion control algorithm instances.
    ///
    /// Defaults to `NewRenoFactory()` (RFC 9002 NewReno). Set this to inject
    /// a custom congestion control algorithm (e.g., CUBIC, BBR) for all
    /// connections created with this configuration.
    ///
    /// - Note: This property is `package` access because the `CongestionControllerFactory`
    ///   protocol and its dependency types (`CongestionController`, `RTTEstimator`,
    ///   `SentPacket`) are package-internal. When these types are promoted to `public`,
    ///   this property should be promoted as well.
    package var congestionControllerFactory: any CongestionControllerFactory

    // MARK: - Socket / Transport

    /// UDP socket-level tuning (buffer sizes, max datagram).
    ///
    /// Applied when the endpoint creates its `NIOQUICSocket` via
    /// `serve(host:port:)` or `dial(address:)`.  Has no effect when
    /// a pre-built socket is supplied directly.
    ///
    /// - Default: ``SocketConfiguration()``
    public var socketConfiguration: SocketConfiguration

    // MARK: - Initialization

    /// Creates a default configuration.
    ///
    /// All sizes derive from ``ProtocolLimits`` so that no bare `1200`
    /// literals exist in the configuration layer.
    ///
    /// - Note: Use `TLSConfiguration` for all TLS settings, and prefer
    ///   `QUICConfiguration.production()` or `.development()` factory
    ///   methods for new code.
    public init() {
        self.maxIdleTimeout = .seconds(30)
        self.maxUDPPayloadSize = ProtocolLimits.minimumMaximumDatagramSize
        self.initialMaxData = 10_000_000
        self.initialMaxStreamDataBidiLocal = 1_000_000
        self.initialMaxStreamDataBidiRemote = 1_000_000
        self.initialMaxStreamDataUni = 1_000_000
        self.initialMaxStreamsBidi = 100
        self.initialMaxStreamsUni = 100
        self.maxAckDelay = .milliseconds(25)
        self.ackDelayExponent = 3
        self.connectionIDLength = 8
        self.version = .v1
        self.alpn = ["h3"]
        self.enableDatagrams = false
        self.maxDatagramFrameSize = 65535
        self.tlsProviderFactory = nil
        self.securityMode = nil
        self.congestionControllerFactory = NewRenoFactory()
        self.socketConfiguration = SocketConfiguration()
    }

    // MARK: - Validation

    /// Configuration validation errors.
    public enum ValidationError: Error, CustomStringConvertible, Sendable {
        /// `maxUDPPayloadSize` is below the RFC 9000 minimum (1200).
        case payloadSizeBelowMinimum(configured: Int, minimum: Int)

        /// `socketConfiguration.maxDatagramSize` is smaller than `maxUDPPayloadSize`.
        case socketDatagramSizeTooSmall(socketMax: Int, quicPayload: Int)

        /// `connectionIDLength` is outside the valid range (0-20).
        case connectionIDLengthOutOfRange(Int)

        public var description: String {
            switch self {
            case .payloadSizeBelowMinimum(let configured, let minimum):
                return "maxUDPPayloadSize (\(configured)) < RFC 9000 minimum (\(minimum))"
            case .socketDatagramSizeTooSmall(let socketMax, let quicPayload):
                return "socketConfiguration.maxDatagramSize (\(socketMax)) < maxUDPPayloadSize (\(quicPayload))"
            case .connectionIDLengthOutOfRange(let length):
                return "connectionIDLength (\(length)) outside valid range 0...20"
            }
        }
    }

    /// Validates internal consistency of the configuration.
    ///
    /// Checks:
    /// 1. `maxUDPPayloadSize >= ProtocolLimits.minimumMaximumDatagramSize`
    /// 2. `socketConfiguration.maxDatagramSize >= maxUDPPayloadSize`
    /// 3. `connectionIDLength` in `0...20`
    ///
    /// - Throws: ``ValidationError`` on the first violated constraint.
    public func validate() throws {
        if maxUDPPayloadSize < ProtocolLimits.minimumMaximumDatagramSize {
            throw ValidationError.payloadSizeBelowMinimum(
                configured: maxUDPPayloadSize,
                minimum: ProtocolLimits.minimumMaximumDatagramSize
            )
        }
        if socketConfiguration.maxDatagramSize < maxUDPPayloadSize {
            throw ValidationError.socketDatagramSizeTooSmall(
                socketMax: socketConfiguration.maxDatagramSize,
                quicPayload: maxUDPPayloadSize
            )
        }
        if connectionIDLength < 0 || connectionIDLength > ProtocolLimits.maxConnectionIDLength {
            throw ValidationError.connectionIDLengthOutOfRange(connectionIDLength)
        }
    }

    // MARK: - Security Mode Factory Methods

    /// Creates a production configuration with required TLS.
    ///
    /// Use this for production deployments where security is critical.
    /// The TLS provider factory must produce a properly configured
    /// TLS provider with valid certificates.
    ///
    /// - Parameter tlsProviderFactory: Factory that creates TLS providers
    /// - Returns: A configuration with production security mode
    ///
    /// ## Example
    ///
    /// ```swift
    /// let config = QUICConfiguration.production {
    ///     TLS13Provider(certificatePath: "/path/to/cert.pem")
    /// }
    /// ```
    public static func production(
        tlsProviderFactory: @escaping @Sendable () -> any TLS13Provider
    ) -> QUICConfiguration {
        var config = QUICConfiguration()
        config.securityMode = .production(tlsProviderFactory: tlsProviderFactory)
        return config
    }

    /// Creates a development configuration with TLS but relaxed validation.
    ///
    /// Use this for development and testing environments where
    /// self-signed certificates are acceptable.
    ///
    /// - Parameter tlsProviderFactory: Factory that creates TLS providers
    /// - Returns: A configuration with development security mode
    ///
    /// ## Example
    ///
    /// ```swift
    /// let config = QUICConfiguration.development {
    ///     TLS13Provider(allowSelfSigned: true)
    /// }
    /// ```
    public static func development(
        tlsProviderFactory: @escaping @Sendable () -> any TLS13Provider
    ) -> QUICConfiguration {
        var config = QUICConfiguration()
        config.securityMode = .development(tlsProviderFactory: tlsProviderFactory)
        return config
    }

    #if DEBUG
    /// Creates a testing configuration with MockTLSProvider.
    ///
    /// - Warning: **Never use in production.** This mode disables TLS encryption
    ///   and uses a mock provider that does not provide any security.
    ///
    /// - Returns: A configuration with testing security mode
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Only in unit tests
    /// let config = QUICConfiguration.testing()
    /// ```
    ///
    /// - Note: This method is only available in DEBUG builds.
    @available(*, message: "Testing mode disables TLS encryption. Never use in production.")
    public static func testing() -> QUICConfiguration {
        var config = QUICConfiguration()
        config.securityMode = .testing
        return config
    }
    #endif
}

// MARK: - Transport Parameters Extension

extension TransportParameters {
    /// Creates transport parameters from a configuration (client-side)
    public init(from config: QUICConfiguration, sourceConnectionID: ConnectionID) {
        self.init()
        self.maxIdleTimeout = UInt64(config.maxIdleTimeout.components.seconds * 1000)
        self.maxUDPPayloadSize = UInt64(config.maxUDPPayloadSize)
        self.initialMaxData = config.initialMaxData
        self.initialMaxStreamDataBidiLocal = config.initialMaxStreamDataBidiLocal
        self.initialMaxStreamDataBidiRemote = config.initialMaxStreamDataBidiRemote
        self.initialMaxStreamDataUni = config.initialMaxStreamDataUni
        self.initialMaxStreamsBidi = config.initialMaxStreamsBidi
        self.initialMaxStreamsUni = config.initialMaxStreamsUni
        self.ackDelayExponent = config.ackDelayExponent
        self.maxAckDelay = UInt64(config.maxAckDelay.components.seconds * 1000 +
                                   config.maxAckDelay.components.attoseconds / 1_000_000_000_000_000)
        self.initialSourceConnectionID = sourceConnectionID

        // RFC 9221: Advertise max_datagram_frame_size when datagrams are enabled
        if config.enableDatagrams {
            self.maxDatagramFrameSize = config.maxDatagramFrameSize
        }
    }

    /// Creates transport parameters from a configuration (server-side)
    ///
    /// RFC 9000 Section 18.2: A server MUST include original_destination_connection_id
    /// transport parameter in its transport parameters.
    ///
    /// - Parameters:
    ///   - config: QUIC configuration
    ///   - sourceConnectionID: Server's source connection ID
    ///   - originalDestinationConnectionID: The DCID from the client's first Initial packet
    public init(
        from config: QUICConfiguration,
        sourceConnectionID: ConnectionID,
        originalDestinationConnectionID: ConnectionID
    ) {
        self.init(from: config, sourceConnectionID: sourceConnectionID)
        self.originalDestinationConnectionID = originalDestinationConnectionID
    }
}
