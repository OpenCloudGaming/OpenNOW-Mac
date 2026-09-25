/// QPACK Decoder (RFC 9204)
///
/// Decodes QPACK-encoded field sections back into HTTP header field lists.
///
/// This implementation supports **literal-only mode** (no dynamic table),
/// which is the simplest fully-compliant configuration. The decoder:
///
/// 1. Decodes **Indexed Field Line** references to the static table
/// 2. Decodes **Indexed Field Line With Post-Base Index** (rejected in literal-only mode)
/// 3. Decodes **Literal Field Line With Name Reference** (static table)
/// 4. Decodes **Literal Field Line With Post-Base Name Reference** (rejected in literal-only mode)
/// 5. Decodes **Literal Field Line With Literal Name**
///
/// The Required Insert Count MUST be 0 (no dynamic table references).
/// If a non-zero Required Insert Count is encountered, decoding fails.
///
/// ## Wire Format
///
/// Each encoded field section begins with a two-byte prefix:
///
/// ```
///   0   1   2   3   4   5   6   7
/// +---+---+---+---+---+---+---+---+
/// |   Required Insert Count (8+)  |   = 0
/// +---+---+---+---+---+---+---+---+
/// | S |      Delta Base (7+)      |   = 0
/// +---+---+---+---+---+---+---+---+
/// | Encoded Field Lines ...       |
/// +-------------------------------+
/// ```
///
/// ## Usage
///
/// ```swift
/// let decoder = QPACKDecoder()
/// let headers = try decoder.decode(encodedData)
/// for (name, value) in headers {
///     print("\(name): \(value)")
/// }
/// ```

import Foundation

// MARK: - QPACK Decoder

/// Decodes QPACK-encoded field sections into header field lists.
///
/// This decoder operates in literal-only mode: it does not support
/// dynamic table references. Any encoded field section that references
/// the dynamic table will cause a decoding error.
///
/// The decoder is stateless and `Sendable`, so a single instance can
/// be shared across concurrent request streams.
public struct QPACKDecoder: Sendable {

    /// Maximum number of header fields allowed in a single field section.
    /// Prevents memory exhaustion from maliciously crafted input.
    private let maxHeaderCount: Int

    /// Maximum total size of all decoded header fields (sum of name + value lengths).
    /// Prevents memory exhaustion from large headers.
    private let maxHeaderListSize: Int

    // MARK: - Initialization

    /// Creates a QPACK decoder.
    ///
    /// - Parameters:
    ///   - maxHeaderCount: Maximum number of headers allowed (default: 256)
    ///   - maxHeaderListSize: Maximum total header size in bytes (default: 65536)
    public init(maxHeaderCount: Int = 256, maxHeaderListSize: Int = 65536) {
        self.maxHeaderCount = maxHeaderCount
        self.maxHeaderListSize = maxHeaderListSize
    }

    // MARK: - Decoding

    /// Decodes a QPACK-encoded field section into a list of header fields.
    ///
    /// - Parameter data: The QPACK-encoded field section bytes
    /// - Returns: An array of (name, value) tuples representing the header fields
    /// - Throws: `QPACKDecoderError` if decoding fails
    ///
    /// ## Example
    ///
    /// ```swift
    /// let decoder = QPACKDecoder()
    /// let headers = try decoder.decode(encodedData)
    /// // headers == [
    /// //     (":method", "GET"),
    /// //     (":path", "/"),
    /// //     (":scheme", "https"),
    /// //     (":authority", "example.com"),
    /// // ]
    /// ```
    public func decode(_ data: Data) throws -> [(name: String, value: String)] {
        guard data.count >= 2 else {
            throw QPACKDecoderError.insufficientData
        }

        var offset = 0

        // === Decode the Encoded Field Section Prefix (RFC 9204 Section 4.5) ===

        // Required Insert Count (8-bit prefix)
        let requiredInsertCount = try QPACKInteger.decode(from: data, offset: &offset, prefix: 8)

        // In literal-only mode, Required Insert Count MUST be 0
        guard requiredInsertCount == 0 else {
            throw QPACKDecoderError.dynamicTableNotSupported(requiredInsertCount: requiredInsertCount)
        }

        // Delta Base: S bit (1) + Delta Base (7-bit prefix)
        // In literal-only mode, we just consume it; it should be 0
        let _ = try QPACKInteger.decode(from: data, offset: &offset, prefix: 7)

        // === Decode Field Lines ===
        var headers: [(name: String, value: String)] = []
        headers.reserveCapacity(16) // Typical HTTP request has ~8-16 headers
        var totalSize = 0

        while offset < data.count {
            // Check header count limit
            guard headers.count < maxHeaderCount else {
                throw QPACKDecoderError.tooManyHeaders(count: headers.count + 1, limit: maxHeaderCount)
            }

            let header = try decodeFieldLine(from: data, offset: &offset)

            // Check total size limit (RFC 9204: field size = name length + value length + 32)
            totalSize += header.name.utf8.count + header.value.utf8.count + 32
            guard totalSize <= maxHeaderListSize else {
                throw QPACKDecoderError.headerListTooLarge(size: totalSize, limit: maxHeaderListSize)
            }

            headers.append(header)
        }

        return headers
    }

