/// HTTP/3 Error Codes (RFC 9114 Section 8.1)
///
/// HTTP/3 defines a set of error codes that are used in:
/// - CONNECTION_CLOSE frames (QUIC transport error)
/// - RESET_STREAM frames (stream-level error)
/// - STOP_SENDING frames (stream-level error)
///
/// Error codes are 62-bit integers (QUIC varint range). The HTTP/3
/// error code space is separate from the QUIC transport error space.
///
/// ## Error Code Ranges
///
/// | Range          | Purpose                      |
/// |----------------|------------------------------|
/// | 0x0100-0x0110  | HTTP/3 defined errors        |
/// | 0x0200-0x02ff  | Reserved for QPACK errors    |
/// | Others         | Available for extensions     |
///
/// ## GREASE Error Codes
///
/// Error codes of the form `0x1f * N + 0x21` are reserved for GREASE
/// and MUST NOT be treated as unknown errors by implementations.

import Foundation

// MARK: - HTTP/3 Error Codes

/// HTTP/3 error codes (RFC 9114 Section 8.1)
///
/// These error codes are used in QUIC CONNECTION_CLOSE, RESET_STREAM,
/// and STOP_SENDING frames to indicate HTTP/3-specific error conditions.
///
/// ## Usage
///
/// ```swift
/// // Close connection with error
/// await connection.close(applicationError: HTTP3ErrorCode.closedCriticalStream.rawValue,
///                        reason: "Control stream closed unexpectedly")
///
/// // Reset a stream
/// await stream.reset(errorCode: HTTP3ErrorCode.requestCancelled.rawValue)
/// ```
public enum HTTP3ErrorCode: UInt64, Sendable, Hashable {

    /// H3_NO_ERROR (0x0100)
    ///
    /// No error. Used when the connection or stream needs to be closed
    /// but there is no error to signal.
    case noError = 0x0100

    /// H3_GENERAL_PROTOCOL_ERROR (0x0101)
    ///
    /// Peer violated protocol requirements in a way that does not match
    /// a more specific error code, or peer sent a frame type that was
    /// unexpected for the stream type.
    case generalProtocolError = 0x0101

    /// H3_INTERNAL_ERROR (0x0102)
    ///
    /// An internal error has occurred in the HTTP stack.
    case internalError = 0x0102

    /// H3_STREAM_CREATION_ERROR (0x0103)
    ///
    /// The endpoint detected that its peer created a stream that it
    /// will not accept (e.g., wrong stream type or too many streams).
    case streamCreationError = 0x0103

    /// H3_CLOSED_CRITICAL_STREAM (0x0104)
    ///
    /// A stream required by the HTTP/3 connection was closed or reset.
    /// Critical streams include the control stream and QPACK streams.
    case closedCriticalStream = 0x0104

    /// H3_FRAME_UNEXPECTED (0x0105)
    ///
    /// A frame was received that was not permitted in the current state
    /// or on the current stream type.
    case frameUnexpected = 0x0105

    /// H3_FRAME_ERROR (0x0106)
    ///
    /// A frame that fails to satisfy layout requirements or with an
    /// invalid size was received.
    case frameError = 0x0106

    /// H3_EXCESSIVE_LOAD (0x0107)
    ///
    /// The endpoint determined that its peer is exhibiting behavior
    /// that might be generating excessive load.
    case excessiveLoad = 0x0107

    /// H3_ID_ERROR (0x0108)
    ///
    /// A stream ID or push ID was used incorrectly, such as exceeding
    /// a limit, reducing a limit, or being reused.
    case idError = 0x0108

    /// H3_SETTINGS_ERROR (0x0109)
    ///
    /// An endpoint detected an error in the payload of a SETTINGS frame.
    case settingsError = 0x0109

    /// H3_MISSING_SETTINGS (0x010a)
    ///
    /// No SETTINGS frame was received at the beginning of the control
    /// stream. The first frame on the control stream MUST be SETTINGS.
    case missingSettings = 0x010a

    /// H3_REQUEST_REJECTED (0x010b)
    ///
    /// A server rejected a request without performing any application
    /// processing. The client can safely retry the request.
    case requestRejected = 0x010b

    /// H3_REQUEST_CANCELLED (0x010c)
    ///
    /// The request or its response (including pushed response) is
    /// cancelled. The client should not retry if server processing
    /// may have already occurred.
    case requestCancelled = 0x010c

