/// QUIC Connection Handler — Supporting Types
///
/// Types used by `QUICConnectionHandler` for frame processing results,
/// outbound packet queuing, timer actions, and connection close errors.

import Foundation
import QUICCore
import QUICRecovery

// MARK: - Supporting Types

/// Result of processing frames
package struct FrameProcessingResult: Sendable {
    /// Crypto data received at each level
    package var cryptoData: [(EncryptionLevel, Data)] = []

    /// Stream data received (stream ID, data)
    package var streamData: [(UInt64, Data)] = []

    /// New peer-initiated streams that were created
    package var newStreams: [UInt64] = []

    /// Whether the handshake completed
    package var handshakeComplete: Bool = false

    /// Whether the connection was closed
    package var connectionClosed: Bool = false

    /// Streams whose receive side is now complete (FIN received, all data read)
    ///
    /// These streams will not produce any more data.  Readers that are
    /// waiting for data on these streams should be woken with an
    /// end-of-stream signal (empty `Data`).
    package var finishedStreams: [UInt64] = []

    // MARK: - Datagrams (RFC 9221)

    /// DATAGRAM frame payloads received from the peer
    package var datagramsReceived: [Data] = []

    // MARK: - Connection Migration

    /// PATH_CHALLENGE data received (requires PATH_RESPONSE)
    package var pathChallengeData: [Data] = []

    /// PATH_RESPONSE data received (validates our challenge)
    package var pathResponseData: [Data] = []

    /// Path that was successfully validated (if any)
    package var pathValidated: NetworkPath? = nil

    /// Newly discovered path MTU from DPLPMTUD probe acknowledgment.
    ///
    /// Set when a PATH_RESPONSE matches an active PMTUD probe
    /// (via ``PMTUDiscoveryManager/probeAcknowledged(challengeData:)``).
    /// The caller should update `maxDatagramSize` on the connection
    /// and reconfigure the congestion controller with this value.
    package var discoveredPLPMTU: Int? = nil

    /// New connection IDs issued by peer
    package var newConnectionIDs: [NewConnectionIDFrame] = []

    /// Connection IDs retired by peer
    package var retiredConnectionIDs: [UInt64] = []
}

/// Packet to be sent
package struct OutboundPacket: Sendable {
    /// Frames in this packet
    package let frames: [Frame]

    /// Encryption level
    package let level: EncryptionLevel

    /// Creation time
    package let createdAt: ContinuousClock.Instant

    /// Creates an outbound packet
    package init(frames: [Frame], level: EncryptionLevel) {
        self.frames = frames
        self.level = level
        self.createdAt = .now
    }
}

/// Action to take on timer expiry
package enum TimerAction: Sendable {
    /// No action needed
    case none

    /// Retransmit lost packets at the specified level
    case retransmit([SentPacket], level: EncryptionLevel)

    /// Send probe packets
    case probe
}

/// Error for connection close
package struct ConnectionCloseError: Sendable {
    /// Error code
    package let code: UInt64

    /// Reason phrase
    package let reason: String

    /// Creates a connection close error
    package init(code: UInt64, reason: String = "") {
        self.code = code
        self.reason = reason
    }
}