    /// Decodes a QPACK-encoded field section into `HTTPField` values.
    ///
    /// Convenience overload that returns `HTTPField` structs.
    ///
    /// - Parameter data: The QPACK-encoded field section bytes
    /// - Returns: An array of `HTTPField` values
    /// - Throws: `QPACKDecoderError` if decoding fails
    public func decodeFields(_ data: Data) throws -> [HTTPField] {
        let headers = try decode(data)
        return headers.map { HTTPField(name: $0.name, value: $0.value) }
    }

    // MARK: - Field Line Decoding

    /// Decodes a single field line from the encoded data.
    ///
    /// The field line type is determined by the first byte's bit pattern:
    /// - `1xxxxxxx` → Indexed Field Line (Section 4.5.2)
    /// - `0001xxxx` → Indexed Field Line With Post-Base Index (Section 4.5.3)
    /// - `01xxxxxx` → Literal Field Line With Name Reference (Section 4.5.4)
    /// - `0000xxxx` → Literal Field Line With Post-Base Name Reference (Section 4.5.5)
    /// - `001xxxxx` → Literal Field Line With Literal Name (Section 4.5.6)
    ///
    /// - Parameters:
    ///   - data: The encoded data
    ///   - offset: The current read position (updated on success)
    /// - Returns: A (name, value) tuple
    /// - Throws: `QPACKDecoderError` if decoding fails
    private func decodeFieldLine(
        from data: Data,
        offset: inout Int
    ) throws -> (name: String, value: String) {
        guard offset < data.count else {
            throw QPACKDecoderError.insufficientData
        }

        let firstByte = data[data.startIndex + offset]

        if firstByte & 0x80 != 0 {
            // 1xxxxxxx → Indexed Field Line (RFC 9204 Section 4.5.2)
            return try decodeIndexedFieldLine(from: data, offset: &offset)
        } else if firstByte & 0xf0 == 0x10 {
            // 0001xxxx → Indexed Field Line With Post-Base Index (Section 4.5.3)
            // Not supported in literal-only mode
            throw QPACKDecoderError.dynamicTableNotSupported(requiredInsertCount: 1)
        } else if firstByte & 0xc0 == 0x40 {
            // 01xxxxxx → Literal Field Line With Name Reference (Section 4.5.4)
            return try decodeLiteralWithNameReference(from: data, offset: &offset)
        } else if firstByte & 0xf0 == 0x00 {
            // 0000xxxx → Literal Field Line With Post-Base Name Reference (Section 4.5.5)
            // Not supported in literal-only mode
            throw QPACKDecoderError.dynamicTableNotSupported(requiredInsertCount: 1)
        } else if firstByte & 0xe0 == 0x20 {
            // 001xxxxx → Literal Field Line With Literal Name (Section 4.5.6)
            return try decodeLiteralWithLiteralName(from: data, offset: &offset)
        } else {
            throw QPACKDecoderError.invalidFieldLineType(firstByte: firstByte)
        }
    }

