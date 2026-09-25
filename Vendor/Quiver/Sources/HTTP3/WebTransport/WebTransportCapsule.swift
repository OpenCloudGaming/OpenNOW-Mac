/// WebTransport Capsule Protocol (RFC 9297 + draft-ietf-webtrans-http3)
///
/// Capsules are framed messages exchanged on the CONNECT stream's data
/// portion after the HTTP response headers. They provide a mechanism for
/// signaling session-level events such as close and drain.
///
/// ## Capsule Wire Format (RFC 9297 Section 3.2)
///
/// ```
/// Capsule {
///   Type (i),        // QUIC variable-length integer
///   Length (i),       // QUIC variable-length integer
///   Value (..)        // Length bytes
/// }
/// ```
///
/// ## WebTransport Capsule Types
///
/// | Type   | Name                          | Reference                    |
/// |--------|-------------------------------|------------------------------|
/// | 0x2843 | CLOSE_WEBTRANSPORT_SESSION    | draft-ietf-webtrans-http3    |
/// | 0x78ae | DRAIN_WEBTRANSPORT_SESSION    | draft-ietf-webtrans-http3    |
///
/// ## CLOSE_WEBTRANSPORT_SESSION Payload
///
/// ```
/// CLOSE_WEBTRANSPORT_SESSION {
///   Application Error Code (32),       // 4 bytes, network byte order
///   Application Error Message (..)     // UTF-8 string (remaining bytes)
/// }
/// ```
///
/// ## DRAIN_WEBTRANSPORT_SESSION Payload
///
/// ```
/// DRAIN_WEBTRANSPORT_SESSION {
///   (empty)
/// }
/// ```
///
/// ## References
///
/// - [RFC 9297: HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297.html)
/// - [draft-ietf-webtrans-http3](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)

import Foundation
import QUICCore

// MARK: - Capsule Type Identifiers

/// WebTransport capsule type identifiers.
///
/// These are the capsule types defined by the WebTransport over HTTP/3 draft.
/// Unknown capsule types on the CONNECT stream MUST be ignored per RFC 9297.
public enum WebTransportCapsuleType: UInt64, Sendable, Hashable {
    /// CLOSE_WEBTRANSPORT_SESSION capsule (draft-ietf-webtrans-http3)
    ///
    /// Signals that the WebTransport session is being closed. Contains
    /// an application error code and an optional reason string.
    ///
    /// Either endpoint can send this capsule. Upon receiving it, the
    /// peer SHOULD close all associated streams and the session.
    case closeSession = 0x2843

    /// DRAIN_WEBTRANSPORT_SESSION capsule (draft-ietf-webtrans-http3)
    ///
    /// Signals that the sender is about to close the session and will
    /// not accept new streams. Existing streams may continue until
    /// completion. The peer should initiate a graceful shutdown.
    ///
    /// Has an empty payload.
    case drainSession = 0x78ae
}

extension WebTransportCapsuleType: CustomStringConvertible {
    public var description: String {
        switch self {
        case .closeSession:
            return "CLOSE_WEBTRANSPORT_SESSION(0x2843)"
        case .drainSession:
            return "DRAIN_WEBTRANSPORT_SESSION(0x78ae)"
        }
    }
}

// MARK: - WebTransport Capsule

/// A decoded WebTransport capsule.
///
/// Represents one of the WebTransport-specific capsules that can be
/// exchanged on the CONNECT stream, plus an `unknown` variant for
/// forward compatibility.
public enum WebTransportCapsule: Sendable, Hashable {
    /// CLOSE_WEBTRANSPORT_SESSION capsule.
    ///
    /// Contains the close information (application error code + reason).
    case close(WebTransportSessionCloseInfo)

    /// DRAIN_WEBTRANSPORT_SESSION capsule.
    ///
    /// Signals imminent session closure. Has no payload.
    case drain

    /// An unknown capsule type (forward compatibility).
    ///
    /// Per RFC 9297, unknown capsule types MUST be ignored.
    /// The raw type and payload are preserved for logging/debugging.
    case unknown(type: UInt64, payload: Data)

