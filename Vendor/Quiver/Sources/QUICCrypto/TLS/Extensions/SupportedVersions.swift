/// TLS 1.3 Supported Versions Extension (RFC 8446 Section 4.2.1)
///
/// In ClientHello:
/// ```
/// struct {
///     ProtocolVersion versions<2..254>;
/// } SupportedVersions;
/// ```
///
/// In ServerHello:
/// ```
/// struct {
///     ProtocolVersion selected_version;
/// } SupportedVersions;
/// ```

import Foundation

// MARK: - Supported Versions Extension (wrapper)

/// Supported versions extension (can be client or server variant)
public enum SupportedVersionsExtension: Sendable, TLSExtensionValue {
    case clientHello(SupportedVersionsClientHello)
    case serverHello(SupportedVersionsServerHello)

    public static var extensionType: TLSExtensionType { .supportedVersions }

    public func encode() -> Data {
        switch self {
        case .clientHello(let ext): return ext.encode()
        case .serverHello(let ext): return ext.encode()
        }
    }

    public static func decode(from data: Data) throws -> SupportedVersionsExtension {
        // Distinguish by length: ClientHello has 1-byte length prefix, ServerHello is exactly 2 bytes
        if data.count == 2 {
            return .serverHello(try SupportedVersionsServerHello.decode(from: data))
        } else {
            return .clientHello(try SupportedVersionsClientHello.decode(from: data))
        }
    }
}

// MARK: - Client Hello Variant

/// Supported versions for ClientHello
public struct SupportedVersionsClientHello: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .supportedVersions }

    /// List of supported TLS versions (in preference order)
    public let versions: [UInt16]

    public init(versions: [UInt16] = [TLSConstants.version13]) {
        self.versions = versions
    }

    public func encode() -> Data {
        var writer = TLSWriter(capacity: 1 + versions.count * 2)
        // versions<2..254> with 1-byte length prefix
        var versionsData = Data(capacity: versions.count * 2)
        for version in versions {
            versionsData.append(UInt8((version >> 8) & 0xFF))
            versionsData.append(UInt8(version & 0xFF))
        }
        writer.writeVector8(versionsData)
        return writer.finish()
    }

    public static func decode(from data: Data) throws -> SupportedVersionsClientHello {
        var reader = TLSReader(data: data)
        let versionsData = try reader.readVector8()

        guard versionsData.count >= 2 && versionsData.count % 2 == 0 else {
            throw TLSDecodeError.invalidFormat("Invalid supported versions length")
        }

        var versions: [UInt16] = []
        var vReader = TLSReader(data: versionsData)
        while vReader.hasMore {
            versions.append(try vReader.readUInt16())
        }

        return SupportedVersionsClientHello(versions: versions)
    }

    /// Whether TLS 1.3 is supported
    public var supportsTLS13: Bool {
        versions.contains(TLSConstants.version13)
    }
}

// MARK: - Server Hello Variant

/// Supported versions for ServerHello
public struct SupportedVersionsServerHello: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .supportedVersions }

    /// Selected TLS version
    public let selectedVersion: UInt16

    public init(selectedVersion: UInt16 = TLSConstants.version13) {
        self.selectedVersion = selectedVersion
    }

    public func encode() -> Data {
        var writer = TLSWriter(capacity: 2)
        writer.writeUInt16(selectedVersion)
        return writer.finish()
    }

    public static func decode(from data: Data) throws -> SupportedVersionsServerHello {
        var reader = TLSReader(data: data)
        let version = try reader.readUInt16()
        return SupportedVersionsServerHello(selectedVersion: version)
    }

    /// Whether TLS 1.3 was selected
    public var isTLS13: Bool {
        selectedVersion == TLSConstants.version13
    }
}
