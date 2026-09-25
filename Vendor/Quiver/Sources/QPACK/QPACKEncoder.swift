/// QPACK Encoder (RFC 9204)
///
/// Encodes HTTP header field lists into QPACK wire format for use in
/// HTTP/3 HEADERS frames.
///
/// This implementation uses **literal-only mode** (no dynamic table),
/// which is the simplest fully-compliant configuration. The encoder:
///
/// 1. Uses **Indexed Field Line** references to the static table when
///    an exact name+value match exists
/// 2. Uses **Literal Field Line With Name Reference** when only the name
///    matches a static table entry
/// 3. Uses **Literal Field Line With Literal Name** for all other headers
///
/// The Required Insert Count is always 0 and no encoder/decoder stream
/// instructions are emitted, making this safe for use without QPACK
/// stream synchronization.
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
/// let encoder = QPACKEncoder()
/// let headers: [(String, String)] = [
///     (":method", "GET"),
///     (":scheme", "https"),
///     (":path", "/"),
///     (":authority", "example.com"),
///     ("accept", "*/*"),
/// ]
/// let encoded = encoder.encode(headers)
/// ```

import Foundation

// MARK: - QPACK Encoder

/// Encodes header field lists into QPACK wire format.
///
/// This encoder operates in literal-only mode: it never inserts entries
/// into the dynamic table, so `SETTINGS_MAX_TABLE_CAPACITY = 0` is
/// the appropriate setting to advertise to the peer.
///
/// The encoder is stateless and `Sendable`, so a single instance can
/// be shared across concurrent request streams.
public struct QPACKEncoder: Sendable {

    // MARK: - Initialization

    /// Creates a QPACK encoder.
    ///
    /// The encoder operates in literal-only mode (no dynamic table).
    public init() {}

    // MARK: - Encoding

    /// Encodes a list of header fields into a QPACK encoded field section.
    ///
    /// The output includes the required prefix (Required Insert Count = 0,
    /// Delta Base = 0) followed by the encoded field lines.
    ///
    /// - Parameter headers: An array of (name, value) tuples representing
    ///   the header fields. Names should be lowercase per HTTP/3 convention.
    ///   Pseudo-headers (`:method`, `:path`, etc.) MUST appear before
    ///   regular headers.
    /// - Returns: The QPACK-encoded field section bytes
    ///
    /// ## Example
    ///
    /// ```swift
    /// let encoder = QPACKEncoder()
    /// let data = encoder.encode([
    ///     (":method", "GET"),
    ///     (":path", "/index.html"),
    ///     ("user-agent", "quiver/1.0"),
    /// ])
    /// ```
    public func encode(_ headers: [(name: String, value: String)]) -> Data {
        var result = Data()
        // Estimate capacity: prefix (2 bytes) + ~20 bytes per header
        result.reserveCapacity(2 + headers.count * 20)

        // === Encoded Field Section Prefix (RFC 9204 Section 4.5) ===
        //
        // Required Insert Count = 0 (no dynamic table references)
        // Encoded as a QPACK integer with 8-bit prefix → single byte 0x00
        result.append(0x00)

        // Delta Base = 0, S bit = 0 (no dynamic table)
        // Encoded as S(1 bit) + Delta Base with 7-bit prefix → single byte 0x00
        result.append(0x00)

        // === Encoded Field Lines ===
        for header in headers {
            encodeFieldLine(name: header.name, value: header.value, into: &result)
        }

        return result
    }

    /// Encodes a list of header fields provided as `HTTPField` values.
    ///
    /// Convenience overload that accepts `HTTPField` structs.
    ///
    /// - Parameter fields: The header fields to encode
    /// - Returns: The QPACK-encoded field section bytes
    public func encode(_ fields: [HTTPField]) -> Data {
        return encode(fields.map { ($0.name, $0.value) })
    }

    // MARK: - Field Line Encoding

    /// Encodes a single header field line into the output buffer.
    ///
    /// Strategy:
    /// 1. Try exact (name+value) match in static table → Indexed Field Line
    /// 2. Try name-only match in static table → Literal With Name Reference
    /// 3. Fall back to Literal With Literal Name
    ///
    /// - Parameters:
    ///   - name: The header field name (should be lowercase)
    ///   - value: The header field value
    ///   - result: The output buffer to append to
    private func encodeFieldLine(name: String, value: String, into result: inout Data) {
        let lowercaseName = name.lowercased()

        // Strategy 1: Try exact match → Indexed Field Line (static)
        if let match = QPACKStaticTable.findBestMatch(name: lowercaseName, value: value) {
            if match.isExactMatch {
                encodeIndexedFieldLine(index: match.index, into: &result)
                return
            }

            // Strategy 2: Name-only match → Literal With Name Reference (static)
            encodeLiteralWithNameReference(
                nameIndex: match.index,
                value: value,
                neverIndex: isSensitiveHeader(lowercaseName),
                into: &result
            )
            return
        }

        // Strategy 3: No match → Literal With Literal Name
        encodeLiteralWithLiteralName(
            name: lowercaseName,
            value: value,
            neverIndex: isSensitiveHeader(lowercaseName),
            into: &result
        )
    }

