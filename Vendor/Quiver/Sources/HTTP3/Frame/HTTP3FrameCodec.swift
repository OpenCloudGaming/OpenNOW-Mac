/// HTTP/3 Frame Codec (RFC 9114 Section 7.1, RFC 9218)
///
/// Encodes and decodes HTTP/3 frames to/from their wire format.
///
/// ## Wire Format
///
/// Every HTTP/3 frame has the same structure:
///
/// ```
/// HTTP/3 Frame {
///   Type (i),         // QUIC variable-length integer
///   Length (i),        // QUIC variable-length integer
///   Frame Payload (..) // Length bytes
/// }
/// ```
///
/// The Type and Length fields use QUIC variable-length integer encoding
/// (RFC 9000 Section 16). The payload format depends on the frame type.
///
/// ## Forward Compatibility
///
/// Unknown frame types are preserved as `.unknown(type:payload:)` rather
/// than rejected. This allows endpoints to receive frames defined by
/// future extensions without error (RFC 9114 Section 4.1).

import Foundation
import QUICCore
import QUICStream

// MARK: - HTTP/3 Frame Codec

/// Encodes and decodes HTTP/3 frames
public enum HTTP3FrameCodec {

    /// Maximum allowed frame payload size (16 MB) to prevent memory exhaustion
    public static let maxFramePayloadSize: UInt64 = 16 * 1024 * 1024

    // MARK: - Encoding

    /// Encodes an HTTP/3 frame into its wire format.
    ///
    /// The output consists of:
    /// 1. Frame type as a QUIC varint
    /// 2. Payload length as a QUIC varint
    /// 3. Frame payload bytes
    ///
    /// - Parameter frame: The frame to encode
    /// - Returns: The encoded frame bytes
    ///
    /// ## Example
    ///
    /// ```swift
    /// let frame = HTTP3Frame.data(Data("Hello".utf8))
    /// let encoded = HTTP3FrameCodec.encode(frame)
    /// // Type=0x00 (1 byte) + Length=5 (1 byte) + "Hello" (5 bytes) = 7 bytes
    /// ```
    public static func encode(_ frame: HTTP3Frame) -> Data {
        let (typeValue, payload) = encodePayload(frame)

        var result = Data()
        // Reserve: type varint (1-8) + length varint (1-8) + payload
        result.reserveCapacity(2 + payload.count)

        // Encode frame type
        Varint(typeValue).encode(to: &result)

        // Encode payload length
        Varint(UInt64(payload.count)).encode(to: &result)

        // Append payload
        result.append(payload)

        return result
    }

    /// Encodes an HTTP/3 frame and appends it to an existing buffer.
    ///
    /// - Parameters:
    ///   - frame: The frame to encode
    ///   - buffer: The buffer to append to
    public static func encode(_ frame: HTTP3Frame, into buffer: inout Data) {
        let (typeValue, payload) = encodePayload(frame)

        // Encode frame type
        Varint(typeValue).encode(to: &buffer)

        // Encode payload length
        Varint(UInt64(payload.count)).encode(to: &buffer)

        // Append payload
        buffer.append(payload)
    }

    /// Encodes multiple frames into a single buffer.
    ///
    /// - Parameter frames: The frames to encode
    /// - Returns: The concatenated encoded frames
    public static func encode(_ frames: [HTTP3Frame]) -> Data {
        var result = Data()
        for frame in frames {
            encode(frame, into: &result)
        }
        return result
    }

    // MARK: - Decoding

    /// Decodes a single HTTP/3 frame from the given data.
    ///
    /// - Parameter data: The data to decode from
    /// - Returns: A tuple of (decoded frame, number of bytes consumed)
    /// - Throws: `HTTP3FrameCodecError` if decoding fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let data: Data = ... // received from QUIC stream
    /// let (frame, consumed) = try HTTP3FrameCodec.decode(from: data)
    /// // Process frame, advance buffer by `consumed` bytes
    /// ```
    public static func decode(from data: Data) throws -> (HTTP3Frame, Int) {
        var offset = 0
        let frame = try decode(from: data, offset: &offset)
        return (frame, offset)
    }

