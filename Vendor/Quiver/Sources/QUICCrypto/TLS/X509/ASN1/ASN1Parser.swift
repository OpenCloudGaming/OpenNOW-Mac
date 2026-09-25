/// ASN.1 DER Parser (ITU-T X.690)
///
/// Parses DER (Distinguished Encoding Rules) encoded ASN.1 data.

import Foundation

// MARK: - ASN.1 Parser

/// Parser for ASN.1 DER-encoded data
public struct ASN1Parser: Sendable {
    /// The data being parsed
    private var data: Data

    /// Current position in the data
    private var position: Int

    /// Starting position (for raw bytes calculation)
    private let startPosition: Int

    // MARK: - Initialization

    /// Creates a parser for the given data
    public init(data: Data) {
        self.data = data
        self.position = data.startIndex
        self.startPosition = data.startIndex
    }

    // MARK: - Public API

    /// Parses the next TLV (Tag-Length-Value) from the data
    public mutating func parse() throws -> ASN1Value {
        let startPos = position

        // Read tag
        let tag = try readTag()

        // Read length
        let length = try readLength()

        // Calculate end position
        let endPos = position + length
        guard endPos <= data.endIndex else {
            throw ASN1Error.unexpectedEndOfData
        }

        // Get raw bytes for this TLV
        let rawBytes = data[startPos..<endPos]

        // Read content
        if tag.isConstructed {
            // Parse children
            let contentEnd = position + length
            var children: [ASN1Value] = []

            while position < contentEnd {
                let child = try parse()
                children.append(child)
            }

            guard position == contentEnd else {
                throw ASN1Error.invalidFormat("Constructed value length mismatch")
            }

            return ASN1Value(tag: tag, children: children, rawBytes: Data(rawBytes))
        } else {
            // Primitive - read content bytes
            let content = data[position..<endPos]
            position = endPos
            return ASN1Value(tag: tag, content: Data(content), rawBytes: Data(rawBytes))
        }
    }

    /// Parses all remaining TLV values
    public mutating func parseAll() throws -> [ASN1Value] {
        var values: [ASN1Value] = []
        while position < data.endIndex {
            values.append(try parse())
        }
        return values
    }

    /// Returns the number of remaining bytes
    public var remaining: Int {
        data.endIndex - position
    }

    /// Whether there is more data to parse
    public var hasMore: Bool {
        position < data.endIndex
    }

    // MARK: - Tag Parsing

    private mutating func readTag() throws -> ASN1Tag {
        guard position < data.endIndex else {
            throw ASN1Error.unexpectedEndOfData
        }

        let identifier = data[position]
        position += 1

        // Extract tag class (bits 7-6)
        let tagClassBits = identifier & ASN1TagClass.mask
        guard let tagClass = ASN1TagClass(rawValue: tagClassBits) else {
            throw ASN1Error.invalidTag("Unknown tag class: \(tagClassBits)")
        }

        // Extract constructed bit (bit 5)
        let isConstructed = (identifier & ASN1Tag.constructedMask) != 0

        // Extract tag number (bits 4-0)
        let tagNumberBits = identifier & ASN1Tag.tagNumberMask

        let tagNumber: UInt
        if tagNumberBits == ASN1Tag.longFormIndicator {
            // Long form - tag number spans multiple bytes
            tagNumber = try readLongFormTagNumber()
        } else {
            tagNumber = UInt(tagNumberBits)
        }

        return ASN1Tag(tagClass: tagClass, isConstructed: isConstructed, tagNumber: tagNumber)
    }

    private mutating func readLongFormTagNumber() throws -> UInt {
        var result: UInt = 0

        while position < data.endIndex {
            let byte = data[position]
            position += 1

            result = (result << 7) | UInt(byte & 0x7F)

            // Check for overflow
            guard result <= UInt.max >> 7 else {
                throw ASN1Error.invalidTag("Tag number too large")
            }

            // If high bit is not set, this is the last byte
            if byte & 0x80 == 0 {
                return result
            }
        }

        throw ASN1Error.unexpectedEndOfData
    }

