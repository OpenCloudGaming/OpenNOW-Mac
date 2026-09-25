/// ASN.1 Tag Types (ITU-T X.680, X.690)
///
/// Defines ASN.1 tag classes and universal tag numbers used in DER encoding.

import Foundation

// MARK: - Tag Class

/// ASN.1 Tag Class (bits 7-6 of the identifier octet)
public enum ASN1TagClass: UInt8, Sendable {
    /// Universal - types defined in X.680
    case universal = 0x00
    /// Application - application-wide types
    case application = 0x40
    /// Context-specific - context-dependent types
    case contextSpecific = 0x80
    /// Private - private use types
    case `private` = 0xC0

    /// Mask for extracting tag class from identifier octet
    public static let mask: UInt8 = 0xC0
}

// MARK: - Universal Tags

/// ASN.1 Universal Tag Numbers (X.680 Section 8.4)
public enum ASN1UniversalTag: UInt8, Sendable {
    /// End-of-contents octets
    case endOfContent = 0x00
    /// Boolean value
    case boolean = 0x01
    /// Integer value
    case integer = 0x02
    /// Bit string
    case bitString = 0x03
    /// Octet string
    case octetString = 0x04
    /// Null value
    case null = 0x05
    /// Object identifier
    case objectIdentifier = 0x06
    /// Object descriptor
    case objectDescriptor = 0x07
    /// External type
    case external = 0x08
    /// Real (floating point)
    case real = 0x09
    /// Enumerated type
    case enumerated = 0x0A
    /// Embedded PDV
    case embeddedPDV = 0x0B
    /// UTF-8 string
    case utf8String = 0x0C
    /// Relative OID
    case relativeOID = 0x0D
    /// Time value
    case time = 0x0E
    /// Reserved
    case reserved = 0x0F
    /// Sequence (ordered collection)
    case sequence = 0x10
    /// Set (unordered collection)
    case set = 0x11
    /// Numeric string
    case numericString = 0x12
    /// Printable string
    case printableString = 0x13
    /// T61 (Teletex) string
    case t61String = 0x14
    /// Videotex string
    case videotexString = 0x15
    /// IA5 (ASCII) string
    case ia5String = 0x16
    /// UTC time
    case utcTime = 0x17
    /// Generalized time
    case generalizedTime = 0x18
    /// Graphic string
    case graphicString = 0x19
    /// Visible string
    case visibleString = 0x1A
    /// General string
    case generalString = 0x1B
    /// Universal string
    case universalString = 0x1C
    /// Character string
    case characterString = 0x1D
    /// BMP (Basic Multilingual Plane) string
    case bmpString = 0x1E

    /// Human-readable description
    public var description: String {
        switch self {
        case .endOfContent: return "END-OF-CONTENT"
        case .boolean: return "BOOLEAN"
        case .integer: return "INTEGER"
        case .bitString: return "BIT STRING"
        case .octetString: return "OCTET STRING"
        case .null: return "NULL"
        case .objectIdentifier: return "OBJECT IDENTIFIER"
        case .objectDescriptor: return "ObjectDescriptor"
        case .external: return "EXTERNAL"
        case .real: return "REAL"
        case .enumerated: return "ENUMERATED"
        case .embeddedPDV: return "EMBEDDED PDV"
        case .utf8String: return "UTF8String"
        case .relativeOID: return "RELATIVE-OID"
        case .time: return "TIME"
        case .reserved: return "RESERVED"
        case .sequence: return "SEQUENCE"
        case .set: return "SET"
        case .numericString: return "NumericString"
        case .printableString: return "PrintableString"
        case .t61String: return "T61String"
        case .videotexString: return "VideotexString"
        case .ia5String: return "IA5String"
        case .utcTime: return "UTCTime"
        case .generalizedTime: return "GeneralizedTime"
        case .graphicString: return "GraphicString"
        case .visibleString: return "VisibleString"
        case .generalString: return "GeneralString"
        case .universalString: return "UniversalString"
        case .characterString: return "CHARACTER STRING"
        case .bmpString: return "BMPString"
        }
    }
}

// MARK: - ASN.1 Tag

/// Represents a complete ASN.1 tag (identifier octet)
public struct ASN1Tag: Sendable, Equatable {
    /// Tag class
    public let tagClass: ASN1TagClass

    /// Whether this is a constructed (vs primitive) type
    public let isConstructed: Bool

    /// Tag number
    public let tagNumber: UInt

