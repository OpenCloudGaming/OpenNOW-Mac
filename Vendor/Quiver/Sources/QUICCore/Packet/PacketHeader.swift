/// QUIC Packet Headers (RFC 9000 Section 17)
///
/// QUIC packets use two header formats:
/// - Long Header: Used during connection establishment (Initial, Handshake, 0-RTT, Retry)
/// - Short Header: Used after handshake completion (1-RTT)

import Foundation

// MARK: - Packet Type

/// Type of QUIC packet
@frozen
public enum PacketType: Sendable, Hashable {
    /// Initial packet (long header, type 0x00)
    case initial
    /// 0-RTT packet (long header, type 0x01)
    case zeroRTT
    /// Handshake packet (long header, type 0x02)
    case handshake
    /// Retry packet (long header, type 0x03)
    case retry
    /// 1-RTT packet (short header)
    case oneRTT
    /// Version Negotiation packet
    case versionNegotiation

    /// Whether this packet type uses a long header
    public var isLongHeader: Bool {
        switch self {
        case .initial, .zeroRTT, .handshake, .retry, .versionNegotiation:
            return true
        case .oneRTT:
            return false
        }
    }

    /// The encryption level for this packet type
    public var encryptionLevel: EncryptionLevel {
        switch self {
        case .initial, .retry, .versionNegotiation:
            return .initial
        case .zeroRTT:
            return .zeroRTT
        case .handshake:
            return .handshake
        case .oneRTT:
            return .application
        }
    }
}

/// Encryption level (packet number space)
@frozen
public enum EncryptionLevel: Int, Sendable, Hashable, CaseIterable {
    case initial = 0
    case zeroRTT = 1
    case handshake = 2
    case application = 3
}

// MARK: - Packet Header

/// A QUIC packet header (either long or short form)
public enum PacketHeader: Sendable {
    case long(LongHeader)
    case short(ShortHeader)

    /// The packet type
    public var packetType: PacketType {
        switch self {
        case .long(let header):
            return header.packetType
        case .short:
            return .oneRTT
        }
    }

    /// The destination connection ID
    public var destinationConnectionID: ConnectionID {
        switch self {
        case .long(let header):
            return header.destinationConnectionID
        case .short(let header):
            return header.destinationConnectionID
        }
    }
}

// MARK: - Long Header

/// Long header format (RFC 9000 Section 17.2)
///
/// ```
/// Long Header Packet {
///   Header Form (1) = 1,
///   Fixed Bit (1) = 1,
///   Long Packet Type (2),
///   Type-Specific Bits (4),
///   Version (32),
///   Destination Connection ID Length (8),
///   Destination Connection ID (0..160),
///   Source Connection ID Length (8),
///   Source Connection ID (0..160),
///   Type-Specific Payload (..),
/// }
/// ```
public struct LongHeader: Sendable, Hashable {
    /// The first byte of the header (contains flags)
    public var firstByte: UInt8

    /// QUIC version
    public let version: QUICVersion

    /// Destination connection ID
    public let destinationConnectionID: ConnectionID

    /// Source connection ID
    public let sourceConnectionID: ConnectionID

    /// Token (for Initial and Retry packets)
    public var token: Data?

    /// Retry Integrity Tag (16 bytes, for Retry packets only)
    /// RFC 9001 Section 5.8
    public var retryIntegrityTag: Data?

    /// Length field value (for Initial, Handshake, 0-RTT)
    /// This is the length of the Packet Number + Payload
    public var length: UInt64?

    /// Packet number (decoded, before encryption)
    public var packetNumber: UInt64

    /// Length of the packet number field (1-4 bytes)
    public var packetNumberLength: Int

    /// The packet type derived from the first byte
    public var packetType: PacketType {
        if version.isNegotiation {
            return .versionNegotiation
        }
        let typeValue = (firstByte >> 4) & 0x03
        switch typeValue {
        case 0x00: return .initial
        case 0x01: return .zeroRTT
        case 0x02: return .handshake
        case 0x03: return .retry
        default: fatalError("Invalid long header type")
        }
    }