    /// The capsule type identifier.
    public var capsuleType: UInt64 {
        switch self {
        case .close:
            return WebTransportCapsuleType.closeSession.rawValue
        case .drain:
            return WebTransportCapsuleType.drainSession.rawValue
        case .unknown(let type, _):
            return type
        }
    }
}

// MARK: - CustomStringConvertible

extension WebTransportCapsule: CustomStringConvertible {
    public var description: String {
        switch self {
        case .close(let info):
            return "CLOSE_WEBTRANSPORT_SESSION(\(info))"
        case .drain:
            return "DRAIN_WEBTRANSPORT_SESSION"
        case .unknown(let type, let payload):
            return "UNKNOWN_CAPSULE(type=0x\(String(type, radix: 16)), \(payload.count) bytes)"
        }
    }
}

// MARK: - Capsule Codec

/// Encoder and decoder for WebTransport capsules on the CONNECT stream.
///
/// Capsules use the generic capsule framing defined by RFC 9297:
/// each capsule is a (Type, Length, Value) tuple where Type and Length
/// are QUIC variable-length integers.
///
/// ## Usage
///
/// ```swift
/// // Encode a close capsule
/// let closeInfo = WebTransportSessionCloseInfo(errorCode: 0, reason: "done")
/// let data = WebTransportCapsuleCodec.encode(.close(closeInfo))
///
/// // Decode capsules from a buffer
/// var buffer = receivedData
/// while let (capsule, consumed) = try WebTransportCapsuleCodec.decode(from: buffer) {
///     buffer = Data(buffer.dropFirst(consumed))
///     switch capsule {
///     case .close(let info):
///         print("Session closed: \(info)")
///     case .drain:
///         print("Session draining")
///     case .unknown:
///         break // Ignore unknown capsules
///     }
/// }
/// ```
public enum WebTransportCapsuleCodec {

    // MARK: - Encoding

    /// Encodes a WebTransport capsule to wire bytes.
    ///
    /// Produces a complete capsule frame: Type (varint) + Length (varint) + Payload.
    ///
    /// - Parameter capsule: The capsule to encode
    /// - Returns: The encoded bytes
    public static func encode(_ capsule: WebTransportCapsule) -> Data {
        var data = Data()
        encode(capsule, into: &data)
        return data
    }

    /// Encodes a WebTransport capsule, appending to the given buffer.
    ///
    /// - Parameters:
    ///   - capsule: The capsule to encode
    ///   - buffer: The buffer to append to
    public static func encode(_ capsule: WebTransportCapsule, into buffer: inout Data) {
        let (type, payload) = encodePayload(capsule)

        // Type (varint)
        Varint(type).encode(to: &buffer)
        // Length (varint)
        Varint(UInt64(payload.count)).encode(to: &buffer)
        // Payload
        buffer.append(payload)
    }

    /// Encodes just the capsule payload (without the Type/Length header).
    ///
    /// - Parameter capsule: The capsule to encode
    /// - Returns: A tuple of (type identifier, payload bytes)
    private static func encodePayload(_ capsule: WebTransportCapsule) -> (type: UInt64, payload: Data) {
        switch capsule {
        case .close(let info):
            return (WebTransportCapsuleType.closeSession.rawValue, encodeClosePayload(info))
        case .drain:
            return (WebTransportCapsuleType.drainSession.rawValue, Data())
        case .unknown(let type, let payload):
            return (type, payload)
        }
    }

    /// Encodes the CLOSE_WEBTRANSPORT_SESSION payload.
    ///
    /// Format: Application Error Code (32 bits, big-endian) + Message (UTF-8).
    ///
    /// - Parameter info: The close information
    /// - Returns: The encoded payload
    private static func encodeClosePayload(_ info: WebTransportSessionCloseInfo) -> Data {
        let reasonBytes = Data(info.reason.utf8)
        var payload = Data(capacity: 4 + reasonBytes.count)

        // Application Error Code — 4 bytes, big-endian (network byte order)
        payload.append(UInt8((info.errorCode >> 24) & 0xFF))
        payload.append(UInt8((info.errorCode >> 16) & 0xFF))
        payload.append(UInt8((info.errorCode >> 8) & 0xFF))
        payload.append(UInt8(info.errorCode & 0xFF))

        // Application Error Message — UTF-8 string
        payload.append(reasonBytes)

        return payload
    }

