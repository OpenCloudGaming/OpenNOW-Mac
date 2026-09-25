/// QLOG Helper Extensions
///
/// Extensions for converting QUIC types to QLOG-compatible formats.

import Foundation

// MARK: - Encryption Level

extension EncryptionLevel {
    /// QLOG-compatible name for this encryption level
    public var qlogName: String {
        switch self {
        case .initial:
            return "initial"
        case .handshake:
            return "handshake"
        case .zeroRTT:
            return "0rtt"
        case .application:
            return "1rtt"
        }
    }
}

// MARK: - Frame Type

extension FrameType {
    /// QLOG-compatible name for this frame type
    public var qlogName: String {
        switch self {
        case .padding:
            return "padding"
        case .ping:
            return "ping"
        case .ack, .ackECN:
            return "ack"
        case .resetStream:
            return "reset_stream"
        case .stopSending:
            return "stop_sending"
        case .crypto:
            return "crypto"
        case .newToken:
            return "new_token"
        case .stream:
            return "stream"
        case .maxData:
            return "max_data"
        case .maxStreamData:
            return "max_stream_data"
        case .maxStreamsBidi, .maxStreamsUni:
            return "max_streams"
        case .dataBlocked:
            return "data_blocked"
        case .streamDataBlocked:
            return "stream_data_blocked"
        case .streamsBlockedBidi, .streamsBlockedUni:
            return "streams_blocked"
        case .newConnectionID:
            return "new_connection_id"
        case .retireConnectionID:
            return "retire_connection_id"
        case .pathChallenge:
            return "path_challenge"
        case .pathResponse:
            return "path_response"
        case .connectionClose, .connectionCloseApp:
            return "connection_close"
        case .handshakeDone:
            return "handshake_done"
        case .datagram, .datagramWithLength:
            return "datagram"
        }
    }
}

// MARK: - Frame

extension Frame {
    /// QLOG-compatible name for this frame
    public var qlogName: String {
        switch self {
        case .padding:
            return "padding"
        case .ping:
            return "ping"
        case .ack:
            return "ack"
        case .resetStream:
            return "reset_stream"
        case .stopSending:
            return "stop_sending"
        case .crypto:
            return "crypto"
        case .newToken:
            return "new_token"
        case .stream:
            return "stream"
        case .maxData:
            return "max_data"
        case .maxStreamData:
            return "max_stream_data"
        case .maxStreams:
            return "max_streams"
        case .dataBlocked:
            return "data_blocked"
        case .streamDataBlocked:
            return "stream_data_blocked"
        case .streamsBlocked:
            return "streams_blocked"
        case .newConnectionID:
            return "new_connection_id"
        case .retireConnectionID:
            return "retire_connection_id"
        case .pathChallenge:
            return "path_challenge"
        case .pathResponse:
            return "path_response"
        case .connectionClose:
            return "connection_close"
        case .handshakeDone:
            return "handshake_done"
        case .datagram:
            return "datagram"
        }
    }

    /// Payload length for this frame (if applicable)
    public var payloadLength: Int? {
        switch self {
        case .stream(let frame):
            return frame.data.count
        case .crypto(let frame):
            return frame.data.count
        case .newToken(let data):
            return data.count
        case .datagram(let frame):
            return frame.data.count
        default:
            return nil
        }
    }

    /// Convert to QLOG frame info
    public var qlogFrameInfo: QLOGFrameInfo {
        QLOGFrameInfo(frameType: qlogName, length: payloadLength)
    }
}

// MARK: - Connection ID

extension ConnectionID {
    /// Hex string representation for QLOG
    public var qlogHex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Data

extension Data {
    /// Hex string representation for QLOG
    public var qlogHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - QUIC Version

extension QUICVersion {
    /// QLOG-compatible string representation
    public var qlogString: String {
        String(format: "0x%08x", rawValue)
    }
}