    /// Creates a long header
    public init(
        packetType: PacketType,
        version: QUICVersion,
        destinationConnectionID: ConnectionID,
        sourceConnectionID: ConnectionID,
        token: Data? = nil,
        retryIntegrityTag: Data? = nil,
        length: UInt64? = nil,
        packetNumber: UInt64 = 0,
        packetNumberLength: Int = 4
    ) {
        // Build first byte based on packet type
        // RFC 9000 Section 17.2: Long Header format
        var byte: UInt8
        var effectivePNLength = packetNumberLength

        switch packetType {
        case .initial:
            // Form (1) | Fixed (1) | Type 00 | Reserved (2) | PN Length (2)
            byte = 0xC0 | (0x00 << 4) | UInt8(packetNumberLength - 1) & 0x03

        case .zeroRTT:
            // Form (1) | Fixed (1) | Type 01 | Reserved (2) | PN Length (2)
            byte = 0xC0 | (0x01 << 4) | UInt8(packetNumberLength - 1) & 0x03

        case .handshake:
            // Form (1) | Fixed (1) | Type 02 | Reserved (2) | PN Length (2)
            byte = 0xC0 | (0x02 << 4) | UInt8(packetNumberLength - 1) & 0x03

        case .retry:
            // RFC 9000 Section 17.2.5: Retry packets have no packet number
            // Form (1) | Fixed (1) | Type 11 | Unused (4)
            // The unused bits SHOULD be set to 0 but are ignored on receipt
            byte = 0xC0 | (0x03 << 4)
            effectivePNLength = 0

        case .versionNegotiation:
            // RFC 9000 Section 17.2.1: Version Negotiation
            // The Fixed bit (0x40) can be arbitrary for Version Negotiation
            // per RFC 8999 (QUIC Invariants). We set it to 1 for consistency.
            // The type bits are also arbitrary.
            byte = 0xC0  // Form = 1, Fixed = 1, rest arbitrary (set to 0)
            effectivePNLength = 0

        case .oneRTT:
            fatalError("Cannot create long header for 1-RTT packet")
        }

        self.firstByte = byte
        self.version = version
        self.destinationConnectionID = destinationConnectionID
        self.sourceConnectionID = sourceConnectionID
        self.token = token
        self.retryIntegrityTag = retryIntegrityTag
        self.length = length
        self.packetNumber = packetNumber
        self.packetNumberLength = effectivePNLength
    }

    /// Whether this packet type has a packet number
    public var hasPacketNumber: Bool {
        switch packetType {
        case .initial, .zeroRTT, .handshake:
            return true
        case .retry, .versionNegotiation:
            return false
        default:
            return false
        }
    }
}

// MARK: - Short Header

/// Short header format (RFC 9000 Section 17.3)
///
/// ```
/// 1-RTT Packet {
///   Header Form (1) = 0,
///   Fixed Bit (1) = 1,
///   Spin Bit (1),
///   Reserved Bits (2),
///   Key Phase (1),
///   Packet Number Length (2),
///   Destination Connection ID (0..160),
///   Packet Number (8..32),
///   Packet Payload (8..),
/// }
/// ```
public struct ShortHeader: Sendable, Hashable {
    /// The first byte of the header
    public var firstByte: UInt8

    /// Destination connection ID
    public let destinationConnectionID: ConnectionID

    /// Packet number (decoded)
    public var packetNumber: UInt64

    /// Length of the packet number field (1-4 bytes)
    public var packetNumberLength: Int

    /// Spin bit (for latency measurement)
    public var spinBit: Bool {
        (firstByte & 0x20) != 0
    }

    /// Key phase bit (for key updates)
    public var keyPhase: Bool {
        (firstByte & 0x04) != 0
    }

    /// Creates a short header
    public init(
        destinationConnectionID: ConnectionID,
        packetNumber: UInt64 = 0,
        packetNumberLength: Int = 4,
        spinBit: Bool = false,
        keyPhase: Bool = false
    ) {
        // Build first byte: 0 | 1 | S | RR | K | PP
        var byte: UInt8 = 0x40  // Header form = 0, Fixed bit = 1

        if spinBit {
            byte |= 0x20
        }
        if keyPhase {
            byte |= 0x04
        }
        byte |= UInt8(packetNumberLength - 1) & 0x03

        self.firstByte = byte
        self.destinationConnectionID = destinationConnectionID
        self.packetNumber = packetNumber
        self.packetNumberLength = packetNumberLength
    }

    /// Creates a short header from parsed data (preserves original firstByte for validation)
    /// - Parameters:
    ///   - firstByte: The raw first byte from the packet (for validation)
    ///   - destinationConnectionID: The destination connection ID
    ///   - packetNumber: The packet number (0 if not yet decrypted)
    ///   - packetNumberLength: The length of the packet number field (1-4 bytes)
    internal init(
        firstByte: UInt8,
        destinationConnectionID: ConnectionID,
        packetNumber: UInt64,
        packetNumberLength: Int
    ) {
        self.firstByte = firstByte
        self.destinationConnectionID = destinationConnectionID
        self.packetNumber = packetNumber
        self.packetNumberLength = packetNumberLength
    }
}

