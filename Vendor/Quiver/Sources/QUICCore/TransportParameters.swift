/// QUIC Transport Parameters (RFC 9000 Section 18)
///
/// Parameters exchanged during the TLS handshake to configure the connection.

import Foundation

/// QUIC Transport Parameters exchanged during handshake
public struct TransportParameters: Sendable, Hashable {
    /// Original destination connection ID (server only)
    public var originalDestinationConnectionID: ConnectionID?

    /// Maximum idle timeout in milliseconds
    public var maxIdleTimeout: UInt64

    /// Stateless reset token (server only, 16 bytes)
    public var statelessResetToken: Data?

    /// Maximum UDP payload size
    public var maxUDPPayloadSize: UInt64

    /// Initial maximum data for the connection
    public var initialMaxData: UInt64

    /// Initial max stream data for locally-initiated bidirectional streams
    public var initialMaxStreamDataBidiLocal: UInt64

    /// Initial max stream data for remotely-initiated bidirectional streams
    public var initialMaxStreamDataBidiRemote: UInt64

    /// Initial max stream data for unidirectional streams
    public var initialMaxStreamDataUni: UInt64

    /// Initial max bidirectional streams
    public var initialMaxStreamsBidi: UInt64

    /// Initial max unidirectional streams
    public var initialMaxStreamsUni: UInt64

    /// ACK delay exponent (default 3)
    public var ackDelayExponent: UInt64

    /// Maximum ACK delay in milliseconds (default 25)
    public var maxAckDelay: UInt64

    /// Whether active migration is disabled
    public var disableActiveMigration: Bool

    /// Preferred address for migration (server only)
    public var preferredAddress: PreferredAddress?

    /// Active connection ID limit (minimum 2)
    public var activeConnectionIDLimit: UInt64

    /// Initial source connection ID
    public var initialSourceConnectionID: ConnectionID?

    /// Retry source connection ID (server only, after Retry)
    public var retrySourceConnectionID: ConnectionID?

    /// Maximum DATAGRAM frame size (RFC 9221 §3)
    ///
    /// When present (non-nil), indicates that this endpoint supports
    /// receiving DATAGRAM frames (RFC 9221) and specifies the maximum
    /// size of a DATAGRAM frame payload it is willing to receive.
    ///
    /// A value of 0 means DATAGRAM frames are supported but the endpoint
    /// does not wish to receive any (only send). A value of 65535 is the
    /// typical maximum.
    ///
    /// When nil, DATAGRAM frames are not supported and MUST NOT be sent.
    ///
    /// - Transport parameter ID: 0x0020
    /// - Default: nil (datagrams disabled)
    public var maxDatagramFrameSize: UInt64?

    /// Creates transport parameters with default values
    public init() {
        self.originalDestinationConnectionID = nil
        self.maxIdleTimeout = 30_000  // 30 seconds in ms
        self.statelessResetToken = nil
        self.maxUDPPayloadSize = 65527
        self.initialMaxData = 10_000_000
        self.initialMaxStreamDataBidiLocal = 1_000_000
        self.initialMaxStreamDataBidiRemote = 1_000_000
        self.initialMaxStreamDataUni = 1_000_000
        self.initialMaxStreamsBidi = 100
        self.initialMaxStreamsUni = 100
        self.ackDelayExponent = 3
        self.maxAckDelay = 25  // 25 ms
        self.disableActiveMigration = false
        self.preferredAddress = nil
        self.activeConnectionIDLimit = 2
        self.initialSourceConnectionID = nil
        self.retrySourceConnectionID = nil
        self.maxDatagramFrameSize = nil
    }
}

/// Preferred address for connection migration (RFC 9000 Section 18.2)
public struct PreferredAddress: Sendable, Hashable {
    /// IPv4 address as string (e.g., "192.168.1.1")
    public var ipv4Address: String?

    /// IPv4 port
    public var ipv4Port: UInt16?

    /// IPv6 address as string
    public var ipv6Address: String?

    /// IPv6 port
    public var ipv6Port: UInt16?

    /// Connection ID for the preferred address
    public var connectionID: ConnectionID

    /// Stateless reset token for the preferred address (16 bytes)
    public var statelessResetToken: Data

    /// Creates a preferred address
    public init(
        ipv4Address: String? = nil,
        ipv4Port: UInt16? = nil,
        ipv6Address: String? = nil,
        ipv6Port: UInt16? = nil,
        connectionID: ConnectionID,
        statelessResetToken: Data
    ) {
        self.ipv4Address = ipv4Address
        self.ipv4Port = ipv4Port
        self.ipv6Address = ipv6Address
        self.ipv6Port = ipv6Port
        self.connectionID = connectionID
        self.statelessResetToken = statelessResetToken
    }
}