    /// Encodes an Indexed Field Line (RFC 9204 Section 4.5.2).
    ///
    /// ```
    ///   0   1   2   3   4   5   6   7
    /// +---+---+---+---+---+---+---+---+
    /// | 1 | T |      Index (6+)       |
    /// +---+---+-----------------------+
    /// ```
    ///
    /// - T=1: Reference to the static table
    /// - Index: The static table index
    ///
    /// - Parameters:
    ///   - index: The static table index
    ///   - result: The output buffer
    private func encodeIndexedFieldLine(index: Int, into result: inout Data) {
        // First byte: 1 (indexed) | 1 (static table) | Index (6-bit prefix)
        // Bit pattern: 11xxxxxx
        let firstByte: UInt8 = 0xc0  // 1 | T=1
        let encoded = QPACKInteger.encode(UInt64(index), prefix: 6, firstByte: firstByte)
        result.append(encoded)
    }

    /// Encodes a Literal Field Line With Name Reference (RFC 9204 Section 4.5.4).
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
    /// - N=1: Never index (for sensitive headers)
    /// - T=1: Reference to static table
    /// - Name Index: The static table index for the name
    ///
    /// - Parameters:
    ///   - nameIndex: The static table index for the header name
    ///   - value: The header field value
    ///   - neverIndex: Whether this field should never be indexed
    ///   - result: The output buffer
    private func encodeLiteralWithNameReference(
        nameIndex: Int,
        value: String,
        neverIndex: Bool,
        into result: inout Data
    ) {
        // First byte: 01 | N | T=1 | Name Index (4-bit prefix)
        // Bit pattern: 01NT xxxx
        var firstByte: UInt8 = 0x50  // 0101 0000 = 01 | N=0 | T=1
        if neverIndex {
            firstByte = 0x70  // 0111 0000 = 01 | N=1 | T=1
        }

        let nameEncoded = QPACKInteger.encode(UInt64(nameIndex), prefix: 4, firstByte: firstByte)
        result.append(nameEncoded)

        // Encode the value as a string literal (raw, no Huffman)
        let valueEncoded = QPACKString.encode(value)
        result.append(valueEncoded)
    }

    /// Encodes a Literal Field Line With Literal Name (RFC 9204 Section 4.5.6).
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
    /// - N=1: Never index (for sensitive headers)
    /// - H: Huffman encoding flag (we use H=0 for raw encoding)
    ///
    /// - Parameters:
    ///   - name: The header field name
    ///   - value: The header field value
    ///   - neverIndex: Whether this field should never be indexed
    ///   - result: The output buffer
    private func encodeLiteralWithLiteralName(
        name: String,
        value: String,
        neverIndex: Bool,
        into result: inout Data
    ) {
        let nameBytes = Data(name.utf8)

        // First byte: 001 | N | H=0 | Name Length (3-bit prefix)
        // Bit pattern: 001N 0xxx
        var firstByte: UInt8 = 0x20  // 0010 0000 = 001 | N=0 | H=0
        if neverIndex {
            firstByte = 0x30  // 0011 0000 = 001 | N=1 | H=0
        }

        let nameLengthEncoded = QPACKInteger.encode(
            UInt64(nameBytes.count),
            prefix: 3,
            firstByte: firstByte
        )
        result.append(nameLengthEncoded)
        result.append(nameBytes)

        // Encode the value as a string literal (raw, no Huffman)
        let valueEncoded = QPACKString.encode(value)
        result.append(valueEncoded)
    }

    // MARK: - Sensitivity Detection

    /// Determines whether a header field should be marked as "never index".
    ///
    /// Sensitive headers contain values that should not be compressed or
    /// stored in any table to prevent security issues like CRIME/BREACH attacks.
    ///
    /// - Parameter name: The lowercase header field name
    /// - Returns: `true` if the header is sensitive
    private func isSensitiveHeader(_ name: String) -> Bool {
        switch name {
        case "authorization",
             "cookie",
             "set-cookie",
             "proxy-authorization":
            return true
        default:
            return false
        }
    }
}

// MARK: - HTTP Field Helper Type

/// A simple HTTP header field representation.
///
/// Used as a convenience type for QPACK encoding/decoding.
public struct HTTPField: Sendable, Hashable {
    /// The header field name (lowercase for HTTP/3)
    public let name: String

    /// The header field value
    public let value: String

    /// Creates an HTTP header field.
    ///
    /// - Parameters:
    ///   - name: The field name (will be stored as-is; caller should lowercase for HTTP/3)
    ///   - value: The field value
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

extension HTTPField: CustomStringConvertible {
    public var description: String {
        "\(name): \(value)"
    }
}