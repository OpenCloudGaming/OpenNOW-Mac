import CommonCrypto
import Foundation

/// STUN hole-punching for the NVST "Mjolnir" socket, per the independently observed format
/// (`NattHolePunch::SendPing`, pingVersion=6):
/// - Binding request USERNAME is `pingPayload:localUfrag`; MESSAGE-INTEGRITY is HMAC-SHA1
///   keyed by the remote password (the DESCRIBE password for the punch, the local ICE
///   password for validating inbound requests); FINGERPRINT is CRC-32 of the preceding bytes
///   XOR 0x5354554e.
/// - Responses carry XOR-MAPPED-ADDRESS over the STUN magic cookie / transaction id.

public struct NvstSocketEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

public enum NvstStunError: LocalizedError, Equatable, Sendable {
    case notStun
    case invalidFingerprint
    case invalidIntegrity
    case missingUsername
    case missingMappedAddress
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .notStun: "Not a STUN packet."
        case .invalidFingerprint: "STUN FINGERPRINT mismatch."
        case .invalidIntegrity: "STUN MESSAGE-INTEGRITY mismatch."
        case .missingUsername: "STUN USERNAME attribute missing."
        case .missingMappedAddress: "STUN XOR-MAPPED-ADDRESS attribute missing."
        case .malformed(let reason): "Malformed STUN packet: \(reason)"
        }
    }
}

private enum NvstCrc32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (value >> 1) ^ 0xedb8_8320 : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ 0xffff_ffff
    }
}

private enum NvstStunAttribute {
    static let username: UInt16 = 0x0006
    static let messageIntegrity: UInt16 = 0x0008
    static let xorMappedAddress: UInt16 = 0x0020
    static let fingerprint: UInt16 = 0x8028
}

private let stunMagicCookie: UInt32 = 0x2112_a442
private let fingerprintXor: UInt32 = 0x5354_554e
private let stunBindingRequest: UInt16 = 0x0001
private let stunBindingSuccessResponse: UInt16 = 0x0101

public enum NvstStunHolePunch {
    /// Builds an authenticated STUN binding request (header + USERNAME + MESSAGE-INTEGRITY + FINGERPRINT).
    public static func buildBindingRequest(transactionID: Data, username: String, integrityKey: Data) -> Data? {
        guard let username = username.data(using: .utf8) else { return nil }
        return buildAuthenticatedPacket(
            messageType: stunBindingRequest,
            transactionID: transactionID,
            attributes: [(NvstStunAttribute.username, username)],
            integrityKey: integrityKey
        )
    }

    /// Official ping-version 6 PONG: a STUN Binding Success answering an inbound request,
    /// authenticated with our own (local) ICE password.
    public static func buildBindingSuccess(transactionID: Data,
                                           mappedHost: String,
                                           mappedPort: UInt16,
                                           integrityKey: Data) -> Data? {
        guard let mapped = xorMappedAddress(host: mappedHost, port: mappedPort, transactionID: transactionID) else {
            return nil
        }
        return buildAuthenticatedPacket(
            messageType: stunBindingSuccessResponse,
            transactionID: transactionID,
            attributes: [(NvstStunAttribute.xorMappedAddress, mapped)],
            integrityKey: integrityKey
        )
    }

