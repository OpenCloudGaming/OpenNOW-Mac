/// A cursor-based reader for parsing binary data
///
/// DataReader provides a convenient way to sequentially read bytes from Data,
/// tracking the current position automatically.

import Foundation

/// A cursor-based reader for binary data
public struct DataReader: Sendable {
    /// The underlying data being read
    @usableFromInline
    let data: Data

    /// Current read position
    @usableFromInline
    var position: Data.Index

    /// Creates a new DataReader
    /// - Parameter data: The data to read from (ownership is transferred to the reader)
    public init(_ data: consuming Data) {
        self.data = data
        self.position = self.data.startIndex
    }

    /// The number of bytes remaining to be read
    @inlinable
    public var remainingCount: Int {
        data.endIndex - position
    }

    /// Whether there are more bytes to read
    @inlinable
    public var hasRemaining: Bool {
        position < data.endIndex
    }

    /// The remaining data from current position to end (returns a slice, no copy)
    @inlinable
    public var remainingData: Data {
        data[position...]
    }

    /// The current position in the data
    public var currentPosition: Int {
        position - data.startIndex
    }

    /// Advances the read position by the specified number of bytes
    /// - Parameter count: Number of bytes to skip
    /// - Precondition: `count <= remainingCount`
    public mutating func advance(by count: Int) {
        precondition(count <= remainingCount, "Cannot advance past end of data")
        position += count
    }

    /// Reads a single byte
    /// - Returns: The byte read, or nil if no bytes remaining
    @inlinable
    public mutating func readByte() -> UInt8? {
        guard hasRemaining else { return nil }
        let byte = data[position]
        position += 1
        return byte
    }

    /// Reads the specified number of bytes
    /// - Parameter count: Number of bytes to read
    /// - Returns: The bytes read as a slice (no copy), or nil if insufficient bytes remaining
    @inlinable
    public mutating func readBytes(_ count: Int) -> Data? {
        guard remainingCount >= count else { return nil }
        let endPosition = position + count
        let result = data[position..<endPosition]
        position = endPosition
        return result
    }

    /// Reads all remaining bytes
    /// - Returns: All remaining bytes as a slice (no copy, may be empty)
    @inlinable
    public mutating func readRemainingBytes() -> Data {
        let result = data[position...]
        position = data.endIndex
        return result
    }

    /// Peeks at the next byte without advancing the position
    /// - Returns: The next byte, or nil if no bytes remaining
    @inlinable
    public func peekByte() -> UInt8? {
        guard hasRemaining else { return nil }
        return data[position]
    }

    /// Peeks at the specified number of bytes without advancing the position
    /// - Parameter count: Number of bytes to peek
    /// - Returns: The bytes as a slice (no copy), or nil if insufficient bytes remaining
    @inlinable
    public func peekBytes(_ count: Int) -> Data? {
        guard remainingCount >= count else { return nil }
        return data[position..<(position + count)]
    }

    /// Reads a UInt8 (1 byte)
    @inlinable
    public mutating func readUInt8() -> UInt8? {
        readByte()
    }

    /// Reads a UInt16 in big-endian byte order
    @inlinable
    public mutating func readUInt16() -> UInt16? {
        guard let bytes = readBytes(2) else { return nil }
        return UInt16(bytes[bytes.startIndex]) << 8
            | UInt16(bytes[bytes.startIndex + 1])
    }

    /// Reads a UInt32 in big-endian byte order
    @inlinable
    public mutating func readUInt32() -> UInt32? {
        guard let bytes = readBytes(4) else { return nil }
        return UInt32(bytes[bytes.startIndex]) << 24
            | UInt32(bytes[bytes.startIndex + 1]) << 16
            | UInt32(bytes[bytes.startIndex + 2]) << 8
            | UInt32(bytes[bytes.startIndex + 3])
    }

    /// Reads a UInt64 in big-endian byte order
    @inlinable
    public mutating func readUInt64() -> UInt64? {
        guard let bytes = readBytes(8) else { return nil }
        var result: UInt64 = 0
        for i in 0..<8 {
            result = result << 8 | UInt64(bytes[bytes.startIndex + i])
        }
        return result
    }

    /// Reads a QUIC variable-length integer
    ///
    /// This method uses an optimized internal path that avoids Data slice creation.
    /// Performance is equivalent to `readVarintValue()`.
    @inlinable
    public mutating func readVarint() throws(Varint.DecodeError) -> Varint {
        // Use the fast path: readVarintValue() operates directly on data[position]
        // without creating an intermediate Data slice via remainingData
        return Varint(try readVarintValue())
    }

    /// Reads a QUIC variable-length integer value directly (faster than readVarint())
    /// - Returns: The decoded UInt64 value
    @inlinable
    public mutating func readVarintValue() throws(Varint.DecodeError) -> UInt64 {
        guard hasRemaining else {
            throw Varint.DecodeError.insufficientData
        }

        let firstByte = data[position]

        // Fast path for 1-byte values (0-63), which are the most common case
        // ~80% of varints in QUIC are 1-byte (stream IDs, small lengths, frame types)
        if firstByte & 0xC0 == 0 {
            position += 1
            return UInt64(firstByte)
        }

        // Slow path for multi-byte values
        return try readVarintValueSlow(firstByte: firstByte)
    }

