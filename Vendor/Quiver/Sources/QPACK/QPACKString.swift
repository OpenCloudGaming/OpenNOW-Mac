/// QPACK String Literal Encoding/Decoding (RFC 9204 Section 4.1.2)
///
/// String literals in QPACK can be encoded either as raw octets or using
/// Huffman coding. The first bit (H) of the length prefix indicates the
/// encoding used:
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// | H |    String Length (7+)      |
/// +---+---------------------------+
/// |  String Data (Length octets)   |
/// +-------------------------------+
/// ```
///
/// - H=0: The string is encoded as raw octets
/// - H=1: The string is encoded using the Huffman code defined in
///         RFC 7541 Appendix B
///
/// For this initial implementation, encoding always uses raw (non-Huffman)
/// strings for simplicity. Decoding supports both raw and Huffman-encoded
/// strings.

import Foundation

// MARK: - QPACK String Codec

/// QPACK string literal encoding and decoding operations
public enum QPACKString {

    /// Maximum allowed string length to prevent memory exhaustion attacks.
    /// 64 KB is generous for header values; most are well under 8 KB.
    private static let maxStringLength: UInt64 = 65536

    // MARK: - Encoding

    /// Encodes a string as a QPACK string literal (raw, non-Huffman).
    ///
    /// The output format is:
    /// ```
    /// +---+---+---+---+---+---+---+---+
    /// | 0 |    String Length (7+)      |   H=0 (raw)
    /// +---+---------------------------+
    /// |  String Data (Length octets)   |
    /// +-------------------------------+
    /// ```
    ///
    /// - Parameter string: The string to encode
    /// - Returns: The encoded bytes
    ///
    /// ## Example
    ///
    /// ```swift
    /// let encoded = QPACKString.encode("hello")
    /// // [0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f]
    /// //  ^len   h     e     l     l     o
    /// ```
    public static func encode(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        return encode(bytes: bytes)
    }

    /// Encodes raw bytes as a QPACK string literal (non-Huffman).
    ///
    /// - Parameter bytes: The raw bytes to encode
    /// - Returns: The encoded bytes including length prefix
    public static func encode(bytes: Data) -> Data {
        // H bit = 0 (raw encoding), 7-bit prefix for length
        let lengthPrefix = QPACKInteger.encode(
            UInt64(bytes.count),
            prefix: 7,
            firstByte: 0x00  // H=0
        )
        var result = Data()
        result.reserveCapacity(lengthPrefix.count + bytes.count)
        result.append(lengthPrefix)
        result.append(bytes)
        return result
    }

    /// Encodes a string using Huffman coding as a QPACK string literal.
    ///
    /// The output format is:
    /// ```
    /// +---+---+---+---+---+---+---+---+
    /// | 1 |    String Length (7+)      |   H=1 (Huffman)
    /// +---+---------------------------+
    /// |  Huffman Encoded Data          |
    /// +-------------------------------+
    /// ```
    ///
    /// - Parameter string: The string to encode
    /// - Returns: The Huffman-encoded bytes, or raw bytes if Huffman is larger
    public static func encodeHuffman(_ string: String) -> Data {
        let rawBytes = Data(string.utf8)
        let huffmanBytes = HuffmanCodec.encode(rawBytes)

        // Only use Huffman if it's actually shorter
        if huffmanBytes.count < rawBytes.count {
            let lengthPrefix = QPACKInteger.encode(
                UInt64(huffmanBytes.count),
                prefix: 7,
                firstByte: 0x80  // H=1 (Huffman)
            )
            var result = Data()
            result.reserveCapacity(lengthPrefix.count + huffmanBytes.count)
            result.append(lengthPrefix)
            result.append(huffmanBytes)
            return result
        } else {
            // Fall back to raw encoding
            return encode(rawBytes.count == rawBytes.count ? string : string)
        }
    }

    // MARK: - Decoding

