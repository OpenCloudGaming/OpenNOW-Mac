/// HTTP/3 Frame Types and Definitions (RFC 9114 Section 7.2, RFC 9218)
///
/// HTTP/3 frames are the basic protocol unit exchanged on QUIC streams.
/// Each frame has a type, a length, and a type-dependent payload.
///
/// ## Wire Format (RFC 9114 Section 7.1)
///
/// ```
/// HTTP/3 Frame {
///   Type (i),         // QUIC variable-length integer
///   Length (i),        // QUIC variable-length integer
///   Frame Payload (..) // Length bytes
/// }
/// ```
///
/// ## Frame Types
///
/// | Type  | Name          | Section |
/// |-------|---------------|---------|
/// | 0x00  | DATA          | 7.2.1   |
/// | 0x01  | HEADERS       | 7.2.2   |
/// | 0x03  | CANCEL_PUSH   | 7.2.3   |
/// | 0x04  | SETTINGS      | 7.2.4   |
/// | 0x05  | PUSH_PROMISE  | 7.2.5   |
/// | 0x07  | GOAWAY        | 7.2.6   |
/// | 0x0d  | MAX_PUSH_ID   | 7.2.7   |
///
/// Unknown frame types MUST be ignored for forward compatibility
/// (RFC 9114 Section 9).

import Foundation
import QUICStream

// MARK: - Frame Type Identifiers

/// HTTP/3 frame type identifiers (RFC 9114 Section 7.2)
///
/// These are the well-known frame types defined by RFC 9114.
/// Additional frame types may be defined by extensions and MUST
/// be handled gracefully (unknown types are ignored).
public enum HTTP3FrameType: UInt64, Sendable, Hashable {
    /// DATA frame (Section 7.2.1)
    ///
    /// Conveys arbitrary, variable-length sequences of bytes associated
    /// with an HTTP request or response payload.
    case data = 0x00

    /// HEADERS frame (Section 7.2.2)
    ///
    /// Used to carry an HTTP field section, encoded using QPACK.
    /// HEADERS frames can be sent on request streams and push streams.
    case headers = 0x01

    /// CANCEL_PUSH frame (Section 7.2.3)
    ///
    /// Used to request cancellation of a server push prior to the
    /// push stream being received. Sent on the control stream.
    case cancelPush = 0x03

    /// SETTINGS frame (Section 7.2.4)
    ///
    /// Conveys configuration parameters that affect how endpoints
    /// communicate. MUST be sent as the first frame on the control stream.
    case settings = 0x04

    /// PUSH_PROMISE frame (Section 7.2.5)
    ///
    /// Used to carry a promised request header section from server to client
    /// on a request stream. Not implemented in this initial version.
    case pushPromise = 0x05

    /// GOAWAY frame (Section 7.2.6)
    ///
    /// Used to initiate graceful shutdown of an HTTP/3 connection.
    /// Sent on the control stream to indicate the last stream ID that
    /// was or might be processed.
    case goaway = 0x07

    /// MAX_PUSH_ID frame (Section 7.2.7)
    ///
    /// Used by the client to control the maximum push ID the server
    /// can use. Sent on the control stream.
    case maxPushID = 0x0d
}

extension HTTP3FrameType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .data: return "DATA"
        case .headers: return "HEADERS"
        case .cancelPush: return "CANCEL_PUSH"
        case .settings: return "SETTINGS"
        case .pushPromise: return "PUSH_PROMISE"
        case .goaway: return "GOAWAY"
        case .maxPushID: return "MAX_PUSH_ID"
        }
    }
}

// MARK: - HTTP/3 Frame