    /// Decodes an Indexed Field Line (RFC 9204 Section 4.5.2).
    ///
    /// ```
    ///   0   1   2   3   4   5   6   7
    /// +---+---+---+---+---+---+---+---+
    /// | 1 | T |      Index (6+)       |
    /// +---+---+-----------------------+
    /// ```
    ///
    /// - T=1: Reference to the static table
    /// - T=0: Reference to the dynamic table (not supported)
    ///
    /// - Parameters:
    ///   - data: The encoded data
    ///   - offset: The current read position (updated on success)
    /// - Returns: A (name, value) tuple from the static table
    /// - Throws: `QPACKDecoderError` if decoding fails
    private func decodeIndexedFieldLine(
        from data: Data,
        offset: inout Int
    ) throws -> (name: String, value: String) {
        guard offset < data.count else {
            throw QPACKDecoderError.insufficientData
        }

        let firstByte = data[data.startIndex + offset]
        let isStatic = (firstByte & 0x40) != 0

        guard isStatic else {
            // T=0: Dynamic table reference — not supported
            throw QPACKDecoderError.dynamicTableNotSupported(requiredInsertCount: 1)
        }

        // Decode index with 6-bit prefix
        let index = try QPACKInteger.decode(from: data, offset: &offset, prefix: 6)

        guard let entry = QPACKStaticTable.entry(at: Int(index)) else {
            throw QPACKDecoderError.invalidStaticTableIndex(Int(index))
        }

        return (entry.name, entry.value)
    }

    /// Decodes a Literal Field Line With Name Reference (RFC 9204 Section 4.5.4).
    ///
    /// ```
    ///   0   1   2   3   4   5   6   7
    /// +---+---+---+---+---+---+---+---+
    /// | 0 | 1 | N | T |Name Index(4+) |
    /// +---+---+---+---+---------------+
    /// | H |     Value Length (7+)      |
    /// +---+---------------------------+
    /// |  Value String (Length octets)  |
    /// +-------------------------------+
    /// ```
    ///
    /// - N: Never index flag
    /// - T=1: Static table name reference
    /// - T=0: Dynamic table name reference (not supported)
    ///
    /// - Parameters:
    ///   - data: The encoded data
    ///   - offset: The current read position (updated on success)
    /// - Returns: A (name, value) tuple
    /// - Throws: `QPACKDecoderError` if decoding fails
    private func decodeLiteralWithNameReference(
        from data: Data,
        offset: inout Int
    ) throws -> (name: String, value: String) {
        guard offset < data.count else {
            throw QPACKDecoderError.insufficientData
        }

        let firstByte = data[data.startIndex + offset]
        let isStatic = (firstByte & 0x10) != 0
        // N bit at 0x20 — never index flag (we note but don't need to act on it during decoding)
        // let neverIndex = (firstByte & 0x20) != 0

        guard isStatic else {
            // T=0: Dynamic table name reference — not supported
            throw QPACKDecoderError.dynamicTableNotSupported(requiredInsertCount: 1)
        }

        // Decode name index with 4-bit prefix
        let nameIndex = try QPACKInteger.decode(from: data, offset: &offset, prefix: 4)

        guard let entry = QPACKStaticTable.entry(at: Int(nameIndex)) else {
            throw QPACKDecoderError.invalidStaticTableIndex(Int(nameIndex))
        }

        // Decode the value string
        let value = try QPACKString.decode(from: data, offset: &offset)

        return (entry.name, value)
    }