// MARK: - Protected Long Header

/// A protected long header (before header protection removal)
///
/// This type represents a long header that has been parsed from a protected packet.
/// The `protectedFirstByte` contains bits that have been XORed with a mask and
/// cannot be reliably validated until header protection is removed.
///
/// Use `unprotect()` after calling `removeHeaderProtection()` to create a
/// validated `LongHeader`.
public struct ProtectedLongHeader: Sendable, Hashable {
    /// The protected first byte (contains XORed bits)
    public let protectedFirstByte: UInt8

    /// QUIC version
    public let version: QUICVersion

    /// Destination connection ID
    public let destinationConnectionID: ConnectionID

    /// Source connection ID
    public let sourceConnectionID: ConnectionID

    /// Token (for Initial and Retry packets)
    public let token: Data?

    /// Retry Integrity Tag (16 bytes, for Retry packets only)
    public let retryIntegrityTag: Data?

    /// Length field value (for Initial, Handshake, 0-RTT)
    public let length: UInt64?

    /// The packet type derived from the first byte
    /// Note: Bits 5-4 are NOT protected, so this is reliable
    public var packetType: LongPacketType {
        if version.isNegotiation {
            return .versionNegotiation
        }
        let typeValue = (protectedFirstByte >> 4) & 0x03
        return LongPacketType(rawValue: typeValue) ?? .initial
    }

    /// Whether this packet type has a packet number
    public var hasPacketNumber: Bool {
        switch packetType {
        case .initial, .zeroRTT, .handshake:
            return true
        case .retry, .versionNegotiation:
            return false
        }
    }

    /// Errors that can occur during parsing
    public enum ParseError: Error, Sendable {
        case insufficientData
        case invalidHeader
    }

    /// Parses a protected long header from data
    ///
    /// This method only extracts header fields without validation of protected bits.
    /// - Parameter data: The packet data
    /// - Returns: The parsed protected header and the number of bytes consumed
    public static func parse(from data: Data) throws -> (ProtectedLongHeader, Int) {
        var reader = DataReader(data)
        let startPosition = reader.currentPosition

        guard let firstByte = reader.readByte() else {
            throw ParseError.insufficientData
        }

        // Verify this is a long header
        guard (firstByte & 0x80) != 0 else {
            throw ParseError.invalidHeader
        }

        // Read version
        guard let version = QUICVersion.decode(from: &reader) else {
            throw ParseError.insufficientData
        }

        // Read DCID
        let dcid = try ConnectionID.decode(from: &reader)

        // Read SCID
        let scid = try ConnectionID.decode(from: &reader)

        // Determine packet type and read type-specific fields
        var token: Data?
        var retryIntegrityTag: Data?
        var length: UInt64?

        if version.isNegotiation {
            // Version Negotiation packet - no additional fields to parse here
            let header = ProtectedLongHeader(
                protectedFirstByte: firstByte,
                version: version,
                destinationConnectionID: dcid,
                sourceConnectionID: scid,
                token: nil,
                retryIntegrityTag: nil,
                length: nil
            )
            return (header, reader.currentPosition - startPosition)
        }

        let packetType = (firstByte >> 4) & 0x03

        switch packetType {
        case 0x00:  // Initial
            // Read token length and token
            let tokenLengthValue = try reader.readVarintValue()
            if tokenLengthValue > 0 {
                let safeTokenLength = try SafeConversions.toInt(
                    tokenLengthValue,
                    maxAllowed: ProtocolLimits.maxInitialTokenLength,
                    context: "Initial packet token length"
                )
                guard let tokenData = reader.readBytes(safeTokenLength) else {
                    throw ParseError.insufficientData
                }
                token = tokenData
            }
            // Read Length field
            length = try reader.readVarintValue()

        case 0x01:  // 0-RTT
            length = try reader.readVarintValue()

        case 0x02:  // Handshake
            length = try reader.readVarintValue()

        case 0x03:  // Retry
            // RFC 9001 Section 5.8: Retry Token + 16-byte Retry Integrity Tag
            let remainingCount = reader.remainingCount
            if remainingCount >= ProtocolLimits.retryIntegrityTagLength {
                let retryTokenLength = remainingCount - ProtocolLimits.retryIntegrityTagLength
                if retryTokenLength > 0 {
                    token = reader.readBytes(retryTokenLength)
                }
                retryIntegrityTag = reader.readBytes(ProtocolLimits.retryIntegrityTagLength)
            }

        default:
            break
        }

        let header = ProtectedLongHeader(
            protectedFirstByte: firstByte,
            version: version,
            destinationConnectionID: dcid,
            sourceConnectionID: scid,
            token: token,
            retryIntegrityTag: retryIntegrityTag,
            length: length
        )

        return (header, reader.currentPosition - startPosition)
    }