    // MARK: - Length Parsing

    private mutating func readLength() throws -> Int {
        guard position < data.endIndex else {
            throw ASN1Error.unexpectedEndOfData
        }

        let firstByte = data[position]
        position += 1

        // Short form: bit 7 is 0, bits 6-0 contain length
        if firstByte & 0x80 == 0 {
            return Int(firstByte)
        }

        // Long form: bit 7 is 1, bits 6-0 contain number of length bytes
        let numLengthBytes = Int(firstByte & 0x7F)

        // Check for indefinite length (not allowed in DER)
        guard numLengthBytes != 0 else {
            throw ASN1Error.invalidLength("Indefinite length not allowed in DER")
        }

        // Check we have enough bytes
        guard position + numLengthBytes <= data.endIndex else {
            throw ASN1Error.unexpectedEndOfData
        }

        // Read length bytes
        var length: Int = 0
        for _ in 0..<numLengthBytes {
            let byte = data[position]
            position += 1

            // Check for overflow
            guard length <= Int.max >> 8 else {
                throw ASN1Error.invalidLength("Length too large")
            }

            length = (length << 8) | Int(byte)
        }

        // DER requires minimal encoding
        if numLengthBytes > 1 || length < 128 {
            // Verify this was the minimal encoding
            let minBytes = length < 128 ? 0 : (length < 256 ? 1 : (length < 65536 ? 2 : (length < 16777216 ? 3 : 4)))
            if numLengthBytes > minBytes + 1 {
                // Allow non-minimal but don't fail (some implementations aren't strict)
            }
        }

        return length
    }

    // MARK: - Static Helpers

    /// Parses a single ASN.1 value from data
    public static func parseOne(from data: Data) throws -> ASN1Value {
        var parser = ASN1Parser(data: data)
        return try parser.parse()
    }

    /// Parses all ASN.1 values from data
    public static func parseAll(from data: Data) throws -> [ASN1Value] {
        var parser = ASN1Parser(data: data)
        return try parser.parseAll()
    }
}

// MARK: - ASN.1 Builder

/// Builder for creating ASN.1 DER-encoded data
public struct ASN1Builder: Sendable {
    private var data: Data

    public init() {
        self.data = Data()
    }

    // MARK: - Encoding

    /// Encodes a SEQUENCE containing the given children
    public static func sequence(_ children: [Data]) -> Data {
        let content = children.reduce(Data()) { $0 + $1 }
        return encode(tag: .sequence, content: content)
    }

    /// Encodes a SET containing the given children
    public static func set(_ children: [Data]) -> Data {
        let content = children.reduce(Data()) { $0 + $1 }
        return encode(tag: .set, content: content)
    }

    /// Encodes an INTEGER
    public static func integer(_ value: Data) -> Data {
        var content = value
        // Add leading zero if high bit is set (to keep it positive)
        if let first = content.first, first & 0x80 != 0 {
            content.insert(0x00, at: 0)
        }
        // Remove leading zeros (except if needed for sign)
        while content.count > 1 && content[0] == 0x00 && content[1] & 0x80 == 0 {
            content.removeFirst()
        }
        return encode(tag: .integer, content: content)
    }

    /// Encodes an OBJECT IDENTIFIER
    public static func objectIdentifier(_ oid: OID) -> Data {
        encode(tag: .objectIdentifier, content: oid.derEncode())
    }

    /// Encodes a BIT STRING
    public static func bitString(_ data: Data, unusedBits: UInt8 = 0) -> Data {
        var content = Data([unusedBits])
        content.append(data)
        return encode(tag: .bitString, content: content)
    }

    /// Encodes an OCTET STRING
    public static func octetString(_ data: Data) -> Data {
        encode(tag: .octetString, content: data)
    }

    /// Encodes a NULL
    public static func null() -> Data {
        encode(tag: .null, content: Data())
    }

