/// QPACK Integer Encoding/Decoding (RFC 9204 Section 4.1.1)
///
/// QPACK uses a prefix-based integer encoding derived from HPACK (RFC 7541 Section 5.1).
/// An integer is represented in two parts: a prefix that fills the remaining bits of
/// the current octet, and an optional list of octets for larger values.
///
/// The prefix size (N) determines the maximum value that can be represented in the
/// first octet. If the value is less than 2^N - 1, it is encoded directly. Otherwise,
/// the prefix is filled with all 1s and the remainder is encoded using a variable-length
/// encoding with 7 bits per byte.
///
/// ## Wire Format
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | ? | ? | ? |       Value       |  (prefix = 5 in this example)
/// +---+---+---+---+---+---+---+---+
/// ```
///
/// If the value >= 2^N - 1:
///
/// ```
/// +---+---+---+---+---+---+---+---+
/// | ? | ? | ? | 1   1   1   1   1 |  (all prefix bits set)
/// +---+---+---+---+---+---+---+---+
/// | 1 |    Value - (2^N - 1)      |  (continuation bytes)
/// +---+---------------------------+
/// | 0 |    ...                    |  (final byte, MSB = 0)
/// +---+---------------------------+
/// ```

import Foundation

// MARK: - QPACK Integer Codec

/// QPACK integer encoding and decoding operations
public enum QPACKInteger {

    /// Maximum number of continuation bytes to prevent DoS via excessive encoding
    /// A 62-bit QUIC varint fits in at most 10 continuation bytes (ceil(62/7) = 9, +1 safety)
    private static let maxContinuationBytes = 10

    // MARK: - Encoding

    /// Encodes an integer using QPACK prefix integer encoding.
    ///
    /// - Parameters:
    ///   - value: The integer value to encode (must be non-negative)
    ///   - prefix: The number of bits available in the first byte (1...8)
    ///   - firstByte: The existing bits in the first byte (high bits above the prefix).
    ///                Only the bits above the prefix are preserved; the prefix bits are overwritten.
    /// - Returns: The encoded bytes
    ///
    /// ## Example
    ///
    /// Encoding the value 10 with a 5-bit prefix:
    /// ```
    /// let encoded = QPACKInteger.encode(10, prefix: 5)
    /// // Result: [0x0a] (10 fits in 5 bits)
    /// ```
    ///
    /// Encoding the value 1337 with a 5-bit prefix:
    /// ```
    /// let encoded = QPACKInteger.encode(1337, prefix: 5)
    /// // Result: [0x1f, 0x9a, 0x0a]
    /// // 1337 - 31 = 1306
    /// // 1306 = 0x51a → encoded as [0x9a, 0x0a]
    /// ```
    public static func encode(_ value: UInt64, prefix: Int, firstByte: UInt8 = 0) -> Data {
        precondition(prefix >= 1 && prefix <= 8, "Prefix must be between 1 and 8")

        let maxPrefix = (1 << prefix) - 1  // 2^N - 1
        let prefixMask = UInt8(maxPrefix)

        // Preserve the high bits of firstByte (above the prefix)
        let highBitsMask = ~prefixMask
        let highBits = firstByte & highBitsMask

        if value < UInt64(maxPrefix) {
            // Value fits in the prefix
            return Data([highBits | UInt8(value)])
        }

        // Value doesn't fit in prefix — encode the remainder
        var result = Data()
        result.reserveCapacity(maxContinuationBytes + 1)
        result.append(highBits | prefixMask)

        var remaining = value - UInt64(maxPrefix)
        while remaining >= 128 {
            result.append(UInt8(remaining & 0x7f) | 0x80)  // Set continuation bit
            remaining >>= 7
        }
        result.append(UInt8(remaining))  // Final byte (no continuation bit)

        return result
    }

