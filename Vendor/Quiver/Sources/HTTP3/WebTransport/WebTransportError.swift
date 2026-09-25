/// WebTransport Error Types (draft-ietf-webtrans-http3)
///
/// Defines error codes, close information, and error types specific
/// to WebTransport sessions over HTTP/3.
///
/// ## Error Hierarchy
///
/// - `WebTransportError` — General errors during session lifecycle
/// - `WebTransportSessionCloseInfo` — Application-level close with code + reason
/// - `WebTransportErrorCode` — Well-known error codes from the spec
///
/// ## References
///
/// - [draft-ietf-webtrans-http3](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
/// - [RFC 9297: HTTP Datagrams](https://www.rfc-editor.org/rfc/rfc9297.html)

import Foundation

// MARK: - WebTransport Session Close Info

/// Information about a WebTransport session closure.
///
/// Sent via the `CLOSE_WEBTRANSPORT_SESSION` capsule on the CONNECT stream
/// to communicate an application-level error code and optional reason string.
///
/// ## Wire Format
///
/// ```
/// CLOSE_WEBTRANSPORT_SESSION Capsule {
///   Type (i) = 0x2843,
///   Length (i),
///   Application Error Code (32),
///   Application Error Message (..)    // UTF-8 string
/// }
/// ```
///
/// ## Usage
///
/// ```swift
/// let closeInfo = WebTransportSessionCloseInfo(
///     errorCode: 0,
///     reason: "Session complete"
/// )
/// try await session.close(closeInfo)
/// ```
public struct WebTransportSessionCloseInfo: Sendable, Hashable {
    /// Application-level error code (32-bit).
    ///
    /// A value of 0 typically indicates a clean closure.
    /// Application-specific codes should be documented by the application protocol.
    public let errorCode: UInt32

    /// Human-readable reason string (UTF-8).
    ///
    /// This is intended for debugging and logging, not for programmatic use.
    /// May be empty.
    public let reason: String

    /// Creates close information.
    ///
    /// - Parameters:
    ///   - errorCode: Application error code (default: 0)
    ///   - reason: Human-readable reason (default: empty)
    public init(errorCode: UInt32 = 0, reason: String = "") {
        self.errorCode = errorCode
        self.reason = reason
    }

    /// A clean closure with no error.
    public static let noError = WebTransportSessionCloseInfo(errorCode: 0, reason: "")
}

// MARK: - CustomStringConvertible

extension WebTransportSessionCloseInfo: CustomStringConvertible {
    public var description: String {
        if reason.isEmpty {
            return "CloseInfo(code=\(errorCode))"
        }
        return "CloseInfo(code=\(errorCode), reason=\"\(reason)\")"
    }
}

// MARK: - WebTransport Error

/// Errors that can occur during WebTransport session operations.
///
/// These represent both protocol-level and application-level errors
/// encountered while establishing, operating, or closing a WebTransport session.
public enum WebTransportError: Error, Sendable, CustomStringConvertible {
    /// The session has not been established yet.
    ///
    /// Operations like `openStream()` or `sendDatagram()` require
    /// the session to be in the `.established` state.
    case sessionNotEstablished

    /// The session has already been closed.
    ///
    /// The session was previously closed (by either side) and can
    /// no longer be used for stream or datagram operations.
    case sessionClosed(WebTransportSessionCloseInfo?)

    /// The session was rejected by the server.
    ///
    /// The server responded to the Extended CONNECT with a non-200 status.
    case sessionRejected(status: Int, reason: String?)

    /// The peer does not support WebTransport.
    ///
    /// The peer's SETTINGS did not include the required WebTransport
    /// settings (`ENABLE_CONNECT_PROTOCOL`, `H3_DATAGRAM`,
    /// `WEBTRANSPORT_MAX_SESSIONS`).
    case peerDoesNotSupportWebTransport(String)

    /// Maximum number of concurrent sessions reached.
    ///
    /// The peer's `SETTINGS_WEBTRANSPORT_MAX_SESSIONS` limit has been reached.
    case maxSessionsExceeded(limit: UInt64)

    /// A stream operation failed.
    ///
    /// An error occurred while opening, reading from, or writing to
    /// a WebTransport stream.
    case streamError(String, underlying: (any Error)?)

    /// A datagram operation failed.
    ///
    /// An error occurred while sending or receiving a datagram.
    case datagramError(String, underlying: (any Error)?)

    /// A capsule encoding or decoding error.
    ///
    /// The capsule data on the CONNECT stream was malformed or
    /// could not be encoded.
    case capsuleError(String)

    /// The session ID is invalid.
    ///
    /// The session ID extracted from a stream or datagram does not
    /// correspond to any known active session.
    case invalidSessionID(UInt64)

    /// An invalid stream was received.
    ///
    /// A WebTransport stream referenced an unknown session or had
    /// a malformed header.
    case invalidStream(String)

    /// The specified stream is not part of this session.
    ///
    /// The stream ID provided to a priority or lifecycle operation
    /// does not correspond to any active stream in the session.
    case unknownStream(UInt64)

    /// An internal error occurred.
    case internalError(String, underlying: (any Error)?)

    /// The underlying HTTP/3 connection encountered an error.
    case http3Error(String, underlying: (any Error)?)