    /// Creates a validated LongHeader after header protection removal
    ///
    /// This method validates the unprotected first byte and creates a `LongHeader`.
    /// - Parameters:
    ///   - unprotectedFirstByte: The first byte after header protection removal
    ///   - packetNumber: The decoded packet number
    ///   - packetNumberLength: The length of the packet number field (1-4)
    /// - Returns: A validated `LongHeader`
    /// - Throws: `HeaderValidationError` if validation fails
    public func unprotect(
        unprotectedFirstByte: UInt8,
        packetNumber: UInt64,
        packetNumberLength: Int
    ) throws -> LongHeader {
        // Determine packet type from protected bits (bits 5-4 are not protected)
        let actualPacketType: PacketType
        switch packetType {
        case .initial: actualPacketType = .initial
        case .zeroRTT: actualPacketType = .zeroRTT
        case .handshake: actualPacketType = .handshake
        case .retry: actualPacketType = .retry
        case .versionNegotiation: actualPacketType = .versionNegotiation
        }

        var header = LongHeader(
            packetType: actualPacketType,
            version: version,
            destinationConnectionID: destinationConnectionID,
            sourceConnectionID: sourceConnectionID,
            token: token,
            retryIntegrityTag: retryIntegrityTag,
            length: length,
            packetNumber: packetNumber,
            packetNumberLength: packetNumberLength
        )
        header.firstByte = unprotectedFirstByte

        // RFC 9000 §17.2: Endpoints MUST treat receipt of a packet that has a
        // non-zero value for reserved bits after removing both packet and header
        // protection as a connection error of type PROTOCOL_VIOLATION.
        try header.validate(strict: true)

        return header
    }
}

// MARK: - Long Packet Type

/// Long header packet type (RFC 9000 Section 17.2)
public enum LongPacketType: UInt8, Sendable, Hashable {
    case initial = 0x00
    case zeroRTT = 0x01
    case handshake = 0x02
    case retry = 0x03
    case versionNegotiation = 0xFF  // Special value, determined by version = 0

    /// The encryption level for this packet type
    public var encryptionLevel: EncryptionLevel {
        switch self {
        case .initial, .retry, .versionNegotiation:
            return .initial
        case .zeroRTT:
            return .zeroRTT
        case .handshake:
            return .handshake
        }
    }
}

// MARK: - Protected Short Header

/// A protected short header (before header protection removal)
///
/// This type represents a short header that has been parsed from a protected packet.
/// For short headers, even the Fixed bit is protected, so no validation can occur
/// until header protection is removed.
///
/// Use `unprotect()` after calling `removeHeaderProtection()` to create a
/// validated `ShortHeader`.
public struct ProtectedShortHeader: Sendable, Hashable {
    /// The protected first byte (contains XORed bits)
    public let protectedFirstByte: UInt8

    /// Destination connection ID
    public let destinationConnectionID: ConnectionID

    /// Errors that can occur during parsing
    public enum ParseError: Error, Sendable {
        case insufficientData
        case invalidHeader
    }

    /// Parses a protected short header from data
    ///
    /// This method only extracts header fields without validation.
    /// - Parameters:
    ///   - data: The packet data
    ///   - dcidLength: The expected DCID length (from connection state)
    /// - Returns: The parsed protected header and the number of bytes consumed
    public static func parse(from data: Data, dcidLength: Int) throws -> (ProtectedShortHeader, Int) {
        var reader = DataReader(data)

        guard let firstByte = reader.readByte() else {
            throw ParseError.insufficientData
        }

        // Verify this is a short header
        guard (firstByte & 0x80) == 0 else {
            throw ParseError.invalidHeader
        }

        // Read DCID (length is known from connection state)
        let dcid = try ConnectionID.decodeBytes(from: &reader, length: dcidLength)

        let header = ProtectedShortHeader(
            protectedFirstByte: firstByte,
            destinationConnectionID: dcid
        )

        // Header length = 1 (first byte) + dcidLength
        return (header, 1 + dcidLength)
    }