    /// Encodes an integer into the first byte of an existing buffer, appending continuation bytes.
    ///
    /// This is useful when building a header byte that contains both flags and an integer value.
    ///
    /// - Parameters:
    ///   - value: The integer value to encode
    ///   - prefix: The number of bits available for the integer
    ///   - buffer: The buffer to append to (the first byte's high bits should already be set)
    ///   - firstByteIndex: Index of the byte in the buffer where the prefix starts
    public static func encode(_ value: UInt64, prefix: Int, into buffer: inout Data, firstByteIndex: Int) {
        precondition(prefix >= 1 && prefix <= 8, "Prefix must be between 1 and 8")
        precondition(firstByteIndex < buffer.count, "firstByteIndex out of range")

        let maxPrefix = (1 << prefix) - 1
        let prefixMask = UInt8(maxPrefix)
        let highBitsMask = ~prefixMask
        let highBits = buffer[buffer.startIndex + firstByteIndex] & highBitsMask

        if value < UInt64(maxPrefix) {
            buffer[buffer.startIndex + firstByteIndex] = highBits | UInt8(value)
            return
        }

        buffer[buffer.startIndex + firstByteIndex] = highBits | prefixMask

        var remaining = value - UInt64(maxPrefix)
        while remaining >= 128 {
            buffer.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        buffer.append(UInt8(remaining))
    }

    // MARK: - Decoding

    /// Decodes a QPACK prefix integer from the given data at the specified offset.
    ///
    /// - Parameters:
    ///   - data: The data to decode from
    ///   - offset: The current read position (updated on success)
    ///   - prefix: The number of prefix bits (1...8)
    /// - Returns: The decoded integer value
    /// - Throws: `QPACKIntegerError` if decoding fails
    ///
    /// ## Example
    ///
    /// ```
    /// var offset = 0
    /// let value = try QPACKInteger.decode(from: Data([0x0a]), offset: &offset, prefix: 5)
    /// // value == 10, offset == 1
    /// ```
    public static func decode(from data: Data, offset: inout Int, prefix: Int) throws -> UInt64 {
        precondition(prefix >= 1 && prefix <= 8, "Prefix must be between 1 and 8")

        guard offset < data.count else {
            throw QPACKIntegerError.insufficientData
        }

        let maxPrefix = UInt64((1 << prefix) - 1)
        let prefixMask = UInt8(maxPrefix)

        let firstByte = data[data.startIndex + offset]
        let prefixValue = UInt64(firstByte & prefixMask)
        offset += 1

        if prefixValue < maxPrefix {
            // Value fits in the prefix
            return prefixValue
        }

        // Read continuation bytes
        var value = maxPrefix
        var shift: UInt64 = 0
        var bytesRead = 0

        while true {
            guard offset < data.count else {
                throw QPACKIntegerError.insufficientData
            }

            let byte = data[data.startIndex + offset]
            offset += 1
            bytesRead += 1

            // Prevent DoS from excessively long encodings
            if bytesRead > maxContinuationBytes {
                throw QPACKIntegerError.integerOverflow
            }

            // Check for overflow before adding
            let contribution = UInt64(byte & 0x7f)

            // Verify the shift won't overflow a UInt64
            if shift >= 63 && contribution > 1 {
                throw QPACKIntegerError.integerOverflow
            }

            let shiftedContribution = contribution << shift
            let (newValue, overflow) = value.addingReportingOverflow(shiftedContribution)
            if overflow {
                throw QPACKIntegerError.integerOverflow
            }
            value = newValue
            shift += 7

            // Check if this is the last byte (MSB not set)
            if byte & 0x80 == 0 {
                break
            }
        }

        return value
    }

    /// Decodes a QPACK prefix integer and returns the first byte's high bits.
    ///
    /// This is useful when the first byte contains both flags and an integer value.
    ///
    /// - Parameters:
    ///   - data: The data to decode from
    ///   - offset: The current read position (updated on success)
    ///   - prefix: The number of prefix bits (1...8)
    /// - Returns: A tuple of (decoded integer value, first byte including high bits)
    /// - Throws: `QPACKIntegerError` if decoding fails
    public static func decodeWithFirstByte(
        from data: Data,
        offset: inout Int,
        prefix: Int
    ) throws -> (value: UInt64, firstByte: UInt8) {
        guard offset < data.count else {
            throw QPACKIntegerError.insufficientData
        }

        let firstByte = data[data.startIndex + offset]
        let value = try decode(from: data, offset: &offset, prefix: prefix)
        return (value, firstByte)
    }

    // MARK: - Utility

    /// Returns the number of bytes needed to encode a value with the given prefix.
    ///
    /// - Parameters:
    ///   - value: The integer value
    ///   - prefix: The prefix bit count
    /// - Returns: Number of bytes required
    public static func encodedSize(_ value: UInt64, prefix: Int) -> Int {
        precondition(prefix >= 1 && prefix <= 8, "Prefix must be between 1 and 8")

        let maxPrefix = UInt64((1 << prefix) - 1)

        if value < maxPrefix {
            return 1
        }

        var remaining = value - maxPrefix
        var size = 1  // first byte
        while remaining >= 128 {
            size += 1
            remaining >>= 7
        }
        size += 1  // final byte
        return size
    }
}

// MARK: - Errors

/// Errors that can occur during QPACK integer decoding
public enum QPACKIntegerError: Error, Sendable, CustomStringConvertible {
    /// Not enough data available to decode the integer
    case insufficientData

    /// The encoded integer value overflows UInt64
    case integerOverflow

    /// The encoding is invalid
    case invalidEncoding

    public var description: String {
        switch self {
        case .insufficientData:
            return "Insufficient data for QPACK integer decoding"
        case .integerOverflow:
            return "QPACK integer value overflows UInt64"
        case .invalidEncoding:
            return "Invalid QPACK integer encoding"
        }
    }
}