    /// Decodes a Literal Field Line With Literal Name (RFC 9204 Section 4.5.6).
    ///
    /// ```
    ///   0   1   2   3   4   5   6   7
    /// +---+---+---+---+---+---+---+---+
    /// | 0 | 0 | 1 | N | H |NameLen(3+)|
    /// +---+---+---+---+---+-----------+
    /// |  Name String (NameLen octets)  |
    /// +---+---------------------------+
    /// | H |     Value Length (7+)      |
    /// +---+---------------------------+
    /// |  Value String (Length octets)  |
    /// +-------------------------------+
    /// ```
    ///
    /// - N: Never index flag
    /// - H: Huffman encoding flag for the name
    ///
    /// - Parameters:
    ///   - data: The encoded data
    ///   - offset: The current read position (updated on success)
    /// - Returns: A (name, value) tuple
    /// - Throws: `QPACKDecoderError` if decoding fails
    private func decodeLiteralWithLiteralName(
        from data: Data,
        offset: inout Int
    ) throws -> (name: String, value: String) {
        guard offset < data.count else {
            throw QPACKDecoderError.insufficientData
        }

        let firstByte = data[data.startIndex + offset]
        // N bit at 0x10 — never index flag (noted but not acted on during decoding)
        // let neverIndex = (firstByte & 0x10) != 0
        let nameIsHuffman = (firstByte & 0x08) != 0

        // Decode name length with 3-bit prefix
        let nameLength = try QPACKInteger.decode(from: data, offset: &offset, prefix: 3)

        // Validate name length
        guard nameLength <= 65536 else {
            throw QPACKDecoderError.headerNameTooLong(Int(nameLength))
        }

        let intNameLength = Int(nameLength)
        guard offset + intNameLength <= data.count else {
            throw QPACKDecoderError.insufficientData
        }

        // Read name bytes
        let nameBytes = data[(data.startIndex + offset)..<(data.startIndex + offset + intNameLength)]
        offset += intNameLength

        // Decode name
        let nameData: Data
        if nameIsHuffman {
            nameData = try HuffmanCodec.decode(Data(nameBytes))
        } else {
            nameData = Data(nameBytes)
        }

        guard let name = String(data: nameData, encoding: .utf8) else {
            throw QPACKDecoderError.invalidUTF8InHeaderName
        }

        // Decode the value string
        let value = try QPACKString.decode(from: data, offset: &offset)

        return (name, value)
    }
}

// MARK: - Errors

/// Errors that can occur during QPACK field section decoding
public enum QPACKDecoderError: Error, Sendable, CustomStringConvertible {
    /// Not enough data available to decode the field section
    case insufficientData

    /// The encoded field section references the dynamic table, which is not supported
    case dynamicTableNotSupported(requiredInsertCount: UInt64)

    /// The static table index is out of range (0-98)
    case invalidStaticTableIndex(Int)

    /// The field line type byte is not recognized
    case invalidFieldLineType(firstByte: UInt8)

    /// Too many headers in the field section
    case tooManyHeaders(count: Int, limit: Int)

    /// The total header list size exceeds the maximum
    case headerListTooLarge(size: Int, limit: Int)

    /// A header name is too long
    case headerNameTooLong(Int)

    /// A header name contains invalid UTF-8
    case invalidUTF8InHeaderName

    /// A header value contains invalid UTF-8
    case invalidUTF8InHeaderValue

    /// Integer decoding failed within the field section
    case integerDecodingFailed(Error)

    /// String decoding failed within the field section
    case stringDecodingFailed(Error)

    public var description: String {
        switch self {
        case .insufficientData:
            return "Insufficient data for QPACK field section decoding"
        case .dynamicTableNotSupported(let ric):
            return "Dynamic table not supported (Required Insert Count = \(ric))"
        case .invalidStaticTableIndex(let index):
            return "Invalid QPACK static table index: \(index) (valid range: 0-98)"
        case .invalidFieldLineType(let byte):
            return "Invalid QPACK field line type: 0x\(String(byte, radix: 16, uppercase: true))"
        case .tooManyHeaders(let count, let limit):
            return "Too many headers: \(count) exceeds limit of \(limit)"
        case .headerListTooLarge(let size, let limit):
            return "Header list size \(size) exceeds limit of \(limit)"
        case .headerNameTooLong(let length):
            return "Header name length \(length) exceeds maximum"
        case .invalidUTF8InHeaderName:
            return "Header name contains invalid UTF-8"
        case .invalidUTF8InHeaderValue:
            return "Header value contains invalid UTF-8"
        case .integerDecodingFailed(let error):
            return "QPACK integer decoding failed: \(error)"
        case .stringDecodingFailed(let error):
            return "QPACK string decoding failed: \(error)"
        }
    }
}