    /// Decodes a single HTTP/3 frame from the given data at the specified offset.
    ///
    /// - Parameters:
    ///   - data: The data to decode from
    ///   - offset: The current read position (updated on success)
    /// - Returns: The decoded frame
    /// - Throws: `HTTP3FrameCodecError` if decoding fails
    public static func decode(from data: Data, offset: inout Int) throws -> HTTP3Frame {
        let startOffset = offset

        // Decode frame type (QUIC varint)
        let frameType = try decodeVarint(from: data, offset: &offset)

        // Decode payload length (QUIC varint)
        let payloadLength = try decodeVarint(from: data, offset: &offset)

        // Validate payload length
        guard payloadLength <= maxFramePayloadSize else {
            throw HTTP3FrameCodecError.frameTooLarge(payloadLength)
        }

        let intPayloadLength = Int(payloadLength)

        // Ensure we have enough data for the payload
        guard offset + intPayloadLength <= data.count else {
            // Reset offset to allow caller to retry with more data
            offset = startOffset
            throw HTTP3FrameCodecError.insufficientData
        }

        // Extract payload
        let payload: Data
        if intPayloadLength > 0 {
            payload = data[(data.startIndex + offset)..<(data.startIndex + offset + intPayloadLength)]
            offset += intPayloadLength
        } else {
            payload = Data()
        }

        // Parse frame based on type
        return try decodeFramePayload(type: frameType, payload: payload)
    }

    /// Decodes all frames from the given data.
    ///
    /// Stops when there is not enough data for the next complete frame.
    ///
    /// - Parameter data: The data to decode from
    /// - Returns: A tuple of (decoded frames, total bytes consumed)
    /// - Throws: `HTTP3FrameCodecError` for malformed frames (not for insufficient data at boundary)
    public static func decodeAll(from data: Data) throws -> ([HTTP3Frame], Int) {
        var frames: [HTTP3Frame] = []
        var offset = 0

        while offset < data.count {
            let savedOffset = offset
            do {
                let frame = try decode(from: data, offset: &offset)
                frames.append(frame)
            } catch HTTP3FrameCodecError.insufficientData {
                // Not enough data for a complete frame — stop here
                offset = savedOffset
                break
            }
        }

        return (frames, offset)
    }

    /// Returns the minimum number of bytes needed to determine if a complete frame
    /// is available in the buffer, or nil if even the header is incomplete.
    ///
    /// This is useful for framing on a stream to know when to wait for more data.
    ///
    /// - Parameter data: The buffered data
    /// - Returns: Total frame size (header + payload) if determinable, nil otherwise
    public static func peekFrameSize(from data: Data) -> Int? {
        var offset = 0

        // Try to read frame type varint
        guard let _ = try? decodeVarint(from: data, offset: &offset) else {
            return nil
        }

        // Try to read payload length varint
        let lengthOffset = offset
        guard let payloadLength = try? decodeVarint(from: data, offset: &offset) else {
            return nil
        }

        // Total = type varint bytes + length varint bytes + payload
        _ = lengthOffset  // suppress warning
        return offset + Int(payloadLength)
    }

    // MARK: - Private Helpers

    /// Encodes the frame payload and returns the type value and payload bytes.
    private static func encodePayload(_ frame: HTTP3Frame) -> (type: UInt64, payload: Data) {
        switch frame {
        case .data(let data):
            return (HTTP3FrameType.data.rawValue, data)

        case .headers(let headerBlock):
            return (HTTP3FrameType.headers.rawValue, headerBlock)

        case .cancelPush(let pushID):
            var payload = Data()
            Varint(pushID).encode(to: &payload)
            return (HTTP3FrameType.cancelPush.rawValue, payload)

        case .settings(let settings):
            let payload = encodeSettings(settings)
            return (HTTP3FrameType.settings.rawValue, payload)

        case .pushPromise(let pushID, let headerBlock):
            var payload = Data()
            Varint(pushID).encode(to: &payload)
            payload.append(headerBlock)
            return (HTTP3FrameType.pushPromise.rawValue, payload)

        case .goaway(let streamID):
            var payload = Data()
            Varint(streamID).encode(to: &payload)
            return (HTTP3FrameType.goaway.rawValue, payload)

        case .maxPushID(let pushID):
            var payload = Data()
            Varint(pushID).encode(to: &payload)
            return (HTTP3FrameType.maxPushID.rawValue, payload)

        case .priorityUpdateRequest(let streamID, let priority):
            let update = PriorityUpdate(elementID: streamID, priority: priority, isRequestStream: true)
            return (PriorityUpdate.requestStreamFrameType, update.encodePayload())

        case .priorityUpdatePush(let pushID, let priority):
            let update = PriorityUpdate(elementID: pushID, priority: priority, isRequestStream: false)
            return (PriorityUpdate.pushStreamFrameType, update.encodePayload())

        case .unknown(let type, let payload):
            return (type, payload)
        }
    }