/// An HTTP/3 frame (RFC 9114 Section 7)
///
/// Represents a decoded HTTP/3 frame including its type and payload.
/// Unknown frame types are preserved as `.unknown` for forward
/// compatibility — they MUST be ignored per RFC 9114 Section 9.
///
/// ## Usage
///
/// ```swift
/// // Creating frames
/// let dataFrame = HTTP3Frame.data(Data("Hello".utf8))
/// let headersFrame = HTTP3Frame.headers(qpackEncodedHeaders)
/// let settingsFrame = HTTP3Frame.settings(HTTP3Settings())
/// let goawayFrame = HTTP3Frame.goaway(streamID: 4)
///
/// // Inspecting frames
/// switch frame {
/// case .data(let payload):
///     print("Received \(payload.count) bytes of data")
/// case .headers(let headerBlock):
///     let headers = try decoder.decode(headerBlock)
/// case .settings(let settings):
///     print("Max field section size: \(settings.maxFieldSectionSize)")
/// case .unknown(let type, _):
///     print("Ignoring unknown frame type: \(type)")
/// default:
///     break
/// }
/// ```
public enum HTTP3Frame: Sendable {
    /// DATA frame (Section 7.2.1)
    ///
    /// Contains raw payload data for an HTTP message body.
    /// DATA frames can only appear on request streams.
    ///
    /// ```
    /// DATA Frame {
    ///   Type (i) = 0x00,
    ///   Length (i),
    ///   Data (..)
    /// }
    /// ```
    case data(Data)

    /// HEADERS frame (Section 7.2.2)
    ///
    /// Contains a QPACK-encoded field section (header block).
    /// HEADERS frames can appear on request streams and push streams.
    ///
    /// The payload is the raw QPACK-encoded bytes; use a `QPACKDecoder`
    /// to decode them into header field pairs.
    ///
    /// ```
    /// HEADERS Frame {
    ///   Type (i) = 0x01,
    ///   Length (i),
    ///   Encoded Field Section (..)
    /// }
    /// ```
    case headers(Data)

    /// CANCEL_PUSH frame (Section 7.2.3)
    ///
    /// Requests cancellation of a server push identified by the push ID.
    /// CANCEL_PUSH frames are sent on the control stream.
    ///
    /// ```
    /// CANCEL_PUSH Frame {
    ///   Type (i) = 0x03,
    ///   Length (i),
    ///   Push ID (i)
    /// }
    /// ```
    case cancelPush(pushID: UInt64)

    /// SETTINGS frame (Section 7.2.4)
    ///
    /// Conveys configuration parameters. MUST be the first frame sent
    /// on the control stream by each peer. A SETTINGS frame MUST NOT
    /// be sent more than once or on any stream other than the control stream.
    ///
    /// ```
    /// SETTINGS Frame {
    ///   Type (i) = 0x04,
    ///   Length (i),
    ///   Setting {
    ///     Identifier (i),
    ///     Value (i),
    ///   } ...
    /// }
    /// ```
    case settings(HTTP3Settings)

    /// PUSH_PROMISE frame (Section 7.2.5)
    ///
    /// Carries a promised request header section from server to client.
    /// Contains a push ID and a QPACK-encoded header block.
    /// Sent on a request stream.
    ///
    /// ```
    /// PUSH_PROMISE Frame {
    ///   Type (i) = 0x05,
    ///   Length (i),
    ///   Push ID (i),
    ///   Encoded Field Section (..)
    /// }
    /// ```
    case pushPromise(pushID: UInt64, headerBlock: Data)

    /// GOAWAY frame (Section 7.2.6)
    ///
    /// Initiates graceful shutdown of the HTTP/3 connection.
    /// Contains the stream ID or push ID of the last request/push
    /// that was or might be processed.
    ///
    /// For client-initiated shutdown, the value is a stream ID.
    /// For server-initiated shutdown, the value is a push ID.
    ///
    /// ```
    /// GOAWAY Frame {
    ///   Type (i) = 0x07,
    ///   Length (i),
    ///   Stream ID/Push ID (i)
    /// }
    /// ```
    case goaway(streamID: UInt64)

    /// MAX_PUSH_ID frame (Section 7.2.7)
    ///
    /// Sent by the client to control the number of server pushes
    /// the server is permitted to initiate. Contains the maximum
    /// push ID the server can use.
    ///
    /// ```
    /// MAX_PUSH_ID Frame {
    ///   Type (i) = 0x0d,
    ///   Length (i),
    ///   Push ID (i)
    /// }
    /// ```
    case maxPushID(pushID: UInt64)

    /// PRIORITY_UPDATE frame for request streams (RFC 9218 Section 7.1)
    ///
    /// Sent on the control stream to dynamically reprioritize a request
    /// stream. Contains the stream ID and a Priority Field Value.
    ///
    /// ```
    /// PRIORITY_UPDATE Frame {
    ///   Type (i) = 0x0f0700,
    ///   Length (i),
    ///   Prioritized Element ID (i),
    ///   Priority Field Value (..)
    /// }
    /// ```
    case priorityUpdateRequest(streamID: UInt64, priority: StreamPriority)