    /// Header + attributes + MESSAGE-INTEGRITY + FINGERPRINT, with both length rewrites RFC 5389
    /// requires: the integrity HMAC sees a length that stops after its own attribute, and the
    /// fingerprint CRC sees the final length.
    static func buildAuthenticatedPacket(messageType: UInt16,
                                         transactionID: Data,
                                         attributes: [(UInt16, Data)],
                                         integrityKey: Data) -> Data? {
        guard transactionID.count == 12 else { return nil }
        var header = Data()
        header.appendBigEndian(messageType)
        header.appendBigEndian(UInt16(0)) // length placeholder
        header.append(contentsOf: [UInt8(0x21), UInt8(0x12), UInt8(0xa4), UInt8(0x42)])
        header.append(transactionID)

        var body = Data()
        for (type, value) in attributes {
            body.appendAttribute(type: type, value: value)
        }
        let integrityPlaceholder = [UInt8](repeating: 0, count: 20)
        body.appendAttribute(type: NvstStunAttribute.messageIntegrity, value: Data(integrityPlaceholder))

        header.replaceSubrange(2..<4, with: UInt16(body.count).bigEndianBytes())

        // HMAC covers the message up to the start of MESSAGE-INTEGRITY (its 4-byte header and
        // 20-byte value are both excluded).
        var integrityInput = header
        integrityInput.append(body.prefix(body.count - 24))
        var hmac = [UInt8](repeating: 0, count: 20)
        integrityKey.withUnsafeBytes { keyBytes in
            integrityInput.withUnsafeBytes { inputBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), keyBytes.baseAddress, integrityKey.count, inputBytes.baseAddress, integrityInput.count, &hmac)
            }
        }
        body.replaceSubrange((body.count - 20)..<body.count, with: hmac)

        header.replaceSubrange(2..<4, with: UInt16(body.count + 8).bigEndianBytes())
        var fingerprintInput = header
        fingerprintInput.append(body)
        let fingerprint = NvstCrc32.crc32(fingerprintInput) ^ fingerprintXor
        body.appendAttribute(type: NvstStunAttribute.fingerprint, value: fingerprint.bigEndianBytes())

        var packet = header
        packet.append(body)
        return packet
    }

    /// The 12-byte transaction id of an inbound STUN message, when it is a Binding Request.
    public static func bindingRequestTransactionID(_ packet: Data) -> Data? {
        guard packet.count >= 20,
              packet.readUInt32BE(at: 4) == stunMagicCookie,
              packet.readUInt16BE(at: 0) == stunBindingRequest else { return nil }
        return Data(packet[(packet.startIndex + 8)..<(packet.startIndex + 20)])
    }

    /// NATT hole punch: USERNAME = `pingPayload:localUfrag`, HMAC keyed by the remote password.
    public static func buildNattHolePunchRequest(localUfrag: String, pingPayload: String, remotePassword: Data, transactionID: Data) -> Data? {
        let username = "\(pingPayload):\(localUfrag)"
        return buildBindingRequest(transactionID: transactionID, username: username, integrityKey: remotePassword)
    }

    /// Validates FINGERPRINT + MESSAGE-INTEGRITY and extracts the XOR-MAPPED-ADDRESS.
    public static func parseBindingResponse(_ packet: Data, integrityKey: Data, transactionID: Data) throws -> NvstSocketEndpoint? {
        guard packet.count >= 20,
              UInt32(packet[0]) != 0 || (packet[0] & 0xc0) == 0 else { throw NvstStunError.notStun }
        guard packet.readUInt32BE(at: 4) == stunMagicCookie else { throw NvstStunError.notStun }
        let messageType = packet.readUInt16BE(at: 0)
        if messageType != stunBindingSuccessResponse { return nil }
        guard packet.count == 20 + Int(packet.readUInt16BE(at: 2)) else { throw NvstStunError.malformed("length") }
        guard packet[8..<20].elementsEqual(transactionID) else { throw NvstStunError.malformed("transaction id") }

        // FINGERPRINT covers everything before it.
        guard let (fingerprintOffset, fingerprintValue) = attribute(packet, type: NvstStunAttribute.fingerprint) else {
            throw NvstStunError.malformed("missing fingerprint")
        }
        guard fingerprintValue.count == 4 else { throw NvstStunError.malformed("fingerprint length") }
        let expected = NvstCrc32.crc32(packet[..<fingerprintOffset]) ^ fingerprintXor
        guard fingerprintValue.readUInt32BE(at: 0) == expected else { throw NvstStunError.invalidFingerprint }

        // MESSAGE-INTEGRITY covers the message through its own attribute, with length adjusted.
        guard let (integrityOffset, integrity) = attribute(packet, type: NvstStunAttribute.messageIntegrity), integrity.count == 20 else {
            throw NvstStunError.invalidIntegrity
        }
        var adjusted = packet[..<(integrityOffset + 24)]
        adjusted.replaceSubrange(2..<4, with: UInt16(integrityOffset + 24 - 20).bigEndianBytes())
        var hmac = [UInt8](repeating: 0, count: 20)
        integrityKey.withUnsafeBytes { keyBytes in
            adjusted.withUnsafeBytes { inputBytes in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1), keyBytes.baseAddress, integrityKey.count, inputBytes.baseAddress, inputBytes.count, &hmac)
            }
        }
        guard hmac.elementsEqual(integrity) else { throw NvstStunError.invalidIntegrity }

        guard let mappedAttribute = attribute(packet, type: NvstStunAttribute.xorMappedAddress) else {
            throw NvstStunError.missingMappedAddress
        }
        let mapped = mappedAttribute.value
        guard mapped.count >= 8 else { throw NvstStunError.missingMappedAddress }
        let family = mapped[1]
        let port = mapped.readUInt16BE(at: 2) ^ UInt16(truncatingIfNeeded: stunMagicCookie >> 16)
        var host = "?"
        if family == 0x01, mapped.count >= 8 {
            let address = mapped.readUInt32BE(at: 4) ^ stunMagicCookie
            host = "\(address >> 24 & 0xff).\(address >> 16 & 0xff).\(address >> 8 & 0xff).\(address & 0xff)"
        } else if family == 0x02, mapped.count >= 20 {
            var addr = [UInt8](repeating: 0, count: 16)
            for index in 0..<4 { addr[index] = mapped[4 + index] ^ UInt8((stunMagicCookie >> (8 * (3 - index))) & 0xff) }
            for index in 0..<12 { addr[4 + index] = mapped[8 + index] ^ transactionID[index] }
            host = Self.formatIPv6(addr)
        }
        return NvstSocketEndpoint(host: host, port: port)
    }

    /// Builds a XOR-MAPPED-ADDRESS STUN value (family byte + x-port + x-address).
    public static func xorMappedAddress(host: String, port: UInt16, transactionID: Data) -> Data? {
        var value = Data([0x00, 0x01]) // IPv4
        let addr = host.split(separator: ".").compactMap { UInt8($0) }
        if addr.count == 4 {
            value.appendBigEndian(port ^ UInt16(truncatingIfNeeded: stunMagicCookie >> 16))
            let address = UInt32(addr[0]) << 24 | UInt32(addr[1]) << 16 | UInt32(addr[2]) << 8 | UInt32(addr[3])
            value.appendBigEndian(address ^ stunMagicCookie)
            return value
        }
        return nil
    }

    private static func attribute(_ packet: Data, type: UInt16) -> (offset: Int, value: Data)? {
        var offset = 20
        while offset + 4 <= packet.count {
            let attributeType = packet.readUInt16BE(at: offset)
            let length = Int(packet.readUInt16BE(at: offset + 2))
            let valueStart = offset + 4
            guard valueStart + length <= packet.count else { return nil }
            if attributeType == type {
                return (offset, Data(packet[valueStart..<(valueStart + length)]))
            }
            offset = valueStart + ((length + 3) & ~3)
        }
        return nil
    }

    private static func formatIPv6(_ octets: [UInt8]) -> String {
        var groups: [String] = []
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append(String(format: "%02x%02x", octets[index], octets[index + 1]))
        }
        return groups.joined(separator: ":")
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(contentsOf: value.bigEndianBytes())
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: value.bigEndianBytes())
    }

    mutating func appendAttribute(type: UInt16, value: Data) {
        appendBigEndian(type)
        appendBigEndian(UInt16(value.count))
        append(contentsOf: value)
        let padded = (value.count + 3) & ~3
        if padded > value.count { append(contentsOf: [UInt8](repeating: 0, count: padded - value.count)) }
    }

    func readUInt16BE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) << 8 | UInt16(self[offset + 1])
    }

    func readUInt32BE(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
}

private extension UInt16 {
    func bigEndianBytes() -> Data {
        Data([UInt8(self >> 8), UInt8(self & 0xff)])
    }
}

private extension UInt32 {
    func bigEndianBytes() -> Data {
        Data([UInt8(self >> 24), UInt8(self >> 16 & 0xff), UInt8(self >> 8 & 0xff), UInt8(self & 0xff)])
    }
}
