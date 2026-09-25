/// QUIC Frames (RFC 9000 Section 12)
///
/// Frames are the units of structured data within QUIC packets.
/// Each frame type serves a specific purpose in the protocol.

import Foundation

// MARK: - Frame Type

/// QUIC Frame type identifiers (RFC 9000 Section 12.4)
@frozen
public enum FrameType: UInt64, Sendable {
    case padding = 0x00
    case ping = 0x01
    case ack = 0x02
    case ackECN = 0x03
    case resetStream = 0x04
    case stopSending = 0x05
    case crypto = 0x06
    case newToken = 0x07
    // STREAM frames: 0x08 - 0x0f (with flags)
    case stream = 0x08
    case maxData = 0x10
    case maxStreamData = 0x11
    case maxStreamsBidi = 0x12
    case maxStreamsUni = 0x13
    case dataBlocked = 0x14
    case streamDataBlocked = 0x15
    case streamsBlockedBidi = 0x16
    case streamsBlockedUni = 0x17
    case newConnectionID = 0x18
    case retireConnectionID = 0x19
    case pathChallenge = 0x1a
    case pathResponse = 0x1b
    case connectionClose = 0x1c
    case connectionCloseApp = 0x1d
    case handshakeDone = 0x1e
    case datagram = 0x30
    case datagramWithLength = 0x31

    /// Whether this frame type is valid in Initial packets
    @inlinable
    public var validInInitial: Bool {
        switch self {
        case .padding, .ping, .ack, .ackECN, .crypto, .connectionClose:
            return true
        default:
            return false
        }
    }

    /// Whether this frame type is valid in Handshake packets
    @inlinable
    public var validInHandshake: Bool {
        switch self {
        case .padding, .ping, .ack, .ackECN, .crypto, .connectionClose:
            return true
        default:
            return false
        }
    }

    /// Whether this frame type is ack-eliciting
    @inlinable
    public var isAckEliciting: Bool {
        switch self {
        case .padding, .ack, .ackECN, .connectionClose, .connectionCloseApp:
            return false
        default:
            return true
        }
    }
}

// MARK: - Frame

/// A QUIC frame
public enum Frame: Sendable, Hashable {
    /// PADDING frame (type 0x00) - used for padding packets
    case padding(count: Int)

    /// PING frame (type 0x01) - used to keep connection alive
    case ping

    /// ACK frame (type 0x02, 0x03) - acknowledges received packets
    case ack(AckFrame)

    /// RESET_STREAM frame (type 0x04) - abruptly terminates a stream
    case resetStream(ResetStreamFrame)

    /// STOP_SENDING frame (type 0x05) - requests peer stop sending on stream
    case stopSending(StopSendingFrame)

    /// CRYPTO frame (type 0x06) - carries TLS handshake data
    case crypto(CryptoFrame)

    /// NEW_TOKEN frame (type 0x07) - provides token for future connections
    case newToken(Data)

    /// STREAM frame (type 0x08-0x0f) - carries stream data
    case stream(StreamFrame)

    /// MAX_DATA frame (type 0x10) - updates connection-level flow control limit
    case maxData(UInt64)

    /// MAX_STREAM_DATA frame (type 0x11) - updates stream-level flow control limit
    case maxStreamData(MaxStreamDataFrame)

    /// MAX_STREAMS frame (type 0x12, 0x13) - updates stream count limit
    case maxStreams(MaxStreamsFrame)

    /// DATA_BLOCKED frame (type 0x14) - indicates connection-level blocking
    case dataBlocked(UInt64)

    /// STREAM_DATA_BLOCKED frame (type 0x15) - indicates stream-level blocking
    case streamDataBlocked(StreamDataBlockedFrame)

    /// STREAMS_BLOCKED frame (type 0x16, 0x17) - indicates stream count blocking
    case streamsBlocked(StreamsBlockedFrame)

    /// NEW_CONNECTION_ID frame (type 0x18) - provides new connection ID
    case newConnectionID(NewConnectionIDFrame)

    /// RETIRE_CONNECTION_ID frame (type 0x19) - retires a connection ID
    case retireConnectionID(UInt64)

    /// PATH_CHALLENGE frame (type 0x1a) - path validation challenge
    case pathChallenge(Data)

    /// PATH_RESPONSE frame (type 0x1b) - path validation response
    case pathResponse(Data)

    /// CONNECTION_CLOSE frame (type 0x1c, 0x1d) - closes connection
    case connectionClose(ConnectionCloseFrame)

    /// HANDSHAKE_DONE frame (type 0x1e) - signals handshake completion
    case handshakeDone

    /// DATAGRAM frame (type 0x30, 0x31) - unreliable datagram
    case datagram(DatagramFrame)

    /// The frame type identifier
    @inlinable
    public var frameType: FrameType {
        switch self {
        case .padding: return .padding
        case .ping: return .ping
        case .ack(let f): return f.ecnCounts != nil ? .ackECN : .ack
        case .resetStream: return .resetStream
        case .stopSending: return .stopSending
        case .crypto: return .crypto
        case .newToken: return .newToken
        case .stream: return .stream
        case .maxData: return .maxData
        case .maxStreamData: return .maxStreamData
        case .maxStreams(let f): return f.isBidirectional ? .maxStreamsBidi : .maxStreamsUni
        case .dataBlocked: return .dataBlocked
        case .streamDataBlocked: return .streamDataBlocked
        case .streamsBlocked(let f): return f.isBidirectional ? .streamsBlockedBidi : .streamsBlockedUni
        case .newConnectionID: return .newConnectionID
        case .retireConnectionID: return .retireConnectionID
        case .pathChallenge: return .pathChallenge
        case .pathResponse: return .pathResponse
        case .connectionClose(let f): return f.isApplicationError ? .connectionCloseApp : .connectionClose
        case .handshakeDone: return .handshakeDone
        case .datagram(let f): return f.hasLength ? .datagramWithLength : .datagram
        }
    }

    /// Whether this frame is ack-eliciting
    @inlinable
    public var isAckEliciting: Bool {
        frameType.isAckEliciting
    }

    /// Validates if this frame is allowed at the given encryption level
    ///
    /// RFC 9000 Section 12.4 specifies frame types allowed at each level:
    /// - Initial: PADDING, PING, ACK, CRYPTO, CONNECTION_CLOSE
    /// - Handshake: PADDING, PING, ACK, CRYPTO, CONNECTION_CLOSE
    /// - 0-RTT: All frames EXCEPT ACK, CRYPTO, HANDSHAKE_DONE, NEW_TOKEN, PATH_RESPONSE
    /// - 1-RTT (Application): All frames
    ///
    /// - Parameter level: The encryption level
    /// - Returns: `true` if the frame is valid at this level
    public func isValid(at level: EncryptionLevel) -> Bool {
        switch level {
        case .initial:
            return frameType.validInInitial
        case .handshake:
            return frameType.validInHandshake
        case .zeroRTT:
            // RFC 9000 §12.4: 0-RTT packets cannot contain:
            // - ACK frames (would require decrypting 0-RTT packets first)
            // - CRYPTO frames (0-RTT doesn't carry handshake data)
            // - HANDSHAKE_DONE (server-only, post-handshake)
            // - NEW_TOKEN (server-only, post-handshake)
            // - PATH_RESPONSE (requires path validation, not possible in 0-RTT)
            switch frameType {
            case .ack, .ackECN, .crypto, .handshakeDone, .newToken, .pathResponse:
                return false
            default:
                return true
            }
        case .application:
            // All frames are valid at 1-RTT level
            return true
        }
    }
}
