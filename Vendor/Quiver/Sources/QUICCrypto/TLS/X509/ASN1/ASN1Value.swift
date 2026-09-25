/// ASN.1 Value Types
///
/// Represents parsed ASN.1 DER values.

import Foundation

// MARK: - ASN.1 Value

/// Represents a parsed ASN.1 TLV (Tag-Length-Value)
public struct ASN1Value: Sendable {
    /// The tag identifying the type
    public let tag: ASN1Tag

    /// The raw content bytes (value portion)
    public let content: Data

    /// Child values for constructed types
    public let children: [ASN1Value]

    /// Original raw bytes including tag and length
    public let rawBytes: Data

    // MARK: - Initialization

    /// Creates an ASN.1 value for primitive types
    public init(tag: ASN1Tag, content: Data, rawBytes: Data) {
        self.tag = tag
        self.content = content
        self.children = []
        self.rawBytes = rawBytes
    }

    /// Creates an ASN.1 value for constructed types
    public init(tag: ASN1Tag, children: [ASN1Value], rawBytes: Data) {
        self.tag = tag
        self.content = Data()
        self.children = children
        self.rawBytes = rawBytes
    }

    // MARK: - Content Accessors

    /// Interprets content as an unsigned integer
    public func asInteger() throws -> [UInt8] {
        guard tag.isInteger else {
            throw ASN1Error.typeMismatch(expected: "INTEGER", actual: tag.description)
        }
        return Array(content)
    }

    /// Interprets content as a positive BigInt (removes leading zero if present)
    public func asPositiveInteger() throws -> Data {
        guard tag.isInteger else {
            throw ASN1Error.typeMismatch(expected: "INTEGER", actual: tag.description)
        }
        // Skip leading zero byte used for positive number representation
        if content.count > 1 && content[0] == 0x00 {
            return content.dropFirst()
        }
        return content
    }

    /// Interprets content as a boolean
    public func asBoolean() throws -> Bool {
        guard tag.universalTag == .boolean else {
            throw ASN1Error.typeMismatch(expected: "BOOLEAN", actual: tag.description)
        }
        guard content.count == 1 else {
            throw ASN1Error.invalidFormat("BOOLEAN must be 1 byte")
        }
        // DER: false = 0x00, true = 0xFF (but accept any non-zero)
        return content[0] != 0x00
    }

    /// Interprets content as an object identifier
    public func asObjectIdentifier() throws -> OID {
        guard tag.isObjectIdentifier else {
            throw ASN1Error.typeMismatch(expected: "OBJECT IDENTIFIER", actual: tag.description)
        }
        return try OID(derEncoded: content)
    }

    /// Interprets content as a bit string, returning (unused bits, data)
    public func asBitString() throws -> (unusedBits: UInt8, data: Data) {
        guard tag.isBitString else {
            throw ASN1Error.typeMismatch(expected: "BIT STRING", actual: tag.description)
        }
        guard content.count >= 1 else {
            throw ASN1Error.invalidFormat("BIT STRING must have at least 1 byte")
        }
        let unusedBits = content[0]
        guard unusedBits <= 7 else {
            throw ASN1Error.invalidFormat("Invalid unused bits in BIT STRING: \(unusedBits)")
        }
        return (unusedBits, content.dropFirst())
    }

    /// Interprets content as an octet string
    public func asOctetString() throws -> Data {
        guard tag.isOctetString else {
            throw ASN1Error.typeMismatch(expected: "OCTET STRING", actual: tag.description)
        }
        return content
    }

    /// Interprets content as a UTF-8 string
    public func asString() throws -> String {
        // Accept various string types
        guard let univTag = tag.universalTag else {
            throw ASN1Error.typeMismatch(expected: "STRING", actual: tag.description)
        }

        switch univTag {
        case .utf8String, .printableString, .ia5String, .visibleString:
            guard let str = String(data: content, encoding: .utf8) else {
                throw ASN1Error.invalidFormat("Invalid UTF-8 encoding")
            }
            return str
        case .t61String:
            // T61 is often used with Latin-1 encoding
            guard let str = String(data: content, encoding: .isoLatin1) else {
                throw ASN1Error.invalidFormat("Invalid Latin-1 encoding")
            }
            return str
        case .bmpString:
            // BMP uses UTF-16BE
            guard let str = String(data: content, encoding: .utf16BigEndian) else {
                throw ASN1Error.invalidFormat("Invalid UTF-16BE encoding")
            }
            return str
        default:
            throw ASN1Error.typeMismatch(expected: "STRING", actual: tag.description)
        }
    }

    /// Interprets content as UTC Time
    public func asUTCTime() throws -> Date {
        guard tag.universalTag == .utcTime else {
            throw ASN1Error.typeMismatch(expected: "UTCTime", actual: tag.description)
        }
        guard let str = String(data: content, encoding: .ascii) else {
            throw ASN1Error.invalidFormat("Invalid ASCII in UTCTime")
        }
        return try parseUTCTime(str)
    }