    /// PRIORITY_UPDATE frame for push streams (RFC 9218 Section 7.2)
    ///
    /// Sent on the control stream to dynamically reprioritize a push
    /// stream. Contains the push ID and a Priority Field Value.
    ///
    /// ```
    /// PRIORITY_UPDATE Frame {
    ///   Type (i) = 0x0f0701,
    ///   Length (i),
    ///   Prioritized Element ID (i),
    ///   Priority Field Value (..)
    /// }
    /// ```
    case priorityUpdatePush(pushID: UInt64, priority: StreamPriority)

    /// Unknown or extension frame type
    ///
    /// Per RFC 9114 Section 9, implementations MUST ignore unknown
    /// frame types to allow for future extensions. The raw type
    /// identifier and payload are preserved for logging/debugging.
    case unknown(type: UInt64, payload: Data)

    // MARK: - Properties

    /// The frame type identifier
    public var frameType: UInt64 {
        switch self {
        case .data:
            return HTTP3FrameType.data.rawValue
        case .headers:
            return HTTP3FrameType.headers.rawValue
        case .cancelPush:
            return HTTP3FrameType.cancelPush.rawValue
        case .settings:
            return HTTP3FrameType.settings.rawValue
        case .pushPromise:
            return HTTP3FrameType.pushPromise.rawValue
        case .goaway:
            return HTTP3FrameType.goaway.rawValue
        case .maxPushID:
            return HTTP3FrameType.maxPushID.rawValue
        case .priorityUpdateRequest:
            return PriorityUpdate.requestStreamFrameType
        case .priorityUpdatePush:
            return PriorityUpdate.pushStreamFrameType
        case .unknown(let type, _):
            return type
        }
    }

    /// Whether this frame is allowed on the control stream
    ///
    /// Per RFC 9114 Section 7.2, only SETTINGS, GOAWAY, MAX_PUSH_ID,
    /// and CANCEL_PUSH frames are permitted on the control stream.
    /// DATA and HEADERS frames on the control stream are a connection error.
    public var isAllowedOnControlStream: Bool {
        switch self {
        case .settings, .goaway, .maxPushID, .cancelPush,
             .priorityUpdateRequest, .priorityUpdatePush:
            return true
        case .unknown:
            // Unknown frames on control stream are allowed (forward compatibility)
            return true
        case .data, .headers, .pushPromise:
            return false
        }
    }

    /// Whether this frame is allowed on request streams
    ///
    /// Per RFC 9114 Section 7.2, DATA, HEADERS, and PUSH_PROMISE frames
    /// are permitted on request streams. SETTINGS, GOAWAY, MAX_PUSH_ID,
    /// and CANCEL_PUSH on request streams are a connection error.
    public var isAllowedOnRequestStream: Bool {
        switch self {
        case .data, .headers, .pushPromise:
            return true
        case .unknown:
            // Unknown frames on request streams are allowed (forward compatibility)
            return true
        case .settings, .goaway, .maxPushID, .cancelPush,
             .priorityUpdateRequest, .priorityUpdatePush:
            return false
        }
    }

    /// Whether this frame carries data payload
    public var hasPayload: Bool {
        switch self {
        case .data(let payload):
            return !payload.isEmpty
        case .headers(let headerBlock):
            return !headerBlock.isEmpty
        case .pushPromise(_, let headerBlock):
            return !headerBlock.isEmpty
        case .unknown(_, let payload):
            return !payload.isEmpty
        case .priorityUpdateRequest, .priorityUpdatePush:
            return true
        default:
            return true
        }
    }
}

// MARK: - CustomStringConvertible

