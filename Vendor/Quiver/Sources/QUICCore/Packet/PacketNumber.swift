/// Packet Number Newtype (RFC 9000 Section 17.1)
///
/// A type-safe wrapper around `UInt64` packet numbers that prevents accidental
/// type confusion between packet numbers, stream IDs, and other `UInt64` values.
///
/// QUIC packet numbers are integers in the range 0 to 2^62-1 (§12.3). They are
/// used to uniquely identify packets within a packet number space and are critical
/// for loss detection and acknowledgement processing.
///
/// ## Migration
///
/// This type is introduced as a foundation for incremental migration. Call sites
/// currently using raw `UInt64` for packet numbers can adopt `PacketNumber`
/// gradually. Use `.rawValue` at module boundaries where `UInt64` is still expected.
///
/// Future work will migrate `SentPacket.id`, `LossDetector.largestAckedPacket`,
/// `AckManager.largestReceived`, `ConnectionState.nextPacketNumber`, and related
/// fields from `UInt64` to `PacketNumber`.

import Foundation

/// A type-safe QUIC packet number.
///
/// Wraps a raw `UInt64` packet number and provides RFC 9000-compliant
/// helpers for packet number arithmetic, comparison, and encoding.
///
/// ```swift
/// let pn: PacketNumber = 42
/// let next = pn.next()
/// assert(next.rawValue == 43)
/// assert(pn.distance(to: next) == 1)
/// ```
public struct PacketNumber: RawRepresentable, Hashable, Sendable, Comparable {
    // MARK: - Constants

    /// Maximum value representable as a QUIC packet number (2^62 - 1).
    ///
    /// RFC 9000 §12.3: "Packet numbers are integers in the range 0 to 2^62-1."
    public static let maxValue: UInt64 = (1 << 62) - 1

    /// The initial packet number for a new connection (0).
    public static let initial = PacketNumber(rawValue: 0)

    // MARK: - Stored Property

    /// The raw `UInt64` packet number as defined by RFC 9000.
    public let rawValue: UInt64

    // MARK: - Initialization

    /// Creates a packet number from a raw `UInt64` value.
    ///
    /// - Parameter rawValue: The packet number value.
    /// - Precondition: In debug builds, asserts that `rawValue` does not exceed
    ///   the maximum QUIC packet number (2^62 - 1).
    @inlinable
    public init(rawValue: UInt64) {
        assert(rawValue <= Self.maxValue, "Packet number \(rawValue) exceeds maximum (2^62 - 1)")
        self.rawValue = rawValue
    }

    // MARK: - Packet Number Arithmetic

    /// Returns the next sequential packet number.
    ///
    /// - Returns: A `PacketNumber` with value `rawValue + 1`.
    /// - Precondition: The current value must be less than `PacketNumber.maxValue`.
    @inlinable
    public func next() -> PacketNumber {
        PacketNumber(rawValue: rawValue + 1)
    }

    /// Returns the distance from this packet number to another.
    ///
    /// Useful for calculating gaps in acknowledgement ranges and for
    /// packet number decoding (RFC 9000 §A.3).
    ///
    /// - Parameter other: The target packet number.
    /// - Returns: The signed distance (`other - self`). Positive if `other` is
    ///   greater, negative if `other` is smaller.
    @inlinable
    public func distance(to other: PacketNumber) -> Int64 {
        Int64(bitPattern: other.rawValue) - Int64(bitPattern: rawValue)
    }

    /// Returns a packet number advanced by the given offset.
    ///
    /// - Parameter offset: The number of positions to advance (may be negative).
    /// - Returns: The advanced packet number.
    @inlinable
    public func advanced(by offset: Int64) -> PacketNumber {
        if offset >= 0 {
            return PacketNumber(rawValue: rawValue + UInt64(offset))
        } else {
            return PacketNumber(rawValue: rawValue - UInt64(-offset))
        }
    }

    // MARK: - Encoding Helpers

    /// The minimum number of bytes needed to encode the truncated representation
    /// of this packet number (RFC 9000 §17.1).
    ///
    /// The encoding length depends on the distance from the largest acknowledged
    /// packet number. When no context is available, returns 4 (maximum).
    ///
    /// - Parameter largestAcked: The largest packet number acknowledged by the peer,
    ///   or `nil` if no acknowledgements have been received.
    /// - Returns: The encoding length in bytes (1, 2, 3, or 4).
    @inlinable
    public func encodedLength(largestAcked: PacketNumber?) -> Int {
        guard let largestAcked = largestAcked else {
            // No ACK received yet — use full 4-byte encoding
            return 4
        }

        // RFC 9000 Appendix A.2: Packet number encoding
        // The sender MUST use a packet number size that is large enough to
        // represent more than twice the distance from the largest acknowledged.
        let numUnacked = rawValue &- largestAcked.rawValue
        if numUnacked < (1 << 7) {
            return 1
        } else if numUnacked < (1 << 15) {
            return 2
        } else if numUnacked < (1 << 23) {
            return 3
        } else {
            return 4
        }
    }

    // MARK: - Comparable

    @inlinable
    public static func < (lhs: PacketNumber, rhs: PacketNumber) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ExpressibleByIntegerLiteral

extension PacketNumber: ExpressibleByIntegerLiteral {
    @inlinable
    public init(integerLiteral value: UInt64) {
        self.init(rawValue: value)
    }
}

// MARK: - CustomStringConvertible

extension PacketNumber: CustomStringConvertible {
    public var description: String {
        "PN(\(rawValue))"
    }
}

// MARK: - CustomDebugStringConvertible

extension PacketNumber: CustomDebugStringConvertible {
    public var debugDescription: String {
        "PacketNumber(\(rawValue))"
    }
}

// MARK: - Codable

extension PacketNumber: Codable {
    @inlinable
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UInt64.self)
    }

    @inlinable
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Strideable-like Helpers

extension PacketNumber {
    /// Returns a range of packet numbers from `self` to `end` (exclusive).
    ///
    /// Useful for iterating over packet number spaces (e.g., detecting losses).
    ///
    /// - Parameter end: The exclusive upper bound.
    /// - Returns: A sequence of `PacketNumber` values.
    public func until(_ end: PacketNumber) -> some Sequence<PacketNumber> {
        (rawValue..<end.rawValue).lazy.map { PacketNumber(rawValue: $0) }
    }

    /// Returns a range of packet numbers from `self` through `last` (inclusive).
    ///
    /// - Parameter last: The inclusive upper bound.
    /// - Returns: A sequence of `PacketNumber` values.
    public func through(_ last: PacketNumber) -> some Sequence<PacketNumber> {
        (rawValue...last.rawValue).lazy.map { PacketNumber(rawValue: $0) }
    }
}