    /// Slow path for multi-byte varint values
    @usableFromInline
    mutating func readVarintValueSlow(firstByte: UInt8) throws(Varint.DecodeError) -> UInt64 {
        let prefix = firstByte >> 6

        let length: Int
        switch prefix {
        case 0b01: length = 2
        case 0b10: length = 4
        default:   length = 8  // 0b11
        }

        guard remainingCount >= length else {
            throw Varint.DecodeError.insufficientData
        }

        let value: UInt64
        switch length {
        case 2:
            value = UInt64(firstByte & 0x3F) << 8
                | UInt64(data[position + 1])
        case 4:
            value = UInt64(firstByte & 0x3F) << 24
                | UInt64(data[position + 1]) << 16
                | UInt64(data[position + 2]) << 8
                | UInt64(data[position + 3])
        default: // 8
            value = UInt64(firstByte & 0x3F) << 56
                | UInt64(data[position + 1]) << 48
                | UInt64(data[position + 2]) << 40
                | UInt64(data[position + 3]) << 32
                | UInt64(data[position + 4]) << 24
                | UInt64(data[position + 5]) << 16
                | UInt64(data[position + 6]) << 8
                | UInt64(data[position + 7])
        }

        position += length
        return value
    }

    /// Peeks at the next varint without advancing the position
    /// - Returns: The varint value and its encoded length
    /// - Throws: `Varint.DecodeError` if insufficient data
    ///
    /// This method uses an optimized path that avoids Data slice creation.
    @inlinable
    public func peekVarint() throws(Varint.DecodeError) -> (value: UInt64, length: Int) {
        guard hasRemaining else {
            throw Varint.DecodeError.insufficientData
        }

        let firstByte = data[position]
        let prefix = firstByte >> 6

        let length: Int
        switch prefix {
        case 0b00: length = 1
        case 0b01: length = 2
        case 0b10: length = 4
        default:   length = 8  // 0b11
        }

        guard remainingCount >= length else {
            throw Varint.DecodeError.insufficientData
        }

        let value: UInt64
        switch length {
        case 1:
            value = UInt64(firstByte & 0x3F)
        case 2:
            value = UInt64(firstByte & 0x3F) << 8
                | UInt64(data[position + 1])
        case 4:
            value = UInt64(firstByte & 0x3F) << 24
                | UInt64(data[position + 1]) << 16
                | UInt64(data[position + 2]) << 8
                | UInt64(data[position + 3])
        default: // 8
            value = UInt64(firstByte & 0x3F) << 56
                | UInt64(data[position + 1]) << 48
                | UInt64(data[position + 2]) << 40
                | UInt64(data[position + 3]) << 32
                | UInt64(data[position + 4]) << 24
                | UInt64(data[position + 5]) << 16
                | UInt64(data[position + 6]) << 8
                | UInt64(data[position + 7])
        }

        return (value, length)
    }
}

// MARK: - DataWriter

/// A helper for building binary data
package struct DataWriter: Sendable {
    /// The accumulated data
    @usableFromInline
    var data: Data

    /// Creates an empty DataWriter
    /// - Parameter capacity: Initial capacity hint
    package init(capacity: Int = 64) {
        data = Data(capacity: capacity)
    }

    /// The current length of written data
    package var count: Int {
        data.count
    }

    /// Returns the accumulated data
    package func toData() -> Data {
        data
    }

    /// Writes a single byte
    @inlinable
    package mutating func writeByte(_ byte: UInt8) {
        data.append(byte)
    }

    /// Writes raw bytes
    @inlinable
    package mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    /// Writes raw bytes from a sequence
    @inlinable
    package mutating func writeBytes<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        data.append(contentsOf: bytes)
    }

    /// Writes a UInt8 (1 byte)
    @inlinable
    package mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    /// Writes a UInt16 in big-endian byte order
    @inlinable
    package mutating func writeUInt16(_ value: UInt16) {
        data.append(UInt8(value >> 8))
        data.append(UInt8(value & 0xFF))
    }

    /// Writes a UInt32 in big-endian byte order
    @inlinable
    package mutating func writeUInt32(_ value: UInt32) {
        data.append(UInt8(value >> 24))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    /// Writes a UInt64 in big-endian byte order
    @inlinable
    package mutating func writeUInt64(_ value: UInt64) {
        for i in (0..<8).reversed() {
            data.append(UInt8((value >> (i * 8)) & 0xFF))
        }
    }

    /// Writes a QUIC variable-length integer
    @inlinable
    package mutating func writeVarint(_ varint: Varint) {
        varint.encode(to: &data)
    }

    /// Writes a QUIC variable-length integer from a UInt64
    @inlinable
    package mutating func writeVarint(_ value: UInt64) {
        Varint(value).encode(to: &data)
    }

    /// Writes zero bytes (0x00) efficiently
    ///
    /// Uses `Data(count:)` which is zero-initialized and faster than
    /// `Data(repeating: 0x00, count:)` for large counts.
    @inlinable
    package mutating func writeZeroBytes(_ count: Int) {
        data.append(Data(count: count))
    }

    /// Reserves space for later filling, returns the offset
    @inlinable
    package mutating func reserveBytes(_ count: Int) -> Int {
        let offset = data.count
        data.append(Data(count: count))  // Data(count:) is zero-initialized and faster
        return offset
    }

    /// Fills previously reserved bytes at the given offset
    package mutating func fillBytes(_ bytes: Data, at offset: Int) {
        precondition(offset + bytes.count <= data.count)
        data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
    }
}