    /// Decodes a QPACK string literal from the given data at the specified offset.
    ///
    /// Supports both raw and Huffman-encoded strings. The H bit in the first byte
    /// determines the encoding.
    ///
    /// - Parameters:
    ///   - data: The data to decode from
    ///   - offset: The current read position (updated on success)
    /// - Returns: The decoded string
    /// - Throws: `QPACKStringError` if decoding fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// var offset = 0
    /// let decoded = try QPACKString.decode(from: Data([0x05, 0x68, 0x65, 0x6c, 0x6c, 0x6f]),
    ///                                      offset: &offset)
    /// // decoded == "hello", offset == 6
    /// ```
    public static func decode(from data: Data, offset: inout Int) throws -> String {
        let bytes = try decodeBytes(from: data, offset: &offset)

        guard let string = String(data: bytes, encoding: .utf8) else {
            throw QPACKStringError.invalidUTF8
        }
        return string
    }

    /// Decodes a QPACK string literal as raw bytes.
    ///
    /// This is useful when the string content may not be valid UTF-8
    /// (e.g., binary header values).
    ///
    /// - Parameters:
    ///   - data: The data to decode from
    ///   - offset: The current read position (updated on success)
    /// - Returns: The decoded bytes
    /// - Throws: `QPACKStringError` if decoding fails
    public static func decodeBytes(from data: Data, offset: inout Int) throws -> Data {
        guard offset < data.count else {
            throw QPACKStringError.insufficientData
        }

        // Read H bit from the first byte
        let firstByte = data[data.startIndex + offset]
        let isHuffman = (firstByte & 0x80) != 0

        // Decode string length (7-bit prefix)
        let length = try QPACKInteger.decode(from: data, offset: &offset, prefix: 7)

        // Validate length
        guard length <= maxStringLength else {
            throw QPACKStringError.stringTooLong(Int(length))
        }

        let intLength = Int(length)

        guard offset + intLength <= data.count else {
            throw QPACKStringError.insufficientData
        }

        // Extract string bytes
        let stringBytes = data[(data.startIndex + offset)..<(data.startIndex + offset + intLength)]
        offset += intLength

        if isHuffman {
            // Decode Huffman-encoded string
            return try HuffmanCodec.decode(Data(stringBytes))
        } else {
            // Raw string
            return Data(stringBytes)
        }
    }

    // MARK: - Utility

    /// Returns the number of bytes needed to encode a string (raw, non-Huffman).
    ///
    /// - Parameter string: The string to measure
    /// - Returns: Total encoded size in bytes (length prefix + string bytes)
    public static func encodedSize(_ string: String) -> Int {
        let byteCount = string.utf8.count
        let lengthPrefixSize = QPACKInteger.encodedSize(UInt64(byteCount), prefix: 7)
        return lengthPrefixSize + byteCount
    }

    /// Returns the number of bytes needed to encode raw bytes (non-Huffman).
    ///
    /// - Parameter bytes: The bytes to measure
    /// - Returns: Total encoded size in bytes (length prefix + data bytes)
    public static func encodedSize(bytes: Data) -> Int {
        let lengthPrefixSize = QPACKInteger.encodedSize(UInt64(bytes.count), prefix: 7)
        return lengthPrefixSize + bytes.count
    }
}

// MARK: - Errors

/// Errors that can occur during QPACK string decoding
public enum QPACKStringError: Error, Sendable, CustomStringConvertible {
    /// Not enough data available to decode the string
    case insufficientData

    /// The decoded string is not valid UTF-8
    case invalidUTF8

    /// The string length exceeds the maximum allowed
    case stringTooLong(Int)

    /// Huffman decoding failed
    case huffmanDecodingFailed(String)

    public var description: String {
        switch self {
        case .insufficientData:
            return "Insufficient data for QPACK string decoding"
        case .invalidUTF8:
            return "QPACK string contains invalid UTF-8"
        case .stringTooLong(let length):
            return "QPACK string length \(length) exceeds maximum allowed (65536)"
        case .huffmanDecodingFailed(let reason):
            return "QPACK Huffman decoding failed: \(reason)"
        }
    }
}