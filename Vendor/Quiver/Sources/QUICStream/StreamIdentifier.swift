/// Stream Identifier Newtype (RFC 9000 Section 2.1)
///
/// A type-safe wrapper around `UInt64` stream IDs that prevents accidental
/// type confusion between stream IDs, packet numbers, and other `UInt64` values.
///
/// QUIC stream IDs encode metadata in their two least-significant bits:
/// - Bit 0: Initiator (0 = client, 1 = server)
/// - Bit 1: Directionality (0 = bidirectional, 1 = unidirectional)
///
/// ## Migration
///
/// This type is introduced alongside the existing ``StreamID`` utility enum.
/// The existing enum provides static methods operating on raw `UInt64` values;
/// this struct wraps the value and exposes the same functionality as instance
/// properties and methods, enabling compile-time type safety.
///
/// Future work will migrate call sites from `UInt64` + `StreamID.isBidirectional(_:)`
/// to `StreamIdentifier` + `.isBidirectional`.

import Foundation

/// A type-safe QUIC stream identifier.
///
/// Wraps a raw `UInt64` stream ID and provides RFC 9000-compliant
/// accessors for the metadata encoded in the two least-significant bits.
///
/// ```swift
/// let id = StreamIdentifier(rawValue: 0)
/// assert(id.isClientInitiated)
/// assert(id.isBidirectional)
/// assert(id.streamIndex == 0)
/// ```
public struct StreamIdentifier: RawRepresentable, Hashable, Sendable, Comparable {
    // MARK: - Stored Property

    /// The raw `UInt64` stream ID as defined by RFC 9000.
    public let rawValue: UInt64

    // MARK: - Initialization

    /// Creates a stream identifier from a raw `UInt64` value.
    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Creates a stream identifier from its constituent parts.
    ///
    /// - Parameters:
    ///   - index: The stream index (0, 1, 2, …). This is the sequence number
    ///     within the (initiator, directionality) group.
    ///   - isClient: Whether this stream is initiated by the client.
    ///   - isBidirectional: Whether this stream is bidirectional.
    public init(index: UInt64, isClient: Bool, isBidirectional: Bool) {
        var id = index << 2
        if !isClient { id |= 0x01 }
        if !isBidirectional { id |= 0x02 }
        self.rawValue = id
    }

    // MARK: - Stream Type Properties

    /// The stream type derived from the two least-significant bits.
    public var streamType: StreamID.StreamType {
        StreamID.streamType(for: rawValue)
    }

    /// Whether this stream is bidirectional (bit 1 == 0).
    public var isBidirectional: Bool {
        (rawValue & 0x02) == 0
    }

    /// Whether this stream is unidirectional (bit 1 == 1).
    public var isUnidirectional: Bool {
        (rawValue & 0x02) != 0
    }

    /// Whether this stream was initiated by the client (bit 0 == 0).
    public var isClientInitiated: Bool {
        (rawValue & 0x01) == 0
    }

    /// Whether this stream was initiated by the server (bit 0 == 1).
    public var isServerInitiated: Bool {
        (rawValue & 0x01) != 0
    }

    /// The stream index (sequence number within the type group).
    ///
    /// This is the value passed as `index` to ``init(index:isClient:isBidirectional:)``.
    /// It equals `rawValue >> 2`.
    public var streamIndex: UInt64 {
        rawValue >> 2
    }

    // MARK: - Comparable

    public static func < (lhs: StreamIdentifier, rhs: StreamIdentifier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Conversion Helpers

extension StreamIdentifier {
    /// Creates a stream identifier from a raw `UInt64`, mirroring
    /// ``StreamID/make(index:isClient:isBidirectional:)``.
    public static func make(
        index: UInt64,
        isClient: Bool,
        isBidirectional: Bool
    ) -> StreamIdentifier {
        StreamIdentifier(index: index, isClient: isClient, isBidirectional: isBidirectional)
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension StreamIdentifier: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}

// MARK: - CustomStringConvertible

extension StreamIdentifier: CustomStringConvertible {
    public var description: String {
        let direction = isBidirectional ? "bidi" : "uni"
        let initiator = isClientInitiated ? "client" : "server"
        return "StreamIdentifier(\(rawValue), \(initiator)-\(direction))"
    }
}

// MARK: - CustomDebugStringConvertible

extension StreamIdentifier: CustomDebugStringConvertible {
    public var debugDescription: String {
        description
    }
}

// MARK: - Codable

extension StreamIdentifier: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UInt64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Bridging with StreamID Utility Enum

extension StreamIdentifier {
    /// Checks whether this stream is a remote stream relative to the given role.
    ///
    /// - Parameter isClient: `true` if the local endpoint is a client.
    /// - Returns: `true` if the stream was initiated by the remote peer.
    public func isRemote(localIsClient isClient: Bool) -> Bool {
        isClient != isClientInitiated
    }

    /// Checks whether this stream is locally initiated relative to the given role.
    ///
    /// - Parameter isClient: `true` if the local endpoint is a client.
    /// - Returns: `true` if the stream was initiated by the local endpoint.
    public func isLocal(localIsClient isClient: Bool) -> Bool {
        isClient == isClientInitiated
    }
}