    /// Interprets content as Generalized Time
    public func asGeneralizedTime() throws -> Date {
        guard tag.universalTag == .generalizedTime else {
            throw ASN1Error.typeMismatch(expected: "GeneralizedTime", actual: tag.description)
        }
        guard let str = String(data: content, encoding: .ascii) else {
            throw ASN1Error.invalidFormat("Invalid ASCII in GeneralizedTime")
        }
        return try parseGeneralizedTime(str)
    }

    /// Interprets content as either UTC Time or Generalized Time
    public func asTime() throws -> Date {
        guard let univTag = tag.universalTag else {
            throw ASN1Error.typeMismatch(expected: "TIME", actual: tag.description)
        }
        switch univTag {
        case .utcTime:
            return try asUTCTime()
        case .generalizedTime:
            return try asGeneralizedTime()
        default:
            throw ASN1Error.typeMismatch(expected: "TIME", actual: tag.description)
        }
    }

    // MARK: - Navigation

    /// Gets child at index (for SEQUENCE/SET)
    public func child(at index: Int) throws -> ASN1Value {
        guard index >= 0 && index < children.count else {
            throw ASN1Error.indexOutOfBounds(index: index, count: children.count)
        }
        return children[index]
    }

    /// Gets optional child at index
    public func optionalChild(at index: Int) -> ASN1Value? {
        guard index >= 0 && index < children.count else {
            return nil
        }
        return children[index]
    }

    /// Finds first child with matching tag
    public func firstChild(withTag tag: ASN1Tag) -> ASN1Value? {
        children.first { $0.tag == tag }
    }

    /// Finds first child with context-specific tag number
    public func firstChild(withContextTag number: UInt) -> ASN1Value? {
        children.first { $0.tag.tagClass == .contextSpecific && $0.tag.tagNumber == number }
    }

    // MARK: - Time Parsing

    private func parseUTCTime(_ str: String) throws -> Date {
        // Format: YYMMDDhhmmssZ or YYMMDDhhmmss+hhmm
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")

        // Try with seconds
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        if let date = formatter.date(from: str) {
            return date
        }

        // Try without seconds
        formatter.dateFormat = "yyMMddHHmm'Z'"
        if let date = formatter.date(from: str) {
            return date
        }

        throw ASN1Error.invalidFormat("Invalid UTCTime format: \(str)")
    }

    private func parseGeneralizedTime(_ str: String) throws -> Date {
        // Format: YYYYMMDDhhmmssZ or YYYYMMDDhhmmss.fffZ
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")

        // Try with fractional seconds
        formatter.dateFormat = "yyyyMMddHHmmss.SSS'Z'"
        if let date = formatter.date(from: str) {
            return date
        }

        // Try without fractional seconds
        formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        if let date = formatter.date(from: str) {
            return date
        }

        throw ASN1Error.invalidFormat("Invalid GeneralizedTime format: \(str)")
    }
}

// MARK: - Object Identifier

/// ASN.1 Object Identifier (OID)
public struct OID: Sendable, Equatable, Hashable {
    /// The OID components
    public let components: [UInt]

    /// String representation (dot notation)
    public var dotNotation: String {
        components.map(String.init).joined(separator: ".")
    }

    // MARK: - Initialization

    /// Creates an OID from components
    public init(components: [UInt]) {
        self.components = components
    }

    /// Creates an OID from dot notation string
    public init(_ dotNotation: String) throws {
        let parts = dotNotation.split(separator: ".")
        guard parts.count >= 2 else {
            throw ASN1Error.invalidFormat("OID must have at least 2 components")
        }

        var comps: [UInt] = []
        for part in parts {
            guard let num = UInt(part) else {
                throw ASN1Error.invalidFormat("Invalid OID component: \(part)")
            }
            comps.append(num)
        }
        self.components = comps
    }

    /// Creates an OID from DER-encoded bytes
    public init(derEncoded data: Data) throws {
        guard data.count >= 1 else {
            throw ASN1Error.invalidFormat("OID must have at least 1 byte")
        }

        var comps: [UInt] = []

        // First byte encodes first two components: first * 40 + second
        let firstByte = data[0]
        comps.append(UInt(firstByte / 40))
        comps.append(UInt(firstByte % 40))

        // Remaining bytes are variable-length encoded
        var value: UInt = 0
        var index = 1
        while index < data.count {
            let byte = data[index]
            value = (value << 7) | UInt(byte & 0x7F)
            if byte & 0x80 == 0 {
                comps.append(value)
                value = 0
            }
            index += 1
        }

        self.components = comps
    }

    /// Encodes this OID to DER format
    public func derEncode() -> Data {
        guard components.count >= 2 else {
            return Data()
        }

        var result = Data()

        // First byte: first * 40 + second
        result.append(UInt8(components[0] * 40 + components[1]))

        // Remaining components use variable-length encoding
        for i in 2..<components.count {
            let comp = components[i]
            if comp < 128 {
                result.append(UInt8(comp))
            } else {
                // Multi-byte encoding
                var bytes: [UInt8] = []
                var val = comp
                bytes.append(UInt8(val & 0x7F))
                val >>= 7
                while val > 0 {
                    bytes.append(UInt8((val & 0x7F) | 0x80))
                    val >>= 7
                }
                result.append(contentsOf: bytes.reversed())
            }
        }

        return result
    }
}