extension HTTP3Frame: CustomStringConvertible {
    public var description: String {
        switch self {
        case .data(let payload):
            return "DATA(\(payload.count) bytes)"
        case .headers(let headerBlock):
            return "HEADERS(\(headerBlock.count) bytes)"
        case .cancelPush(let pushID):
            return "CANCEL_PUSH(pushID=\(pushID))"
        case .settings(let settings):
            return "SETTINGS(\(settings))"
        case .pushPromise(let pushID, let headerBlock):
            return "PUSH_PROMISE(pushID=\(pushID), \(headerBlock.count) bytes)"
        case .goaway(let streamID):
            return "GOAWAY(streamID=\(streamID))"
        case .maxPushID(let pushID):
            return "MAX_PUSH_ID(pushID=\(pushID))"
        case .priorityUpdateRequest(let streamID, let priority):
            return "PRIORITY_UPDATE_REQUEST(streamID=\(streamID), \(priority))"
        case .priorityUpdatePush(let pushID, let priority):
            return "PRIORITY_UPDATE_PUSH(pushID=\(pushID), \(priority))"
        case .unknown(let type, let payload):
            return "UNKNOWN(type=0x\(String(type, radix: 16)), \(payload.count) bytes)"
        }
    }
}

// MARK: - Equatable

extension HTTP3Frame: Equatable {
    public static func == (lhs: HTTP3Frame, rhs: HTTP3Frame) -> Bool {
        switch (lhs, rhs) {
        case (.data(let a), .data(let b)):
            return a == b
        case (.headers(let a), .headers(let b)):
            return a == b
        case (.cancelPush(let a), .cancelPush(let b)):
            return a == b
        case (.settings(let a), .settings(let b)):
            return a == b
        case (.pushPromise(let aPushID, let aBlock), .pushPromise(let bPushID, let bBlock)):
            return aPushID == bPushID && aBlock == bBlock
        case (.goaway(let a), .goaway(let b)):
            return a == b
        case (.maxPushID(let a), .maxPushID(let b)):
            return a == b
        case (.priorityUpdateRequest(let aID, let aPri), .priorityUpdateRequest(let bID, let bPri)):
            return aID == bID && aPri == bPri
        case (.priorityUpdatePush(let aID, let aPri), .priorityUpdatePush(let bID, let bPri)):
            return aID == bID && aPri == bPri
        case (.unknown(let aType, let aPayload), .unknown(let bType, let bPayload)):
            return aType == bType && aPayload == bPayload
        default:
            return false
        }
    }
}

// MARK: - Reserved Frame Types

/// Frame types that are reserved and MUST NOT be used (RFC 9114 Section 7.2.8)
///
/// These frame types were used in HTTP/2 but have no equivalent in HTTP/3.
/// Receipt of a frame of these types on any stream MUST be treated as a
/// connection error of type H3_FRAME_UNEXPECTED.
///
/// | Type | HTTP/2 Name    |
/// |------|----------------|
/// | 0x02 | PRIORITY       |
/// | 0x06 | PING           |
/// | 0x08 | WINDOW_UPDATE  |
/// | 0x09 | CONTINUATION   |
public enum HTTP3ReservedFrameType {
    /// Reserved frame type values from HTTP/2 that MUST cause connection error
    public static let reservedTypes: Set<UInt64> = [
        0x02,  // PRIORITY (HTTP/2)
        0x06,  // PING (HTTP/2)
        0x08,  // WINDOW_UPDATE (HTTP/2)
        0x09,  // CONTINUATION (HTTP/2)
    ]

    /// Checks if a frame type is reserved (HTTP/2 leftover)
    ///
    /// - Parameter type: The frame type to check
    /// - Returns: `true` if the type is reserved and must cause an error
    public static func isReserved(_ type: UInt64) -> Bool {
        return reservedTypes.contains(type)
    }
}

// MARK: - Grease Frame Types

/// GREASE (Generate Random Extensions And Sustain Extensibility) support
///
/// Per RFC 9114 Section 7.2.8, frame types of the format `0x1f * N + 0x21`
/// for non-negative integer N are reserved for exercising the requirement
/// that unknown types be ignored. These MUST NOT be treated as errors.
public enum HTTP3GreaseFrameType {
    /// Checks if a frame type is a GREASE value
    ///
    /// GREASE frame types follow the formula: `0x1f * N + 0x21`
    /// for non-negative integer values of N.
    ///
    /// - Parameter type: The frame type to check
    /// - Returns: `true` if the type matches the GREASE pattern
    public static func isGrease(_ type: UInt64) -> Bool {
        guard type >= 0x21 else { return false }
        return (type - 0x21) % 0x1f == 0
    }
}