    // MARK: - Decoding

    /// Attempts to decode a single capsule from the given data.
    ///
    /// Returns `nil` if there is insufficient data for a complete capsule.
    /// This allows incremental parsing: callers can accumulate data in a
    /// buffer and repeatedly call `decode` until it succeeds.
    ///
    /// - Parameter data: The data to decode from
    /// - Returns: A tuple of (decoded capsule, total bytes consumed), or `nil`
    ///   if insufficient data is available for a complete capsule
    /// - Throws: `WebTransportCapsuleError` if the capsule data is malformed
    public static func decode(from data: Data) throws -> (WebTransportCapsule, Int)? {
        var offset = 0

        // Try to read Type (varint)
        guard let (typeVarint, typeLen) = try? decodeVarint(from: data, offset: offset) else {
            return nil // Insufficient data for type
        }
        offset += typeLen

        // Try to read Length (varint)
        guard offset < data.count else { return nil }
        let remaining = Data(data.dropFirst(offset))
        guard let (lengthVarint, lengthLen) = try? decodeVarint(from: remaining, offset: 0) else {
            return nil // Insufficient data for length
        }
        offset += lengthLen

        let payloadLength = Int(lengthVarint)

        // Check we have enough bytes for the full payload
        guard data.count >= offset + payloadLength else {
            return nil // Insufficient data for payload
        }

        let payload = Data(data[data.startIndex.advanced(by: offset)..<data.startIndex.advanced(by: offset + payloadLength)])
        let totalConsumed = offset + payloadLength

        // Decode based on capsule type
        let capsule = try decodeCapsulePayload(type: typeVarint, payload: payload)
        return (capsule, totalConsumed)
    }

    /// Decodes all complete capsules from a buffer.
    ///
    /// Consumes as many complete capsules as possible and returns them
    /// along with the total number of bytes consumed. Any remaining
    /// partial capsule data stays in the buffer.
    ///
    /// - Parameter data: The data to decode from
    /// - Returns: A tuple of (decoded capsules, total bytes consumed)
    /// - Throws: `WebTransportCapsuleError` if any capsule data is malformed
    public static func decodeAll(from data: Data) throws -> ([WebTransportCapsule], Int) {
        var capsules: [WebTransportCapsule] = []
        var totalConsumed = 0
        var remaining = data

        while !remaining.isEmpty {
            guard let (capsule, consumed) = try decode(from: remaining) else {
                break // Incomplete capsule at end
            }
            capsules.append(capsule)
            totalConsumed += consumed
            remaining = Data(remaining.dropFirst(consumed))
        }

        return (capsules, totalConsumed)
    }

    /// Decodes a capsule payload based on its type.
    ///
    /// - Parameters:
    ///   - type: The capsule type identifier
    ///   - payload: The capsule payload bytes
    /// - Returns: The decoded capsule
    /// - Throws: `WebTransportCapsuleError` for malformed payloads
    private static func decodeCapsulePayload(
        type: UInt64,
        payload: Data
    ) throws -> WebTransportCapsule {
        guard let knownType = WebTransportCapsuleType(rawValue: type) else {
            // Unknown capsule type — preserve for forward compatibility
            return .unknown(type: type, payload: payload)
        }

        switch knownType {
        case .closeSession:
            return try .close(decodeClosePayload(payload))
        case .drainSession:
            // DRAIN has an empty payload
            return .drain
        }
    }

    /// Decodes a CLOSE_WEBTRANSPORT_SESSION payload.
    ///
    /// - Parameter payload: The capsule payload
    /// - Returns: The decoded close information
    /// - Throws: `WebTransportCapsuleError` if the payload is too short
    private static func decodeClosePayload(_ payload: Data) throws -> WebTransportSessionCloseInfo {
        guard payload.count >= 4 else {
            throw WebTransportCapsuleError.payloadTooShort(
                expected: 4,
                actual: payload.count,
                capsuleType: "CLOSE_WEBTRANSPORT_SESSION"
            )
        }

        // Application Error Code — 4 bytes, big-endian
        let errorCode: UInt32 = payload.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return UInt32(ptr[0]) << 24
                | UInt32(ptr[1]) << 16
                | UInt32(ptr[2]) << 8
                | UInt32(ptr[3])
        }

