/// HTTP/3 Unidirectional Stream Types (RFC 9114 Section 6.2)
///
/// HTTP/3 uses QUIC unidirectional streams for several purposes.
/// Each unidirectional stream starts with a variable-length integer
/// that identifies the stream type.
///
/// ## Wire Format
///
/// ```
/// Unidirectional Stream Header {
///   Stream Type (i),    // QUIC variable-length integer
/// }
/// ```
///
/// The stream type is sent as the first bytes on the stream, followed
/// by type-specific data.
///
/// ## Stream Types
///
/// | Type | Name            | Section | Description                           |
/// |------|-----------------|---------|---------------------------------------|
/// | 0x00 | Control         | 6.2.1   | HTTP/3 control stream (SETTINGS, etc) |
/// | 0x01 | Push            | 6.2.2   | Server push stream                    |
/// | 0x02 | QPACK Encoder   | RFC 9204| QPACK encoder instructions            |
/// | 0x03 | QPACK Decoder   | RFC 9204| QPACK decoder instructions            |
///
/// Each peer MUST open exactly one control stream, one QPACK encoder stream,
/// and one QPACK decoder stream. Opening more than one of any type is a
/// connection error of type H3_STREAM_CREATION_ERROR.
///
/// Unknown stream types MUST be ignored for forward compatibility.

import Foundation

// MARK: - Stream Type Identifiers

/// HTTP/3 unidirectional stream type identifiers (RFC 9114 Section 6.2)
///
/// These identify the purpose of a unidirectional stream. The stream type
/// is sent as the first varint on the stream.
public enum HTTP3StreamType: UInt64, Sendable, Hashable {
    /// Control stream (RFC 9114 Section 6.2.1)
    ///
    /// Carries HTTP/3 control frames: SETTINGS, GOAWAY, MAX_PUSH_ID,
    /// and CANCEL_PUSH. Each side of a connection MUST open exactly
    /// one control stream.
    ///
    /// The first frame on the control stream MUST be a SETTINGS frame.
    /// Receipt of a second SETTINGS frame is a connection error of
    /// type H3_FRAME_UNEXPECTED.
    ///
    /// Closing the control stream is a connection error of type
    /// H3_CLOSED_CRITICAL_STREAM.
    case control = 0x00

    /// Push stream (RFC 9114 Section 6.2.2)
    ///
    /// Carries a server push, identified by a Push ID sent as the
    /// first varint after the stream type. Only the server can open
    /// push streams. The push ID identifies the promise (PUSH_PROMISE)
    /// that the push fulfills.
    case push = 0x01

    /// QPACK encoder stream (RFC 9204 Section 4.2)
    ///
    /// Carries QPACK encoder instructions from the encoder to the decoder.
    /// In literal-only mode (dynamic table size = 0), this stream is
    /// opened but no instructions are sent.
    ///
    /// Each side MUST open exactly one QPACK encoder stream.
    /// Closing this stream is a connection error of type
    /// H3_CLOSED_CRITICAL_STREAM.
    case qpackEncoder = 0x02

    /// QPACK decoder stream (RFC 9204 Section 4.2)
    ///
    /// Carries QPACK decoder instructions (acknowledgements) from the
    /// decoder back to the encoder. In literal-only mode, this stream
    /// is opened but no instructions are sent.
    ///
    /// Each side MUST open exactly one QPACK decoder stream.
    /// Closing this stream is a connection error of type
    /// H3_CLOSED_CRITICAL_STREAM.
    case qpackDecoder = 0x03
}

// MARK: - CustomStringConvertible

extension HTTP3StreamType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .control:
            return "Control(0x00)"
        case .push:
            return "Push(0x01)"
        case .qpackEncoder:
            return "QPACKEncoder(0x02)"
        case .qpackDecoder:
            return "QPACKDecoder(0x03)"
        }
    }
}

// MARK: - Stream Type Properties