    /// Encodes HTTP/3 settings as a series of (identifier, value) varint pairs.
    ///
    /// Only non-default settings are encoded to minimize wire size.
    /// Unknown settings from the peer (stored in `additionalSettings`) are
    /// also re-encoded for round-trip fidelity.
    private static func encodeSettings(_ settings: HTTP3Settings) -> Data {
        var payload = Data()

        // SETTINGS_MAX_TABLE_CAPACITY (0x01) — default is 0
        if settings.maxTableCapacity != 0 {
            Varint(HTTP3SettingsIdentifier.maxTableCapacity.rawValue).encode(to: &payload)
            Varint(settings.maxTableCapacity).encode(to: &payload)
        }

        // SETTINGS_MAX_FIELD_SECTION_SIZE (0x06) — default is unlimited
        if settings.maxFieldSectionSize != UInt64.max {
            Varint(HTTP3SettingsIdentifier.maxFieldSectionSize.rawValue).encode(to: &payload)
            Varint(settings.maxFieldSectionSize).encode(to: &payload)
        }

        // SETTINGS_QPACK_BLOCKED_STREAMS (0x07) — default is 0
        if settings.qpackBlockedStreams != 0 {
            Varint(HTTP3SettingsIdentifier.qpackBlockedStreams.rawValue).encode(to: &payload)
            Varint(settings.qpackBlockedStreams).encode(to: &payload)
        }

        // SETTINGS_ENABLE_CONNECT_PROTOCOL (0x08) — RFC 9220
        if settings.enableConnectProtocol {
            Varint(HTTP3SettingsIdentifier.enableConnectProtocol.rawValue).encode(to: &payload)
            Varint(1).encode(to: &payload)
        }

        // SETTINGS_H3_DATAGRAM (0x33) — RFC 9297
        if settings.enableH3Datagram {
            Varint(HTTP3SettingsIdentifier.h3Datagram.rawValue).encode(to: &payload)
            Varint(1).encode(to: &payload)
        }

        // SETTINGS_WEBTRANSPORT_MAX_SESSIONS (0xc671706a) — draft-ietf-webtrans-http3-07+
        // This is the NEW identifier that Deno/web-transport-rs and modern clients check first.
        if let maxSessions = settings.webtransportMaxSessions {
            Varint(HTTP3SettingsIdentifier.webtransportMaxSessions.rawValue).encode(to: &payload)
            Varint(maxSessions).encode(to: &payload)

            // Deprecated identifiers for compatibility with Chrome and older clients:
            //
            // WEBTRANSPORT_ENABLE_DEPRECATED (0x2b603742) — boolean flag, must be exactly 1.
            // Older clients (Chrome 114, Deno with web-transport-rs) check this as a boolean
            // enable flag and reject any value != 1.
            Varint(HTTP3SettingsIdentifier.webtransportEnableDeprecated.rawValue).encode(to: &payload)
            Varint(1).encode(to: &payload)

            // WEBTRANSPORT_MAX_SESSIONS_DEPRECATED (0x2b603743) — the old max sessions value.
            // Older clients read this after checking the enable flag above.
            Varint(HTTP3SettingsIdentifier.webtransportMaxSessionsDeprecated.rawValue).encode(to: &payload)
            Varint(maxSessions).encode(to: &payload)
        }

        // SETTINGS_ENABLE_DATAGRAM_DEPRECATED (0xFFD277) — still used by Chrome
        // Send alongside SETTINGS_H3_DATAGRAM (0x33) for maximum compatibility.
        if settings.enableH3Datagram {
            Varint(HTTP3SettingsIdentifier.h3DatagramDeprecated.rawValue).encode(to: &payload)
            Varint(1).encode(to: &payload)
        }

        // Encode any additional (unknown) settings for forward compatibility
        for (identifier, value) in settings.additionalSettings {
            Varint(identifier).encode(to: &payload)
            Varint(value).encode(to: &payload)
        }

        return payload
    }

