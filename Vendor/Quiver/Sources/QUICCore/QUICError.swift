/// QUIC Error Codes and Error Handling
///
/// Error codes defined in RFC 9000 Section 20

import Foundation

// MARK: - Transport Error Codes

/// QUIC Transport Error Codes (RFC 9000 Section 20.1)
public enum TransportErrorCode: UInt64, Sendable, Hashable {
    /// No error
    case noError = 0x00

    /// Implementation error
    case internalError = 0x01

    /// Server refused connection
    case connectionRefused = 0x02

    /// Flow control error
    case flowControlError = 0x03

    /// Stream limit error
    case streamLimitError = 0x04

    /// Stream state error
    case streamStateError = 0x05

    /// Final size error
    case finalSizeError = 0x06

    /// Frame encoding error
    case frameEncodingError = 0x07

    /// Transport parameter error
    case transportParameterError = 0x08

    /// Connection ID limit error
    case connectionIDLimitError = 0x09

    /// Protocol violation
    case protocolViolation = 0x0a

    /// Invalid token
    case invalidToken = 0x0b

    /// Application error (carried in APPLICATION_CLOSE)
    case applicationError = 0x0c

    /// Crypto buffer exceeded
    case cryptoBufferExceeded = 0x0d

    /// Key update error
    case keyUpdateError = 0x0e

    /// AEAD limit reached
    case aeadLimitReached = 0x0f

    /// No viable path
    case noViablePath = 0x10

    /// Crypto error range start (0x100-0x1ff reserved for TLS alerts)
    case cryptoError = 0x100
}

// MARK: - QUIC Error

/// Errors that can occur in QUIC operations
public enum QUICError: Error, Sendable {
    // MARK: - Connection Errors

    /// Connection was closed by peer
    case connectionClosed(errorCode: UInt64, reason: String)

    /// Connection timed out
    case connectionTimeout

    /// Connection refused by peer
    case connectionRefused

    /// Handshake failed
    case handshakeFailed(underlying: Error?)

    /// Version negotiation required
    case versionNegotiation(supported: [UInt32])

    /// Invalid token received
    case invalidToken

    // MARK: - Stream Errors

    /// Stream was reset by peer
    case streamReset(streamID: UInt64, errorCode: UInt64)

    /// Stream is closed
    case streamClosed(streamID: UInt64)

    /// Invalid stream ID
    case invalidStreamID(UInt64)

    /// Stream limit exceeded
    case streamLimitExceeded

    /// Stream state error
    case streamStateError(streamID: UInt64)

    // MARK: - Flow Control Errors

    /// Flow control limit exceeded
    case flowControlError

    /// Data blocked
    case dataBlocked

    // MARK: - Packet Errors

    /// Invalid packet format
    case invalidPacket(String)

    /// Decryption failed
    case decryptionFailed

    /// Packet number decode error
    case packetNumberError

    /// Unsupported version
    case unsupportedVersion(UInt32)

    // MARK: - Frame Errors

    /// Invalid frame format
    case invalidFrame(String)

    /// Frame not allowed in this packet type
    case frameNotAllowed(frameType: UInt64, packetType: String)

    // MARK: - Crypto Errors

    /// TLS error
    case tlsError(String)

    /// Certificate error
    case certificateError(String)

    /// Key derivation error
    case keyDerivationError

    // MARK: - Internal Errors

    /// Internal error
    case internalError(String)

    /// Buffer too small
    case bufferTooSmall

    /// Operation would block
    case wouldBlock

    /// Not connected
    case notConnected

    /// Already connected
    case alreadyConnected
}

// MARK: - CustomStringConvertible

extension QUICError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connectionClosed(let errorCode, let reason):
            return "Connection closed (error: 0x\(String(format: "%x", errorCode)), reason: \(reason))"
        case .connectionTimeout:
            return "Connection timed out"
        case .connectionRefused:
            return "Connection refused"
        case .handshakeFailed(let underlying):
            if let error = underlying {
                return "Handshake failed: \(error)"
            }
            return "Handshake failed"
        case .versionNegotiation(let supported):
            return "Version negotiation required, supported: \(supported.map { "0x\(String(format: "%x", $0))" })"
        case .invalidToken:
            return "Invalid token"
        case .streamReset(let streamID, let errorCode):
            return "Stream \(streamID) reset (error: 0x\(String(format: "%x", errorCode)))"
        case .streamClosed(let streamID):
            return "Stream \(streamID) is closed"
        case .invalidStreamID(let id):
            return "Invalid stream ID: \(id)"
        case .streamLimitExceeded:
            return "Stream limit exceeded"
        case .streamStateError(let streamID):
            return "Stream state error for stream \(streamID)"
        case .flowControlError:
            return "Flow control error"
        case .dataBlocked:
            return "Data blocked"
        case .invalidPacket(let msg):
            return "Invalid packet: \(msg)"
        case .decryptionFailed:
            return "Decryption failed"
        case .packetNumberError:
            return "Packet number error"
        case .unsupportedVersion(let version):
            return "Unsupported version: 0x\(String(format: "%x", version))"
        case .invalidFrame(let msg):
            return "Invalid frame: \(msg)"
        case .frameNotAllowed(let frameType, let packetType):
            return "Frame type 0x\(String(format: "%x", frameType)) not allowed in \(packetType) packet"
        case .tlsError(let msg):
            return "TLS error: \(msg)"
        case .certificateError(let msg):
            return "Certificate error: \(msg)"
        case .keyDerivationError:
            return "Key derivation error"
        case .internalError(let msg):
            return "Internal error: \(msg)"
        case .bufferTooSmall:
            return "Buffer too small"
        case .wouldBlock:
            return "Operation would block"
        case .notConnected:
            return "Not connected"
        case .alreadyConnected:
            return "Already connected"
        }
    }
}

// MARK: - Transport Error Code Mapping

extension QUICError {
    /// Returns the transport error code for this error
    public var transportErrorCode: TransportErrorCode {
        switch self {
        case .connectionClosed, .connectionTimeout, .connectionRefused:
            return .noError
        case .handshakeFailed, .tlsError, .certificateError:
            return .cryptoError
        case .versionNegotiation:
            return .noError
        case .invalidToken:
            return .invalidToken
        case .streamReset, .streamClosed, .streamStateError:
            return .streamStateError
        case .invalidStreamID, .streamLimitExceeded:
            return .streamLimitError
        case .flowControlError, .dataBlocked:
            return .flowControlError
        case .invalidPacket, .invalidFrame, .packetNumberError:
            return .frameEncodingError
        case .decryptionFailed:
            return .cryptoError
        case .unsupportedVersion:
            return .protocolViolation
        case .frameNotAllowed:
            return .protocolViolation
        case .keyDerivationError:
            return .cryptoError
        case .internalError, .bufferTooSmall:
            return .internalError
        case .wouldBlock, .notConnected, .alreadyConnected:
            return .internalError
        }
    }
}