extension HTTP3StreamType {
    /// Whether this stream type is a critical stream.
    ///
    /// Critical streams (control, QPACK encoder, QPACK decoder) MUST NOT
    /// be closed. Closing a critical stream is a connection error of type
    /// H3_CLOSED_CRITICAL_STREAM.
    public var isCritical: Bool {
        switch self {
        case .control, .qpackEncoder, .qpackDecoder:
            return true
        case .push:
            return false
        }
    }

    /// Whether this stream type can only be opened by the server.
    ///
    /// Push streams can only be opened by the server. All other stream
    /// types can be opened by either endpoint.
    public var isServerOnly: Bool {
        switch self {
        case .push:
            return true
        case .control, .qpackEncoder, .qpackDecoder:
            return false
        }
    }

    /// Whether each endpoint MUST open exactly one stream of this type.
    ///
    /// Control, QPACK encoder, and QPACK decoder streams are singletons —
    /// each endpoint opens exactly one of each. Opening a second stream
    /// of the same type is a connection error of type H3_STREAM_CREATION_ERROR.
    public var isSingleton: Bool {
        switch self {
        case .control, .qpackEncoder, .qpackDecoder:
            return true
        case .push:
            return false
        }
    }
}

// MARK: - GREASE Stream Types

/// GREASE support for unidirectional stream types
///
/// Per RFC 9114 Section 6.2, stream types of the format `0x1f * N + 0x21`
/// for non-negative integer N are reserved for exercising the requirement
/// that unknown types be ignored. These MUST NOT be treated as errors.
public enum HTTP3GreaseStreamType {
    /// Checks if a stream type is a GREASE value.
    ///
    /// GREASE stream types follow the formula: `0x1f * N + 0x21`
    /// for non-negative integer values of N.
    ///
    /// - Parameter type: The stream type to check
    /// - Returns: `true` if the type matches the GREASE pattern
    public static func isGrease(_ type: UInt64) -> Bool {
        guard type >= 0x21 else { return false }
        return (type - 0x21) % 0x1f == 0
    }

    /// Generates a GREASE stream type value for the given index.
    ///
    /// - Parameter n: The non-negative index
    /// - Returns: The GREASE stream type value (`0x1f * n + 0x21`)
    public static func greaseValue(for n: UInt64) -> UInt64 {
        return 0x1f * n + 0x21
    }
}

// MARK: - Stream Type Classification

/// Classifies an incoming unidirectional stream based on its type byte.
///
/// This is used when processing incoming unidirectional streams to
/// determine how to handle them.
public enum HTTP3StreamClassification: Sendable {
    /// A known HTTP/3 stream type
    case known(HTTP3StreamType)

    /// A GREASE stream type (must be ignored)
    case grease(UInt64)

    /// An unknown stream type (must be ignored per RFC 9114 Section 6.2)
    case unknown(UInt64)

    /// Classifies a stream type value.
    ///
    /// - Parameter type: The stream type value read from the stream
    /// - Returns: The classification of this stream type
    public static func classify(_ type: UInt64) -> HTTP3StreamClassification {
        if let known = HTTP3StreamType(rawValue: type) {
            return .known(known)
        } else if HTTP3GreaseStreamType.isGrease(type) {
            return .grease(type)
        } else {
            return .unknown(type)
        }
    }
}

// MARK: - Stream Type Encoding/Decoding Helpers

import QUICCore

extension HTTP3StreamType {
    /// Encodes the stream type as a QUIC variable-length integer.
    ///
    /// This is used when opening a new unidirectional stream — the stream
    /// type must be sent as the first bytes on the stream.
    ///
    /// - Returns: The varint-encoded stream type bytes
    public func encode() -> Data {
        return Varint(self.rawValue).encode()
    }

    /// Decodes a stream type from the beginning of the given data.
    ///
    /// - Parameter data: The data to decode from (must start with a varint)
    /// - Returns: A tuple of (stream type value, bytes consumed), or nil if
    ///   insufficient data is available
    /// - Throws: If the varint encoding is malformed
    public static func decode(from data: Data) throws -> (UInt64, Int)? {
        guard !data.isEmpty else { return nil }

        let (varint, consumed) = try Varint.decode(from: data)
        return (varint.value, consumed)
    }
}