        // Application Error Message — remaining bytes as UTF-8
        let reason: String
        if payload.count > 4 {
            let messageData = Data(payload.dropFirst(4))
            reason = String(data: messageData, encoding: .utf8) ?? ""
        } else {
            reason = ""
        }

        return WebTransportSessionCloseInfo(errorCode: errorCode, reason: reason)
    }

    // MARK: - Varint Helpers

    /// Decodes a QUIC variable-length integer from data at the given offset.
    ///
    /// - Parameters:
    ///   - data: The source data
    ///   - offset: The byte offset to start decoding from
    /// - Returns: A tuple of (decoded value, bytes consumed)
    /// - Throws: `Varint.DecodeError` if insufficient data
    private static func decodeVarint(from data: Data, offset: Int) throws -> (UInt64, Int) {
        guard offset < data.count else {
            throw Varint.DecodeError.insufficientData
        }
        let slice = Data(data.dropFirst(offset))
        let (varint, consumed) = try Varint.decode(from: slice)
        return (varint.value, consumed)
    }

    // MARK: - Size Calculation

    /// Returns the encoded size of a capsule in bytes.
    ///
    /// Useful for buffer pre-allocation.
    ///
    /// - Parameter capsule: The capsule to measure
    /// - Returns: The total encoded size including Type, Length, and Payload
    public static func encodedSize(of capsule: WebTransportCapsule) -> Int {
        let (type, payload) = encodePayload(capsule)
        let typeLen = Varint.encodedLength(for: type)
        let payloadLen = payload.count
        let lengthLen = Varint.encodedLength(for: UInt64(payloadLen))
        return typeLen + lengthLen + payloadLen
    }
}

// MARK: - Capsule Errors

/// Errors that occur during capsule encoding or decoding.
public enum WebTransportCapsuleError: Error, Sendable, CustomStringConvertible {
    /// The capsule payload is shorter than the minimum required length.
    ///
    /// - Parameters:
    ///   - expected: Minimum expected bytes
    ///   - actual: Actual bytes available
    ///   - capsuleType: The capsule type being decoded
    case payloadTooShort(expected: Int, actual: Int, capsuleType: String)

    /// The varint encoding within the capsule is malformed.
    case malformedVarint(String)

    /// The capsule data is truncated (incomplete on the wire).
    case truncatedCapsule(String)

    public var description: String {
        switch self {
        case .payloadTooShort(let expected, let actual, let capsuleType):
            return "\(capsuleType) payload too short: expected at least \(expected) bytes, got \(actual)"
        case .malformedVarint(let context):
            return "Malformed varint in capsule: \(context)"
        case .truncatedCapsule(let context):
            return "Truncated capsule data: \(context)"
        }
    }
}

// MARK: - Convenience Constructors

extension WebTransportCapsuleCodec {

    /// Encodes a CLOSE_WEBTRANSPORT_SESSION capsule with the given parameters.
    ///
    /// Convenience method that creates and encodes a close capsule in one step.
    ///
    /// - Parameters:
    ///   - errorCode: Application error code (default: 0)
    ///   - reason: Human-readable reason (default: empty)
    /// - Returns: The encoded capsule bytes
    public static func encodeClose(errorCode: UInt32 = 0, reason: String = "") -> Data {
        let info = WebTransportSessionCloseInfo(errorCode: errorCode, reason: reason)
        return encode(.close(info))
    }

    /// Encodes a DRAIN_WEBTRANSPORT_SESSION capsule.
    ///
    /// Convenience method for encoding the drain capsule.
    ///
    /// - Returns: The encoded capsule bytes
    public static func encodeDrain() -> Data {
        return encode(.drain)
    }
}