    public var description: String {
        switch self {
        case .sessionNotEstablished:
            return "WebTransport session not established"
        case .sessionClosed(let info):
            if let info = info {
                return "WebTransport session closed: \(info)"
            }
            return "WebTransport session closed"
        case .sessionRejected(let status, let reason):
            if let reason = reason {
                return "WebTransport session rejected with status \(status): \(reason)"
            }
            return "WebTransport session rejected with status \(status)"
        case .peerDoesNotSupportWebTransport(let detail):
            return "Peer does not support WebTransport: \(detail)"
        case .maxSessionsExceeded(let limit):
            return "Maximum WebTransport sessions exceeded (limit: \(limit))"
        case .streamError(let message, let underlying):
            if let underlying = underlying {
                return "WebTransport stream error: \(message) (\(underlying))"
            }
            return "WebTransport stream error: \(message)"
        case .datagramError(let message, let underlying):
            if let underlying = underlying {
                return "WebTransport datagram error: \(message) (\(underlying))"
            }
            return "WebTransport datagram error: \(message)"
        case .capsuleError(let message):
            return "WebTransport capsule error: \(message)"
        case .invalidSessionID(let id):
            return "Invalid WebTransport session ID: \(id)"
        case .invalidStream(let message):
            return "Invalid WebTransport stream: \(message)"
        case .unknownStream(let streamID):
            return "Unknown WebTransport stream: \(streamID)"
        case .internalError(let message, let underlying):
            if let underlying = underlying {
                return "WebTransport internal error: \(message) (\(underlying))"
            }
            return "WebTransport internal error: \(message)"
        case .http3Error(let message, let underlying):
            if let underlying = underlying {
                return "WebTransport HTTP/3 error: \(message) (\(underlying))"
            }
            return "WebTransport HTTP/3 error: \(message)"
        }
    }
}

// MARK: - WebTransport Session State

/// The state of a WebTransport session.
///
/// Sessions progress through a linear lifecycle:
/// ```
/// connecting → established → draining → closed
///                          ↘ closed (if abruptly terminated)
/// ```
public enum WebTransportSessionState: Sendable, Hashable {
    /// The session is being established (Extended CONNECT sent/received,
    /// awaiting response).
    case connecting

    /// The session is established and fully operational.
    /// Streams can be opened, datagrams can be sent.
    case established

    /// The session is draining (DRAIN_WEBTRANSPORT_SESSION received).
    /// No new streams should be opened, but existing streams continue.
    case draining

    /// The session has been closed.
    case closed(WebTransportSessionCloseInfo?)
}

// MARK: - CustomStringConvertible

extension WebTransportSessionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .connecting:
            return "connecting"
        case .established:
            return "established"
        case .draining:
            return "draining"
        case .closed(let info):
            if let info = info {
                return "closed(\(info))"
            }
            return "closed"
        }
    }
}

// MARK: - Well-Known Error Codes

/// Well-known WebTransport application error codes.
///
/// These are not mandated by the spec but represent common conventions
/// used across WebTransport implementations. Applications are free to
/// define their own error code space.
public enum WebTransportErrorCode {
    /// No error — clean session closure.
    public static let noError: UInt32 = 0x00

    /// Generic protocol violation.
    public static let protocolViolation: UInt32 = 0x01

    /// The session timed out.
    public static let sessionTimeout: UInt32 = 0x02

    /// The session was cancelled by the application.
    public static let cancelled: UInt32 = 0x03

    /// Server is going away / shutting down.
    public static let serverGoingAway: UInt32 = 0x04

    /// The application encountered an internal error.
    public static let internalError: UInt32 = 0xFF
}

// MARK: - WebTransport Stream Reset Codes

/// Error codes used for RESET_STREAM and STOP_SENDING on WebTransport streams.
///
/// Per draft-ietf-webtrans-http3, WebTransport uses a specific error code
/// space in the HTTP/3 application error code range.
///
/// The error code mapping is:
/// ```
/// webtransport_code = 0x52e4a40d + application_code
/// ```
///
/// This maps application error codes (0x00..0xFFFFFFFF) to the HTTP/3
/// error code space, avoiding collision with HTTP/3 and QPACK error codes.
public enum WebTransportStreamErrorCode {
    /// The base offset for WebTransport stream error codes.
    ///
    /// WebTransport application error codes are offset by this value
    /// when used in RESET_STREAM and STOP_SENDING frames.
    public static let base: UInt64 = 0x52e4a40d

    /// Converts a WebTransport application error code to an HTTP/3 error code.
    ///
    /// - Parameter applicationCode: The application-level error code
    /// - Returns: The HTTP/3 error code for use in RESET_STREAM / STOP_SENDING
    public static func toHTTP3ErrorCode(_ applicationCode: UInt32) -> UInt64 {
        return base + UInt64(applicationCode)
    }

    /// Converts an HTTP/3 error code back to a WebTransport application error code.
    ///
    /// - Parameter http3Code: The HTTP/3 error code
    /// - Returns: The application error code, or `nil` if the code is not in the
    ///   WebTransport range
    public static func fromHTTP3ErrorCode(_ http3Code: UInt64) -> UInt32? {
        guard http3Code >= base else { return nil }
        let appCode = http3Code - base
        guard appCode <= UInt64(UInt32.max) else { return nil }
        return UInt32(appCode)
    }

    /// Checks if an HTTP/3 error code is in the WebTransport range.
    ///
    /// - Parameter http3Code: The HTTP/3 error code to check
    /// - Returns: `true` if the code is a WebTransport stream error code
    public static func isWebTransportCode(_ http3Code: UInt64) -> Bool {
        return fromHTTP3ErrorCode(http3Code) != nil
    }
}