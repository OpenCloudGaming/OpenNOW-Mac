/// QUIC Version (RFC 9000 Section 15)
///
/// QUIC versions are identified by a 32-bit unsigned number.

import Foundation

/// A QUIC protocol version
public struct QUICVersion: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // MARK: - Standard Versions

    /// QUIC Version 1 (RFC 9000)
    public static let v1 = QUICVersion(rawValue: 0x00000001)

    /// QUIC Version 2 (RFC 9369)
    public static let v2 = QUICVersion(rawValue: 0x6b3343cf)

    /// Version used for negotiation (reserved)
    public static let negotiation = QUICVersion(rawValue: 0x00000000)

    // MARK: - Version Properties

    /// Whether this is a known/supported version
    public var isSupported: Bool {
        self == .v1 || self == .v2
    }

    /// Whether this is a reserved version for negotiation
    public var isNegotiation: Bool {
        rawValue == 0
    }

    /// Whether this version uses the QUIC v1 wire format
    /// (Both v1 and v2 use the same wire format for packets)
    public var usesV1WireFormat: Bool {
        isSupported
    }

    // MARK: - Static Cryptographic Constants

    /// QUIC v1 initial salt (RFC 9001 Section 5.2)
    private static let v1InitialSalt = Data([
        0x38, 0x76, 0x2c, 0xf7, 0xf5, 0x59, 0x34, 0xb3,
        0x4d, 0x17, 0x9a, 0xe6, 0xa4, 0xc8, 0x0c, 0xad,
        0xcc, 0xbb, 0x7f, 0x0a
    ])

    /// QUIC v2 initial salt (RFC 9369)
    private static let v2InitialSalt = Data([
        0x0d, 0xed, 0xe3, 0xde, 0xf7, 0x00, 0xa6, 0xdb,
        0x81, 0x93, 0x81, 0xbe, 0x6e, 0x26, 0x9d, 0xcb,
        0xf9, 0xbd, 0x2e, 0xd9
    ])

    /// QUIC v1 retry integrity key
    private static let v1RetryIntegrityKey = Data([
        0xbe, 0x0c, 0x69, 0x0b, 0x9f, 0x66, 0x57, 0x5a,
        0x1d, 0x76, 0x6b, 0x54, 0xe3, 0x68, 0xc8, 0x4e
    ])

    /// QUIC v2 retry integrity key
    private static let v2RetryIntegrityKey = Data([
        0x8f, 0xb4, 0xb0, 0x1b, 0x56, 0xac, 0x48, 0xe2,
        0x60, 0xfb, 0xcb, 0xce, 0xad, 0x7c, 0xcc, 0x92
    ])

    /// QUIC v1 retry integrity nonce
    private static let v1RetryIntegrityNonce = Data([
        0x46, 0x15, 0x99, 0xd3, 0x5d, 0x63, 0x2b, 0xf2,
        0x23, 0x98, 0x25, 0xbb
    ])

    /// QUIC v2 retry integrity nonce
    private static let v2RetryIntegrityNonce = Data([
        0xd8, 0x69, 0x69, 0xbc, 0x2d, 0x7c, 0x6d, 0x99,
        0x90, 0xef, 0xb0, 0x4a
    ])

    // MARK: - Initial Salt

    /// Returns the initial salt for key derivation (RFC 9001 Section 5.2)
    public var initialSalt: Data? {
        switch self {
        case .v1: return Self.v1InitialSalt
        case .v2: return Self.v2InitialSalt
        default: return nil
        }
    }

    // MARK: - Retry Integrity

    /// Returns the retry integrity key for this version
    public var retryIntegrityKey: Data? {
        switch self {
        case .v1: return Self.v1RetryIntegrityKey
        case .v2: return Self.v2RetryIntegrityKey
        default: return nil
        }
    }

    /// Returns the retry integrity nonce for this version
    public var retryIntegrityNonce: Data? {
        switch self {
        case .v1: return Self.v1RetryIntegrityNonce
        case .v2: return Self.v2RetryIntegrityNonce
        default: return nil
        }
    }
}

// MARK: - Encoding/Decoding

extension QUICVersion {
    /// Encodes the version as 4 bytes (big-endian)
    public func encode(to data: inout Data) {
        data.append(UInt8(rawValue >> 24))
        data.append(UInt8((rawValue >> 16) & 0xFF))
        data.append(UInt8((rawValue >> 8) & 0xFF))
        data.append(UInt8(rawValue & 0xFF))
    }

    /// Decodes a version from 4 bytes
    public static func decode(from reader: inout DataReader) -> QUICVersion? {
        guard let value = reader.readUInt32() else { return nil }
        return QUICVersion(rawValue: value)
    }
}

// MARK: - CustomStringConvertible

extension QUICVersion: CustomStringConvertible {
    public var description: String {
        switch self {
        case .v1:
            return "QUICv1"
        case .v2:
            return "QUICv2"
        case .negotiation:
            return "QUIC(negotiation)"
        default:
            return "QUIC(0x\(String(format: "%08x", rawValue)))"
        }
    }
}

// MARK: - Supported Versions

extension QUICVersion {
    /// List of supported versions in preference order
    public static let supportedVersions: [QUICVersion] = [.v1, .v2]

    /// Checks if a version is in the supported list
    public static func isVersionSupported(_ version: QUICVersion) -> Bool {
        supportedVersions.contains(version)
    }
}
