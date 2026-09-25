/// QUIC Transport Parameter IDs (RFC 9000 Section 18.2)
///
/// Identifiers for transport parameters exchanged during the TLS handshake.

import Foundation

/// QUIC Transport Parameter IDs (RFC 9000 Section 18.2)
public enum TransportParameterID: UInt64, Sendable, CaseIterable {
    /// Original destination connection ID (0x00)
    case originalDestinationConnectionID = 0x00

    /// Max idle timeout (0x01)
    case maxIdleTimeout = 0x01

    /// Stateless reset token (0x02)
    case statelessResetToken = 0x02

    /// Max UDP payload size (0x03)
    case maxUDPPayloadSize = 0x03

    /// Initial max data (0x04)
    case initialMaxData = 0x04

    /// Initial max stream data for locally-initiated bidi streams (0x05)
    case initialMaxStreamDataBidiLocal = 0x05

    /// Initial max stream data for remotely-initiated bidi streams (0x06)
    case initialMaxStreamDataBidiRemote = 0x06

    /// Initial max stream data for uni streams (0x07)
    case initialMaxStreamDataUni = 0x07

    /// Initial max bidi streams (0x08)
    case initialMaxStreamsBidi = 0x08

    /// Initial max uni streams (0x09)
    case initialMaxStreamsUni = 0x09

    /// ACK delay exponent (0x0a)
    case ackDelayExponent = 0x0a

    /// Max ACK delay (0x0b)
    case maxAckDelay = 0x0b

    /// Disable active migration (0x0c)
    case disableActiveMigration = 0x0c

    /// Preferred address (0x0d)
    case preferredAddress = 0x0d

    /// Active connection ID limit (0x0e)
    case activeConnectionIDLimit = 0x0e

    /// Initial source connection ID (0x0f)
    case initialSourceConnectionID = 0x0f

    /// Retry source connection ID (0x10)
    case retrySourceConnectionID = 0x10

    /// Max datagram frame size (0x0020) — RFC 9221 §3
    ///
    /// When present, indicates support for DATAGRAM frames and the
    /// maximum payload size this endpoint is willing to receive.
    case maxDatagramFrameSize = 0x0020

    /// Whether this parameter is only valid for the server to send
    public var serverOnly: Bool {
        switch self {
        case .originalDestinationConnectionID,
             .statelessResetToken,
             .preferredAddress,
             .retrySourceConnectionID:
            return true
        default:
            return false
        }
    }

    /// Whether this parameter is required
    public var required: Bool {
        switch self {
        case .initialSourceConnectionID:
            return true
        default:
            return false
        }
    }

    /// Default value for this parameter (nil if no default)
    public var defaultValue: UInt64? {
        switch self {
        case .maxIdleTimeout: return 0
        case .maxUDPPayloadSize: return 65527
        case .initialMaxData: return 0
        case .initialMaxStreamDataBidiLocal: return 0
        case .initialMaxStreamDataBidiRemote: return 0
        case .initialMaxStreamDataUni: return 0
        case .initialMaxStreamsBidi: return 0
        case .initialMaxStreamsUni: return 0
        case .ackDelayExponent: return 3
        case .maxAckDelay: return 25
        case .activeConnectionIDLimit: return 2
        default: return nil
        }
    }
}