    /// Creates a validated ShortHeader after header protection removal
    ///
    /// This method validates the unprotected first byte and creates a `ShortHeader`.
    /// - Parameters:
    ///   - unprotectedFirstByte: The first byte after header protection removal
    ///   - packetNumber: The decoded packet number
    ///   - packetNumberLength: The length of the packet number field (1-4)
    /// - Returns: A validated `ShortHeader`
    /// - Throws: `HeaderValidationError` if validation fails
    public func unprotect(
        unprotectedFirstByte: UInt8,
        packetNumber: UInt64,
        packetNumberLength: Int
    ) throws -> ShortHeader {
        // Use internal initializer to preserve the unprotected firstByte
        let header = ShortHeader(
            firstByte: unprotectedFirstByte,
            destinationConnectionID: destinationConnectionID,
            packetNumber: packetNumber,
            packetNumberLength: packetNumberLength
        )

        // RFC 9000 §17.3: Endpoints MUST treat receipt of a packet that has a
        // non-zero value for reserved bits after removing both packet and header
        // protection as a connection error of type PROTOCOL_VIOLATION.
        try header.validate(strict: true)

        return header
    }
}

// MARK: - Protected Packet Header

/// A protected packet header (either long or short form)
///
/// This is a union type for protected headers before header protection removal.
public enum ProtectedPacketHeader: Sendable, Hashable {
    case long(ProtectedLongHeader)
    case short(ProtectedShortHeader)

    /// Errors that can occur during parsing
    public enum ParseError: Error, Sendable {
        case insufficientData
        case invalidHeader
    }

    /// Parses a protected packet header from data
    ///
    /// This method automatically determines whether the packet has a long or short header.
    /// - Parameters:
    ///   - data: The packet data
    ///   - dcidLength: For short headers, the expected DCID length (from connection state)
    /// - Returns: The parsed protected header and the number of bytes consumed
    public static func parse(from data: Data, dcidLength: Int = 0) throws -> (ProtectedPacketHeader, Int) {
        guard !data.isEmpty else {
            throw ParseError.insufficientData
        }

        let firstByte = data[data.startIndex]
        let isLongHeader = (firstByte & 0x80) != 0

        if isLongHeader {
            let (header, length) = try ProtectedLongHeader.parse(from: data)
            return (.long(header), length)
        } else {
            let (header, length) = try ProtectedShortHeader.parse(from: data, dcidLength: dcidLength)
            return (.short(header), length)
        }
    }

    /// The encryption level for this packet
    ///
    /// For long headers, this is derived from the packet type (bits 5-4, not protected).
    /// For short headers, this is always `.application`.
    public var encryptionLevel: EncryptionLevel {
        switch self {
        case .long(let header):
            return header.packetType.encryptionLevel
        case .short:
            return .application
        }
    }

    /// The destination connection ID
    public var destinationConnectionID: ConnectionID {
        switch self {
        case .long(let header):
            return header.destinationConnectionID
        case .short(let header):
            return header.destinationConnectionID
        }
    }

    /// Whether this is a long header packet
    public var isLongHeader: Bool {
        if case .long = self { return true }
        return false
    }
}

// MARK: - Packet Number Encoding

/// Packet number encoding utilities (RFC 9000 Section 17.1)
public enum PacketNumberEncoding {
    /// Encodes a packet number using the minimum number of bytes
    /// - Parameters:
    ///   - fullPacketNumber: The full packet number to encode
    ///   - largestAcked: The largest acknowledged packet number
    /// - Returns: The encoded bytes and the number of bytes used
    public static func encode(
        fullPacketNumber: UInt64,
        largestAcked: UInt64?
    ) -> (bytes: Data, length: Int) {
        // Determine the minimum length needed
        // RFC 9000 Section 17.1: The sender MUST use a packet number size able
        // to represent more than twice as large a range as the difference between
        // the largest acknowledged packet number and the current packet number.
        let numUnacked: UInt64

        if let acked = largestAcked, acked <= fullPacketNumber {
            numUnacked = fullPacketNumber - acked
        } else {
            // No ACKs received yet or edge case: use packet number + 1
            // This ensures we use enough bits to represent the full range
            numUnacked = fullPacketNumber + 1
        }

        let length: Int
        if numUnacked < (1 << 7) {
            length = 1
        } else if numUnacked < (1 << 15) {
            length = 2
        } else if numUnacked < (1 << 23) {
            length = 3
        } else {
            length = 4
        }

        // Encode the truncated packet number
        var bytes = Data(capacity: length)
        let truncated = fullPacketNumber & ((1 << (length * 8)) - 1)

        for i in (0..<length).reversed() {
            bytes.append(UInt8((truncated >> (i * 8)) & 0xFF))
        }

        return (bytes, length)
    }