    /// Decodes a frame from its type and payload.
    private static func decodeFramePayload(type: UInt64, payload: Data) throws -> HTTP3Frame {
        // Check for PRIORITY_UPDATE frames first (RFC 9218)
        if let classification = PriorityUpdate.classify(type) {
            let update = try PriorityUpdate.decode(from: payload, isRequestStream: classification.isRequestStream)
            if classification.isRequestStream {
                return .priorityUpdateRequest(streamID: update.elementID, priority: update.priority)
            } else {
                return .priorityUpdatePush(pushID: update.elementID, priority: update.priority)
            }
        }

        guard let frameType = HTTP3FrameType(rawValue: type) else {
            // Unknown frame type — preserve for forward compatibility
            return .unknown(type: type, payload: payload)
        }

        switch frameType {
        case .data:
            return .data(payload)

        case .headers:
            return .headers(payload)

        case .cancelPush:
            let pushID = try decodeSingleVarint(from: payload, label: "CANCEL_PUSH push ID")
            return .cancelPush(pushID: pushID)

        case .settings:
            let settings = try decodeSettings(from: payload)
            return .settings(settings)

        case .pushPromise:
            var offset = 0
            let pushID = try decodeVarint(from: payload, offset: &offset)
            let headerBlock = payload.suffix(from: payload.startIndex + offset)
            return .pushPromise(pushID: pushID, headerBlock: Data(headerBlock))

        case .goaway:
            let streamID = try decodeSingleVarint(from: payload, label: "GOAWAY stream ID")
            return .goaway(streamID: streamID)

        case .maxPushID:
            let pushID = try decodeSingleVarint(from: payload, label: "MAX_PUSH_ID push ID")
            return .maxPushID(pushID: pushID)
        }
    }

    /// Decodes HTTP/3 settings from a SETTINGS frame payload.
    ///
    /// The payload is a sequence of (identifier, value) varint pairs.
    /// Unknown identifiers are preserved in `additionalSettings`.
    ///
    /// Per RFC 9114 Section 7.2.4:
    /// - Each identifier MUST NOT appear more than once
    /// - Certain identifiers (from HTTP/2) are forbidden
    private static func decodeSettings(from payload: Data) throws -> HTTP3Settings {
        var settings = HTTP3Settings()
        var offset = 0
        var seenIdentifiers = Set<UInt64>()

        while offset < payload.count {
            let identifier = try decodeVarint(from: payload, offset: &offset)
            let value = try decodeVarint(from: payload, offset: &offset)

            // Check for duplicate identifiers (RFC 9114 Section 7.2.4)
            guard !seenIdentifiers.contains(identifier) else {
                throw HTTP3FrameCodecError.duplicateSettingIdentifier(identifier)
            }
            seenIdentifiers.insert(identifier)

            // Reject HTTP/2-only settings that MUST NOT appear in HTTP/3
            // (RFC 9114 Section 7.2.4.1)
            if isHTTP2OnlySetting(identifier) {
                throw HTTP3FrameCodecError.http2SettingReceived(identifier)
            }

            if let knownID = HTTP3SettingsIdentifier(rawValue: identifier) {
                switch knownID {
                case .maxTableCapacity:
                    settings.maxTableCapacity = value
                case .maxFieldSectionSize:
                    settings.maxFieldSectionSize = value
                case .qpackBlockedStreams:
                    settings.qpackBlockedStreams = value
                case .enableConnectProtocol:
                    settings.enableConnectProtocol = (value != 0)
                case .h3Datagram:
                    settings.enableH3Datagram = (value != 0)
                case .h3DatagramDeprecated:
                    // Accept deprecated datagram setting from older peers (Chrome)
                    // Only set if the new identifier hasn't already set it
                    if !settings.enableH3Datagram {
                        settings.enableH3Datagram = (value != 0)
                    }
                case .webtransportMaxSessions:
                    settings.webtransportMaxSessions = value
                case .webtransportEnableDeprecated:
                    // Deprecated boolean enable flag (0x2b603742).
                    // If the new WEBTRANSPORT_MAX_SESSIONS (0xc671706a) was not seen,
                    // treat this as advertising 1 session when value == 1.
                    if settings.webtransportMaxSessions == nil && value != 0 {
                        settings.webtransportMaxSessions = 1
                    }
                case .webtransportMaxSessionsDeprecated:
                    // Deprecated max sessions (0x2b603743).
                    // Override the "1" we may have set from the enable flag above,
                    // but only if the new identifier hasn't been seen.
                    if settings.webtransportMaxSessions == 1 || settings.webtransportMaxSessions == nil {
                        settings.webtransportMaxSessions = value
                    }
                }
            } else {
                // Unknown setting — MUST be ignored per RFC 9114 Section 7.2.4
                // We store them for potential re-encoding / debugging
                settings.additionalSettings.append((identifier, value))
            }
        }

        return settings
    }