    /// H3_REQUEST_INCOMPLETE (0x010d)
    ///
    /// The client's stream terminated without containing a fully
    /// formed request.
    case requestIncomplete = 0x010d

    /// H3_MESSAGE_ERROR (0x010e)
    ///
    /// An HTTP message was malformed and cannot be processed.
    case messageError = 0x010e

    /// H3_CONNECT_ERROR (0x010f)
    ///
    /// The TCP connection established in response to a CONNECT request
    /// was reset or abnormally closed.
    case connectError = 0x010f

    /// H3_VERSION_FALLBACK (0x0110)
    ///
    /// The requested operation cannot be served over HTTP/3. The peer
    /// should retry over HTTP/1.1.
    case versionFallback = 0x0110
}

// MARK: - CustomStringConvertible

extension HTTP3ErrorCode: CustomStringConvertible {
    /// Returns the RFC name of the error code
    public var description: String {
        switch self {
        case .noError:
            return "H3_NO_ERROR"
        case .generalProtocolError:
            return "H3_GENERAL_PROTOCOL_ERROR"
        case .internalError:
            return "H3_INTERNAL_ERROR"
        case .streamCreationError:
            return "H3_STREAM_CREATION_ERROR"
        case .closedCriticalStream:
            return "H3_CLOSED_CRITICAL_STREAM"
        case .frameUnexpected:
            return "H3_FRAME_UNEXPECTED"
        case .frameError:
            return "H3_FRAME_ERROR"
        case .excessiveLoad:
            return "H3_EXCESSIVE_LOAD"
        case .idError:
            return "H3_ID_ERROR"
        case .settingsError:
            return "H3_SETTINGS_ERROR"
        case .missingSettings:
            return "H3_MISSING_SETTINGS"
        case .requestRejected:
            return "H3_REQUEST_REJECTED"
        case .requestCancelled:
            return "H3_REQUEST_CANCELLED"
        case .requestIncomplete:
            return "H3_REQUEST_INCOMPLETE"
        case .messageError:
            return "H3_MESSAGE_ERROR"
        case .connectError:
            return "H3_CONNECT_ERROR"
        case .versionFallback:
            return "H3_VERSION_FALLBACK"
        }
    }

    /// A human-readable explanation of the error
    public var reason: String {
        switch self {
        case .noError:
            return "No error"
        case .generalProtocolError:
            return "General protocol violation"
        case .internalError:
            return "Internal error in HTTP stack"
        case .streamCreationError:
            return "Stream creation not permitted"
        case .closedCriticalStream:
            return "Critical stream was closed"
        case .frameUnexpected:
            return "Frame not permitted in current state"
        case .frameError:
            return "Frame format error"
        case .excessiveLoad:
            return "Peer generating excessive load"
        case .idError:
            return "Stream ID or push ID used incorrectly"
        case .settingsError:
            return "Error in SETTINGS frame payload"
        case .missingSettings:
            return "No SETTINGS frame received on control stream"
        case .requestRejected:
            return "Request rejected without processing"
        case .requestCancelled:
            return "Request or response cancelled"
        case .requestIncomplete:
            return "Client stream terminated without complete request"
        case .messageError:
            return "Malformed HTTP message"
        case .connectError:
            return "TCP connection for CONNECT request failed"
        case .versionFallback:
            return "Retry request over HTTP/1.1"
        }
    }
}

// MARK: - QPACK Error Codes

/// QPACK error codes (RFC 9204 Section 6)
///
/// These error codes are used in HTTP/3 CONNECTION_CLOSE frames
/// to indicate QPACK-specific error conditions.
public enum QPACKErrorCode: UInt64, Sendable, Hashable {
    /// QPACK_DECOMPRESSION_FAILED (0x0200)
    ///
    /// The decoder failed to interpret an encoded field section.
    case decompressionFailed = 0x0200

    /// QPACK_ENCODER_STREAM_ERROR (0x0201)
    ///
    /// The decoder failed to interpret an encoder instruction received
    /// on the encoder stream.
    case encoderStreamError = 0x0201

    /// QPACK_DECODER_STREAM_ERROR (0x0202)
    ///
    /// The encoder failed to interpret a decoder instruction received
    /// on the decoder stream.
    case decoderStreamError = 0x0202
}

extension QPACKErrorCode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .decompressionFailed:
            return "QPACK_DECOMPRESSION_FAILED"
        case .encoderStreamError:
            return "QPACK_ENCODER_STREAM_ERROR"
        case .decoderStreamError:
            return "QPACK_DECODER_STREAM_ERROR"
        }
    }
}