    /// Decodes a truncated packet number to its full value
    /// - Parameters:
    ///   - truncated: The truncated packet number
    ///   - length: The length of the truncated packet number (1-4)
    ///   - largestPN: The largest packet number received so far
    /// - Returns: The full packet number
    public static func decode(
        truncated: UInt64,
        length: Int,
        largestPN: UInt64
    ) -> UInt64 {
        let expectedPN = largestPN + 1
        let pnWin = UInt64(1) << (length * 8)
        let pnHwin = pnWin / 2
        let pnMask = pnWin - 1

        let candidatePN = (expectedPN & ~pnMask) | truncated

        // Use safe comparison to avoid underflow
        // candidatePN <= expectedPN - pnHwin  is equivalent to  candidatePN + pnHwin <= expectedPN
        if candidatePN + pnHwin <= expectedPN && candidatePN < (1 << 62) - pnWin {
            return candidatePN + pnWin
        } else if candidatePN > expectedPN + pnHwin && candidatePN >= pnWin {
            return candidatePN - pnWin
        } else {
            return candidatePN
        }
    }
}

// MARK: - Header Validation

/// Header validation errors
public enum HeaderValidationError: Error, Sendable {
    /// The fixed bit (0x40) is not set to 1
    case fixedBitNotSet
    /// Reserved bits are not zero (warning-level, may be ignored per RFC 8999)
    case reservedBitsNotZero(bits: UInt8)
    /// Retry packet is missing the Retry Integrity Tag (RFC 9001 Section 5.8)
    case missingRetryIntegrityTag
}

extension LongHeader {
    /// Validates the header format after header protection has been removed.
    ///
    /// RFC 9000 Section 17.2: The Fixed bit MUST be set to 1.
    /// Reserved bits (two bits between type and packet number length) SHOULD be 0.
    ///
    /// Note: Per RFC 8999 (QUIC Invariants), receivers MUST ignore the fixed bit
    /// for future versions. However, for QUIC v1, the fixed bit validation can
    /// detect corrupted packets early.
    ///
    /// - Parameter strict: If true, also validates reserved bits; if false, only checks fixed bit
    /// - Throws: HeaderValidationError if validation fails
    public func validate(strict: Bool = false) throws {
        // Check fixed bit (0x40) is set
        // Note: Version Negotiation packets have arbitrary bits per RFC 8999
        if !version.isNegotiation {
            guard (firstByte & 0x40) != 0 else {
                throw HeaderValidationError.fixedBitNotSet
            }
        }

        // For strict validation, check reserved bits (bits 3-4 in Initial/Handshake/0-RTT)
        // These are the two bits between packet type and packet number length
        if strict && hasPacketNumber {
            let reservedBits = (firstByte >> 2) & 0x03
            if reservedBits != 0 {
                throw HeaderValidationError.reservedBitsNotZero(bits: reservedBits)
            }
        }

        // RFC 9001 Section 5.8: Retry packets MUST have a Retry Integrity Tag
        if packetType == .retry {
            guard retryIntegrityTag != nil && retryIntegrityTag!.count == 16 else {
                throw HeaderValidationError.missingRetryIntegrityTag
            }
        }
    }
}

extension ShortHeader {
    /// Validates the header format after header protection has been removed.
    ///
    /// RFC 9000 Section 17.3: The Fixed bit MUST be set to 1.
    /// Reserved bits (bits 3-4) SHOULD be 0.
    ///
    /// - Parameter strict: If true, also validates reserved bits; if false, only checks fixed bit
    /// - Throws: HeaderValidationError if validation fails
    public func validate(strict: Bool = false) throws {
        // Check fixed bit (0x40) is set
        guard (firstByte & 0x40) != 0 else {
            throw HeaderValidationError.fixedBitNotSet
        }

        // For strict validation, check reserved bits (0x18 = bits 3-4)
        if strict {
            let reservedBits = (firstByte >> 3) & 0x03
            if reservedBits != 0 {
                throw HeaderValidationError.reservedBitsNotZero(bits: reservedBits)
            }
        }
    }
}