    /// Checks whether a setting identifier is an HTTP/2-only setting
    /// that MUST NOT appear in HTTP/3 (RFC 9114 Section 7.2.4.1).
    ///
    /// HTTP/2 setting identifiers that are forbidden in HTTP/3
    /// (RFC 9114 Section 11.2.2):
    /// - 0x02: SETTINGS_ENABLE_PUSH
    /// - 0x03: SETTINGS_MAX_CONCURRENT_STREAMS
    /// - 0x04: SETTINGS_INITIAL_WINDOW_SIZE
    /// - 0x05: SETTINGS_MAX_FRAME_SIZE
    ///
    /// Note: 0x08 is NOT reserved. It was SETTINGS_MAX_HEADER_LIST_SIZE in
    /// HTTP/2 but is reassigned to SETTINGS_ENABLE_CONNECT_PROTOCOL (RFC 9220)
    /// in HTTP/3.
    private static func isHTTP2OnlySetting(_ identifier: UInt64) -> Bool {
        switch identifier {
        case 0x02, 0x03, 0x04, 0x05:
            return true
        default:
            return false
        }
    }

    /// Decodes a QUIC varint from data at the given offset.
    ///
    /// Uses the existing `QUICCore.Varint` decoder under the hood.
    private static func decodeVarint(from data: Data, offset: inout Int) throws -> UInt64 {
        guard offset < data.count else {
            throw HTTP3FrameCodecError.insufficientData
        }

        let slice = data[(data.startIndex + offset)...]

        // We need at least 1 byte to determine the varint length
        guard let firstByte = slice.first else {
            throw HTTP3FrameCodecError.insufficientData
        }

        let prefix = firstByte >> 6
        let varintLength: Int
        switch prefix {
        case 0b00: varintLength = 1
        case 0b01: varintLength = 2
        case 0b10: varintLength = 4
        case 0b11: varintLength = 8
        default: fatalError("Unreachable: 2-bit prefix")
        }

        guard slice.count >= varintLength else {
            throw HTTP3FrameCodecError.insufficientData
        }

        let varintData = Data(slice.prefix(varintLength))
        let (varint, consumed) = try Varint.decode(from: varintData)
        offset += consumed
        return varint.value
    }

    /// Decodes a single varint that should be the entire payload.
    private static func decodeSingleVarint(from payload: Data, label: String) throws -> UInt64 {
        guard !payload.isEmpty else {
            throw HTTP3FrameCodecError.invalidPayload("Empty payload for \(label)")
        }
        var offset = 0
        let value = try decodeVarint(from: payload, offset: &offset)

        // The entire payload should be consumed
        if offset != payload.count {
            throw HTTP3FrameCodecError.invalidPayload(
                "Unexpected trailing data in \(label) frame: \(payload.count - offset) extra bytes"
            )
        }
        return value
    }

    // MARK: - Size Calculation

    /// Returns the total encoded size of a frame without actually encoding it.
    ///
    /// Useful for buffer pre-allocation.
    ///
    /// - Parameter frame: The frame to measure
    /// - Returns: Total encoded size in bytes
    public static func encodedSize(of frame: HTTP3Frame) -> Int {
        let (typeValue, payload) = encodePayload(frame)
        let typeSize = Varint.encodedLength(for: typeValue)
        let lengthSize = Varint.encodedLength(for: UInt64(payload.count))
        return typeSize + lengthSize + payload.count
    }
}

// MARK: - Settings Identifiers

/// Known HTTP/3 settings identifiers (RFC 9114 Section 7.2.4.1)
public enum HTTP3SettingsIdentifier: UInt64, Sendable {
    /// Maximum size of the QPACK dynamic table (RFC 9204)
    ///
    /// Default: 0 (no dynamic table)
    case maxTableCapacity = 0x01