    /// Mask for constructed bit (bit 5)
    public static let constructedMask: UInt8 = 0x20

    /// Mask for tag number in short form
    public static let tagNumberMask: UInt8 = 0x1F

    /// Value indicating long form tag number
    public static let longFormIndicator: UInt8 = 0x1F

    // MARK: - Initialization

    /// Creates an ASN.1 tag
    public init(tagClass: ASN1TagClass, isConstructed: Bool, tagNumber: UInt) {
        self.tagClass = tagClass
        self.isConstructed = isConstructed
        self.tagNumber = tagNumber
    }

    /// Creates a universal tag
    public init(universal: ASN1UniversalTag, isConstructed: Bool = false) {
        self.tagClass = .universal
        self.isConstructed = isConstructed
        self.tagNumber = UInt(universal.rawValue)
    }

    /// Creates a context-specific tag
    public static func contextSpecific(_ number: UInt, isConstructed: Bool = true) -> ASN1Tag {
        ASN1Tag(tagClass: .contextSpecific, isConstructed: isConstructed, tagNumber: number)
    }

    // MARK: - Universal Tag Helpers

    /// Universal tag if this is a universal class tag
    public var universalTag: ASN1UniversalTag? {
        guard tagClass == .universal, tagNumber <= UInt8.max else { return nil }
        return ASN1UniversalTag(rawValue: UInt8(tagNumber))
    }

    /// Whether this is a SEQUENCE tag
    public var isSequence: Bool {
        tagClass == .universal && tagNumber == ASN1UniversalTag.sequence.rawValue
    }

    /// Whether this is a SET tag
    public var isSet: Bool {
        tagClass == .universal && tagNumber == ASN1UniversalTag.set.rawValue
    }

    /// Whether this is an INTEGER tag
    public var isInteger: Bool {
        tagClass == .universal && tagNumber == ASN1UniversalTag.integer.rawValue
    }

    /// Whether this is an OBJECT IDENTIFIER tag
    public var isObjectIdentifier: Bool {
        tagClass == .universal && tagNumber == ASN1UniversalTag.objectIdentifier.rawValue
    }

    /// Whether this is a BIT STRING tag
    public var isBitString: Bool {
        tagClass == .universal && tagNumber == ASN1UniversalTag.bitString.rawValue
    }

    /// Whether this is an OCTET STRING tag
    public var isOctetString: Bool {
        tagClass == .universal && tagNumber == ASN1UniversalTag.octetString.rawValue
    }

    // MARK: - Common Tags

    /// SEQUENCE tag (constructed)
    public static let sequence = ASN1Tag(universal: .sequence, isConstructed: true)

    /// SET tag (constructed)
    public static let set = ASN1Tag(universal: .set, isConstructed: true)

    /// INTEGER tag
    public static let integer = ASN1Tag(universal: .integer)

    /// OBJECT IDENTIFIER tag
    public static let objectIdentifier = ASN1Tag(universal: .objectIdentifier)

    /// BIT STRING tag
    public static let bitString = ASN1Tag(universal: .bitString)

    /// OCTET STRING tag
    public static let octetString = ASN1Tag(universal: .octetString)

    /// NULL tag
    public static let null = ASN1Tag(universal: .null)

    /// BOOLEAN tag
    public static let boolean = ASN1Tag(universal: .boolean)

    /// UTC TIME tag
    public static let utcTime = ASN1Tag(universal: .utcTime)

    /// GENERALIZED TIME tag
    public static let generalizedTime = ASN1Tag(universal: .generalizedTime)

    /// UTF8 STRING tag
    public static let utf8String = ASN1Tag(universal: .utf8String)

    /// PRINTABLE STRING tag
    public static let printableString = ASN1Tag(universal: .printableString)

    /// IA5 STRING tag
    public static let ia5String = ASN1Tag(universal: .ia5String)
}

// MARK: - CustomStringConvertible

extension ASN1Tag: CustomStringConvertible {
    public var description: String {
        let classStr: String
        switch tagClass {
        case .universal:
            if let univTag = universalTag {
                return univTag.description + (isConstructed ? " (constructed)" : "")
            }
            classStr = "UNIVERSAL"
        case .application:
            classStr = "APPLICATION"
        case .contextSpecific:
            classStr = "CONTEXT"
        case .private:
            classStr = "PRIVATE"
        }
        return "[\(classStr) \(tagNumber)]" + (isConstructed ? " (constructed)" : "")
    }
}