// MARK: - CustomStringConvertible

extension OID: CustomStringConvertible {
    public var description: String {
        // Return known OID name if available, otherwise dot notation
        if let known = KnownOID(rawValue: dotNotation) {
            return "\(known.name) (\(dotNotation))"
        }
        return dotNotation
    }
}

// MARK: - Known OIDs

/// Well-known OIDs used in X.509 certificates
public enum KnownOID: String, Sendable {
    // Signature algorithms
    case sha256WithRSAEncryption = "1.2.840.113549.1.1.11"
    case sha384WithRSAEncryption = "1.2.840.113549.1.1.12"
    case sha512WithRSAEncryption = "1.2.840.113549.1.1.13"
    case ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    case ecdsaWithSHA384 = "1.2.840.10045.4.3.3"
    case ecdsaWithSHA512 = "1.2.840.10045.4.3.4"
    case ed25519 = "1.3.101.112"

    // Public key algorithms
    case rsaEncryption = "1.2.840.113549.1.1.1"
    case ecPublicKey = "1.2.840.10045.2.1"
    case x25519 = "1.3.101.110"

    // Elliptic curves
    case secp256r1 = "1.2.840.10045.3.1.7"
    case secp384r1 = "1.3.132.0.34"
    case secp521r1 = "1.3.132.0.35"

    // X.509 extensions
    case basicConstraints = "2.5.29.19"
    case keyUsage = "2.5.29.15"
    case extKeyUsage = "2.5.29.37"
    case subjectAltName = "2.5.29.17"
    case issuerAltName = "2.5.29.18"
    case authorityKeyIdentifier = "2.5.29.35"
    case subjectKeyIdentifier = "2.5.29.14"
    case nameConstraints = "2.5.29.30"
    case certificatePolicies = "2.5.29.32"
    case crlDistributionPoints = "2.5.29.31"
    case authorityInfoAccess = "1.3.6.1.5.5.7.1.1"

    // X.500 attribute types
    case commonName = "2.5.4.3"
    case surname = "2.5.4.4"
    case serialNumber = "2.5.4.5"
    case countryName = "2.5.4.6"
    case localityName = "2.5.4.7"
    case stateOrProvinceName = "2.5.4.8"
    case organizationName = "2.5.4.10"
    case organizationalUnitName = "2.5.4.11"
    case emailAddress = "1.2.840.113549.1.9.1"

    /// Human-readable name
    public var name: String {
        switch self {
        case .sha256WithRSAEncryption: return "sha256WithRSAEncryption"
        case .sha384WithRSAEncryption: return "sha384WithRSAEncryption"
        case .sha512WithRSAEncryption: return "sha512WithRSAEncryption"
        case .ecdsaWithSHA256: return "ecdsa-with-SHA256"
        case .ecdsaWithSHA384: return "ecdsa-with-SHA384"
        case .ecdsaWithSHA512: return "ecdsa-with-SHA512"
        case .ed25519: return "Ed25519"
        case .rsaEncryption: return "rsaEncryption"
        case .ecPublicKey: return "ecPublicKey"
        case .x25519: return "X25519"
        case .secp256r1: return "secp256r1 (P-256)"
        case .secp384r1: return "secp384r1 (P-384)"
        case .secp521r1: return "secp521r1 (P-521)"
        case .basicConstraints: return "basicConstraints"
        case .keyUsage: return "keyUsage"
        case .extKeyUsage: return "extKeyUsage"
        case .subjectAltName: return "subjectAltName"
        case .issuerAltName: return "issuerAltName"
        case .authorityKeyIdentifier: return "authorityKeyIdentifier"
        case .subjectKeyIdentifier: return "subjectKeyIdentifier"
        case .nameConstraints: return "nameConstraints"
        case .certificatePolicies: return "certificatePolicies"
        case .crlDistributionPoints: return "crlDistributionPoints"
        case .authorityInfoAccess: return "authorityInfoAccess"
        case .commonName: return "commonName"
        case .surname: return "surname"
        case .serialNumber: return "serialNumber"
        case .countryName: return "countryName"
        case .localityName: return "localityName"
        case .stateOrProvinceName: return "stateOrProvinceName"
        case .organizationName: return "organizationName"
        case .organizationalUnitName: return "organizationalUnitName"
        case .emailAddress: return "emailAddress"
        }
    }

    /// Creates a KnownOID from an OID
    public init?(oid: OID) {
        self.init(rawValue: oid.dotNotation)
    }
}

// MARK: - ASN.1 Errors

/// Errors that can occur during ASN.1 parsing
public enum ASN1Error: Error, Sendable {
    /// Unexpected end of data
    case unexpectedEndOfData
    /// Invalid tag encoding
    case invalidTag(String)
    /// Invalid length encoding
    case invalidLength(String)
    /// Invalid data format
    case invalidFormat(String)
    /// Type mismatch
    case typeMismatch(expected: String, actual: String)
    /// Index out of bounds
    case indexOutOfBounds(index: Int, count: Int)
    /// Unsupported feature
    case unsupported(String)
}