    /// Maximum size of a field section (header block) that the peer will accept
    ///
    /// Default: unlimited
    case maxFieldSectionSize = 0x06

    /// Maximum number of streams that can be blocked waiting for QPACK
    ///
    /// Default: 0 (no blocking)
    case qpackBlockedStreams = 0x07

    /// Enable Extended CONNECT protocol (RFC 9220 §3)
    ///
    /// When sent with value 1, indicates support for Extended CONNECT
    /// with the `:protocol` pseudo-header. Required for WebTransport.
    ///
    /// Note: 0x08 was `SETTINGS_MAX_HEADER_LIST_SIZE` in HTTP/2 but is
    /// NOT reserved in HTTP/3. It was reassigned to this setting by RFC 9220.
    ///
    /// Default: 0 (disabled)
    case enableConnectProtocol = 0x08

    /// HTTP/3 Datagram support (RFC 9297 §2.1)
    ///
    /// When sent with value 1, indicates support for HTTP Datagrams.
    /// Works in conjunction with the QUIC-level `max_datagram_frame_size`
    /// transport parameter (RFC 9221).
    ///
    /// Default: 0 (disabled)
    case h3Datagram = 0x33

    /// HTTP/3 Datagram support — DEPRECATED identifier (0xFFD277)
    ///
    /// Still sent by Chrome (as of Chrome 114+). Accepted for compatibility.
    /// Superseded by `h3Datagram` (0x33).
    case h3DatagramDeprecated = 0xFFD277

    /// Maximum concurrent WebTransport sessions (draft-ietf-webtrans-http3-07+)
    ///
    /// This is the NEW identifier (0xc671706a) from draft-07 onwards.
    /// When present, advertises WebTransport support and the maximum
    /// number of concurrent sessions. Deno (web-transport-rs), modern
    /// browsers, and other up-to-date clients check this identifier first.
    ///
    /// Default: not sent (WebTransport not advertised)
    case webtransportMaxSessions = 0xc671706a

    /// WebTransport enable — DEPRECATED (0x2b603742)
    ///
    /// Before draft-07, this was used as a boolean flag (value=1) to
    /// indicate WebTransport support. Older clients (Chrome 114, Deno)
    /// check this and require the value to be exactly 1.
    ///
    /// **Important**: This is NOT the max sessions count — it is a boolean.
    /// Sending a value other than 1 will cause older clients to reject
    /// WebTransport as unsupported.
    case webtransportEnableDeprecated = 0x2b603742

    /// WebTransport max sessions — DEPRECATED (0x2b603743)
    ///
    /// Before draft-07, this carried the actual max sessions count.
    /// Used in conjunction with `webtransportEnableDeprecated`.
    case webtransportMaxSessionsDeprecated = 0x2b603743
}

// MARK: - Errors

/// Errors that can occur during HTTP/3 frame encoding/decoding
public enum HTTP3FrameCodecError: Error, Sendable, CustomStringConvertible {
    /// Not enough data to decode a complete frame
    case insufficientData

    /// Frame payload exceeds the maximum allowed size
    case frameTooLarge(UInt64)

    /// Invalid frame payload content
    case invalidPayload(String)

    /// A setting identifier appeared more than once in a SETTINGS frame
    case duplicateSettingIdentifier(UInt64)

    /// An HTTP/2-only setting was received (RFC 9114 Section 7.2.4.1)
    case http2SettingReceived(UInt64)

    /// Invalid varint encoding in the frame
    case invalidVarint

    public var description: String {
        switch self {
        case .insufficientData:
            return "Insufficient data for HTTP/3 frame decoding"
        case .frameTooLarge(let size):
            return "HTTP/3 frame payload too large: \(size) bytes (max: \(HTTP3FrameCodec.maxFramePayloadSize))"
        case .invalidPayload(let reason):
            return "Invalid HTTP/3 frame payload: \(reason)"
        case .duplicateSettingIdentifier(let id):
            return "Duplicate HTTP/3 setting identifier: 0x\(String(id, radix: 16))"
        case .http2SettingReceived(let id):
            return "HTTP/2-only setting 0x\(String(id, radix: 16)) received in HTTP/3 SETTINGS"
        case .invalidVarint:
            return "Invalid varint encoding in HTTP/3 frame"
        }
    }
}