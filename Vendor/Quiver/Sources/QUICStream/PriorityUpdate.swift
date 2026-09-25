/// Priority Update Frame
///
/// PRIORITY_UPDATE frame for dynamic stream reprioritization (RFC 9218 Section 7).

import Foundation

// MARK: - PRIORITY_UPDATE Frame (RFC 9218 Section 7)

/// PRIORITY_UPDATE frame for dynamic stream reprioritization.
///
/// HTTP/3 uses two PRIORITY_UPDATE frame types:
/// - Type 0x0f0700: For request streams (client-initiated bidirectional)
/// - Type 0x0f0701: For push streams
///
/// ## Wire Format
///
/// ```
/// PRIORITY_UPDATE Frame {
///   Type (i) = 0x0f0700 or 0x0f0701,
///   Length (i),
///   Prioritized Element ID (i),    // Stream ID or Push ID
///   Priority Field Value (..),     // ASCII, Structured Fields Dictionary
/// }
/// ```
///
/// ## Usage
///
/// ```swift
/// // Create a priority update for request stream 4
/// let update = PriorityUpdate(
///     elementID: 4,
///     priority: StreamPriority(urgency: 1, incremental: true),
///     isRequestStream: true
/// )
///
/// // Encode to bytes
/// let encoded = update.encode()
///
/// // Decode from bytes
/// let decoded = try PriorityUpdate.decode(from: data, isRequestStream: true)
/// ```
public struct PriorityUpdate: Sendable, Hashable {
    /// Frame type for request stream PRIORITY_UPDATE (RFC 9218 Section 7.1)
    public static let requestStreamFrameType: UInt64 = 0x0f0700

    /// Frame type for push stream PRIORITY_UPDATE (RFC 9218 Section 7.2)
    public static let pushStreamFrameType: UInt64 = 0x0f0701

    /// The stream ID or push ID being reprioritized.
    public let elementID: UInt64

    /// The new priority for the element.
    public let priority: StreamPriority

    /// Whether this update targets a request stream (true) or push stream (false).
    public let isRequestStream: Bool

    /// Creates a PRIORITY_UPDATE.
    ///
    /// - Parameters:
    ///   - elementID: The stream or push ID to reprioritize
    ///   - priority: The new priority
    ///   - isRequestStream: Whether this targets a request stream (default: true)
    public init(elementID: UInt64, priority: StreamPriority, isRequestStream: Bool = true) {
        self.elementID = elementID
        self.priority = priority
        self.isRequestStream = isRequestStream
    }

    /// The HTTP/3 frame type for this update.
    public var frameType: UInt64 {
        isRequestStream ? Self.requestStreamFrameType : Self.pushStreamFrameType
    }

    /// Encodes the PRIORITY_UPDATE payload (without frame type/length).
    ///
    /// The payload consists of:
    /// 1. Prioritized Element ID (varint)
    /// 2. Priority Field Value (ASCII bytes)
    ///
    /// - Returns: The encoded payload data
    public func encodePayload() -> Data {
        var data = Data()

        // Encode element ID as varint
        data.append(contentsOf: Self.varintEncode(elementID))

        // Encode Priority Field Value as ASCII
        let fieldValue = PriorityHeaderParser.serialize(priority)
        data.append(contentsOf: fieldValue.utf8)

        return data
    }

    /// Decodes a PRIORITY_UPDATE from its payload data.
    ///
    /// - Parameters:
    ///   - data: The payload data (after frame type and length)
    ///   - isRequestStream: Whether this is a request stream update
    /// - Returns: The decoded PriorityUpdate
    /// - Throws: If the payload is malformed
    public static func decode(from data: Data, isRequestStream: Bool) throws -> PriorityUpdate {
        guard !data.isEmpty else {
            throw PriorityUpdateError.emptyPayload
        }

        // Decode element ID varint
        let (elementID, consumed) = try varintDecode(from: data)

        // Remaining bytes are the Priority Field Value
        let remaining = data.suffix(from: data.startIndex + consumed)
        let fieldValue = String(data: Data(remaining), encoding: .utf8)

        let priority = PriorityHeaderParser.parse(fieldValue)

        return PriorityUpdate(
            elementID: elementID,
            priority: priority,
            isRequestStream: isRequestStream
        )
    }

    /// Checks if a frame type is a PRIORITY_UPDATE frame.
    ///
    /// - Parameter frameType: The frame type to check
    /// - Returns: A `PriorityUpdateClassification` if this is a PRIORITY_UPDATE, or nil otherwise
    public static func classify(_ frameType: UInt64) -> PriorityUpdateClassification? {
        switch frameType {
        case requestStreamFrameType:
            return PriorityUpdateClassification(isRequestStream: true)
        case pushStreamFrameType:
            return PriorityUpdateClassification(isRequestStream: false)
        default:
            return nil
        }
    }

    // MARK: - Varint Helpers (minimal, self-contained)

    /// Encodes a UInt64 as a QUIC variable-length integer.
    private static func varintEncode(_ value: UInt64) -> [UInt8] {
        if value <= 63 {
            return [UInt8(value)]
        } else if value <= 16383 {
            return [
                UInt8(0x40 | (value >> 8)),
                UInt8(value & 0xFF)
            ]
        } else if value <= 1_073_741_823 {
            return [
                UInt8(0x80 | (value >> 24)),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
        } else {
            return [
                UInt8(0xC0 | (value >> 56)),
                UInt8((value >> 48) & 0xFF),
                UInt8((value >> 40) & 0xFF),
                UInt8((value >> 32) & 0xFF),
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF)
            ]
        }
    }

    /// Decodes a QUIC variable-length integer from data.
    private static func varintDecode(from data: Data) throws -> (UInt64, Int) {
        guard let firstByte = data.first else {
            throw PriorityUpdateError.insufficientData
        }

        let prefix = firstByte >> 6
        let length: Int

        switch prefix {
        case 0: length = 1
        case 1: length = 2
        case 2: length = 4
        case 3: length = 8
        default: length = 1  // unreachable
        }

        guard data.count >= length else {
            throw PriorityUpdateError.insufficientData
        }

        var value = UInt64(firstByte & 0x3F)
        for i in 1..<length {
            value = (value << 8) | UInt64(data[data.startIndex + i])
        }

        return (value, length)
    }
}

/// Result of classifying a frame type as a PRIORITY_UPDATE.
public struct PriorityUpdateClassification: Sendable, Hashable {
    /// Whether this targets a request stream (true) or push stream (false).
    public let isRequestStream: Bool
}

/// Errors from PRIORITY_UPDATE decoding.
public enum PriorityUpdateError: Error, Sendable, CustomStringConvertible {
    /// The payload was empty
    case emptyPayload

    /// Not enough data to decode the varint
    case insufficientData

    public var description: String {
        switch self {
        case .emptyPayload:
            return "PRIORITY_UPDATE payload is empty"
        case .insufficientData:
            return "Insufficient data for PRIORITY_UPDATE varint"
        }
    }
}