// MARK: - HTTP/3 Error Type

/// A structured HTTP/3 error
///
/// Wraps an error code with an optional human-readable reason string.
/// This is the primary error type thrown by HTTP/3 operations.
///
/// ## Usage
///
/// ```swift
/// throw HTTP3Error(code: .frameUnexpected, reason: "DATA frame on control stream")
/// ```
public struct HTTP3Error: Error, Sendable, CustomStringConvertible {
    /// The HTTP/3 error code
    public let code: HTTP3ErrorCode

    /// An optional human-readable reason for the error
    public let reason: String?

    /// The underlying error, if any
    public let underlyingError: (any Error)?

    /// Creates an HTTP/3 error with an error code and optional reason.
    ///
    /// - Parameters:
    ///   - code: The HTTP/3 error code
    ///   - reason: Optional human-readable description
    ///   - underlyingError: Optional underlying error that caused this
    public init(code: HTTP3ErrorCode, reason: String? = nil, underlyingError: (any Error)? = nil) {
        self.code = code
        self.reason = reason
        self.underlyingError = underlyingError
    }

    public var description: String {
        var result = "\(code) (0x\(String(code.rawValue, radix: 16)))"
        if let reason = reason {
            result += ": \(reason)"
        }
        return result
    }

    /// Whether this error indicates the connection should be closed
    ///
    /// Connection-level errors require sending a QUIC CONNECTION_CLOSE frame.
    /// Stream-level errors use RESET_STREAM or STOP_SENDING.
    public var isConnectionError: Bool {
        switch code {
        case .closedCriticalStream,
             .missingSettings,
             .settingsError,
             .frameUnexpected,
             .frameError,
             .generalProtocolError,
             .idError,
             .excessiveLoad:
            return true
        case .noError,
             .internalError,
             .streamCreationError,
             .requestRejected,
             .requestCancelled,
             .requestIncomplete,
             .messageError,
             .connectError,
             .versionFallback:
            return false
        }
    }

    /// Whether the request that caused this error is safe to retry
    ///
    /// Only `H3_REQUEST_REJECTED` explicitly allows retry.
    public var isRetryable: Bool {
        return code == .requestRejected
    }
}

// MARK: - Convenience Constructors

extension HTTP3Error {
    /// Creates a "no error" instance for graceful shutdown
    public static let noError = HTTP3Error(code: .noError)

    /// Creates a general protocol error
    public static func protocolError(_ reason: String) -> HTTP3Error {
        HTTP3Error(code: .generalProtocolError, reason: reason)
    }

    /// Creates an internal error
    public static func internalError(_ reason: String, underlying: (any Error)? = nil) -> HTTP3Error {
        HTTP3Error(code: .internalError, reason: reason, underlyingError: underlying)
    }

    /// Creates a frame unexpected error
    public static func frameUnexpected(_ reason: String) -> HTTP3Error {
        HTTP3Error(code: .frameUnexpected, reason: reason)
    }

    /// Creates a frame error
    public static func frameError(_ reason: String) -> HTTP3Error {
        HTTP3Error(code: .frameError, reason: reason)
    }

    /// Creates a missing settings error
    public static let missingSettings = HTTP3Error(
        code: .missingSettings,
        reason: "No SETTINGS frame received on control stream"
    )

    /// Creates a settings error
    public static func settingsError(_ reason: String) -> HTTP3Error {
        HTTP3Error(code: .settingsError, reason: reason)
    }

    /// Creates a closed critical stream error
    public static func closedCriticalStream(_ reason: String) -> HTTP3Error {
        HTTP3Error(code: .closedCriticalStream, reason: reason)
    }

    /// Creates a message error for malformed HTTP messages
    public static func messageError(_ reason: String) -> HTTP3Error {
        HTTP3Error(code: .messageError, reason: reason)
    }

    /// Creates a request cancelled error
    public static let requestCancelled = HTTP3Error(code: .requestCancelled)
}

// MARK: - GREASE Error Codes

extension HTTP3ErrorCode {
    /// Checks if an error code value is a GREASE value
    ///
    /// GREASE error codes follow the formula: `0x1f * N + 0x21`
    /// for non-negative integer values of N.
    ///
    /// - Parameter code: The error code value to check
    /// - Returns: `true` if the code matches the GREASE pattern
    public static func isGrease(_ code: UInt64) -> Bool {
        guard code >= 0x21 else { return false }
        return (code - 0x21) % 0x1f == 0
    }
}