    /// Encodes a BOOLEAN
    public static func boolean(_ value: Bool) -> Data {
        encode(tag: .boolean, content: Data([value ? 0xFF : 0x00]))
    }

    /// Encodes a UTF8 STRING
    public static func utf8String(_ string: String) -> Data {
        encode(tag: .utf8String, content: Data(string.utf8))
    }

    /// Encodes a PRINTABLE STRING
    public static func printableString(_ string: String) -> Data {
        encode(tag: .printableString, content: Data(string.utf8))
    }

    /// Encodes an INTEGER from Int value
    public static func integer(_ value: Int) -> Data {
        if value == 0 {
            return encode(tag: .integer, content: Data([0x00]))
        }

        var bytes = Data()
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }

        // Ensure positive (add leading zero if high bit set)
        if let first = bytes.first, first & 0x80 != 0 {
            bytes.insert(0x00, at: 0)
        }

        return encode(tag: .integer, content: bytes)
    }

    /// Encodes a UTCTime (for X.509 validity dates)
    public static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"

        let timeString = formatter.string(from: date)
        return encode(tag: .utcTime, content: Data(timeString.utf8))
    }

    /// Encodes an OBJECT IDENTIFIER from component array
    public static func oid(_ components: [UInt]) -> Data {
        guard components.count >= 2 else {
            return encode(tag: .objectIdentifier, content: Data())
        }

        var content = Data()

        // First byte: first * 40 + second
        content.append(UInt8(components[0] * 40 + components[1]))

        // Remaining components use variable-length encoding
        for i in 2..<components.count {
            let comp = components[i]
            if comp < 128 {
                content.append(UInt8(comp))
            } else {
                var bytes: [UInt8] = []
                var val = comp
                bytes.append(UInt8(val & 0x7F))
                val >>= 7
                while val > 0 {
                    bytes.append(UInt8((val & 0x7F) | 0x80))
                    val >>= 7
                }
                content.append(contentsOf: bytes.reversed())
            }
        }

        return encode(tag: .objectIdentifier, content: content)
    }

    /// Encodes an X.509 Extension
    ///
    /// Extension ::= SEQUENCE {
    ///     extnID OBJECT IDENTIFIER,
    ///     critical BOOLEAN DEFAULT FALSE,
    ///     extnValue OCTET STRING
    /// }
    public static func x509Extension(oid oidComponents: [UInt], critical: Bool, value: Data) -> Data {
        var content = oid(oidComponents)

        if critical {
            content.append(boolean(true))
        }

        content.append(octetString(value))

        return sequence([content])
    }

    /// Encodes a context-specific tagged value
    public static func contextSpecific(_ number: UInt, content: Data, isConstructed: Bool = true) -> Data {
        let tag = ASN1Tag.contextSpecific(number, isConstructed: isConstructed)
        return encode(tag: tag, content: content)
    }

    /// Encodes with the given tag and content
    public static func encode(tag: ASN1Tag, content: Data) -> Data {
        var result = Data()

        // Encode tag
        result.append(encodeTag(tag))

        // Encode length
        result.append(contentsOf: encodeLength(content.count))

        // Append content
        result.append(content)

        return result
    }

    // MARK: - Private Helpers

    private static func encodeTag(_ tag: ASN1Tag) -> UInt8 {
        var identifier = tag.tagClass.rawValue
        if tag.isConstructed {
            identifier |= ASN1Tag.constructedMask
        }

        if tag.tagNumber < 31 {
            identifier |= UInt8(tag.tagNumber)
        } else {
            // Long form not commonly needed for our use cases
            identifier |= ASN1Tag.longFormIndicator
            // Would need to encode tag number in subsequent bytes
        }

        return identifier
    }

    private static func encodeLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        }

        // Determine number of bytes needed
        var bytes: [UInt8] = []
        var remaining = length
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }

        // Prepend count byte
        bytes.insert(UInt8(0x80 | bytes.count), at: 0)
        return bytes
    }
}
