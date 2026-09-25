/// TLS 1.3 ClientHello Message (RFC 8446 Section 4.1.2)
///
/// ```
/// struct {
///     ProtocolVersion legacy_version = 0x0303;    /* TLS v1.2 */
///     Random random;
///     opaque legacy_session_id<0..32>;
///     CipherSuite cipher_suites<2..2^16-2>;
///     opaque legacy_compression_methods<1..2^8-1>;
///     Extension extensions<8..2^16-1>;
/// } ClientHello;
/// ```

import Foundation
import Crypto
/// TLS 1.3 ClientHello message
public struct ClientHello: Sendable {

    /// 32 bytes of random data
    public let random: Data

    /// Legacy session ID (can be non-empty for middlebox compatibility)
    public let legacySessionID: Data

    /// Cipher suites in preference order
    public let cipherSuites: [CipherSuite]

    /// Extensions (order matters for some extensions)
    public let extensions: [TLSExtension]

    // MARK: - Initialization

    /// Creates a ClientHello with the specified parameters
    public init(
        random: Data,
        legacySessionID: Data = Data(),
        cipherSuites: [CipherSuite],
        extensions: [TLSExtension]
    ) {
        precondition(random.count == TLSConstants.randomLength, "Random must be 32 bytes")
        precondition(legacySessionID.count <= TLSConstants.sessionIDMaxLength, "Session ID too long")
        self.random = random
        self.legacySessionID = legacySessionID
        self.cipherSuites = cipherSuites
        self.extensions = extensions
    }

    /// Creates a ClientHello with generated random
    public init(
        legacySessionID: Data = Data(),
        cipherSuites: [CipherSuite] = [.tls_aes_128_gcm_sha256],
        extensions: [TLSExtension]
    ) {
        let key = SymmetricKey(size: .bits256)
        let random = key.withUnsafeBytes { Data($0) }
        self.init(random: random, legacySessionID: legacySessionID, cipherSuites: cipherSuites, extensions: extensions)
    }

    // MARK: - Encoding

    /// Encodes the ClientHello content (without handshake header)
    public func encode() -> Data {
        var writer = TLSWriter(capacity: 512)

        // legacy_version (2 bytes) - always 0x0303 for TLS 1.3
        writer.writeUInt16(TLSConstants.legacyVersion)

        // random (32 bytes)
        writer.writeBytes(random)

        // legacy_session_id (variable, 1-byte length)
        writer.writeVector8(legacySessionID)

        // cipher_suites (variable, 2-byte length)
        var cipherSuiteData = Data(capacity: cipherSuites.count * 2)
        for suite in cipherSuites {
            cipherSuiteData.append(UInt8((suite.rawValue >> 8) & 0xFF))
            cipherSuiteData.append(UInt8(suite.rawValue & 0xFF))
        }
        writer.writeVector16(cipherSuiteData)

        // legacy_compression_methods (variable, 1-byte length) - must be [0x00]
        writer.writeVector8(Data([0x00]))

        // extensions (variable, 2-byte length)
        var extensionData = Data(capacity: 256)
        for ext in extensions {
            extensionData.append(ext.encode())
        }
        writer.writeVector16(extensionData)

        return writer.finish()
    }

    /// Encodes as a complete handshake message (with header)
    public func encodeAsHandshake() -> Data {
        HandshakeCodec.encode(type: .clientHello, content: encode())
    }

    // MARK: - Decoding

    /// Decodes a ClientHello from content data (without handshake header)
    public static func decode(from data: Data) throws -> ClientHello {
        var reader = TLSReader(data: data)

        // legacy_version
        let legacyVersion = try reader.readUInt16()
        guard legacyVersion == TLSConstants.legacyVersion else {
            throw TLSDecodeError.unsupportedVersion(legacyVersion)
        }

        // random
        let random = try reader.readBytes(TLSConstants.randomLength)

        // legacy_session_id
        let legacySessionID = try reader.readVector8()

        // cipher_suites
        let cipherSuiteData = try reader.readVector16()
        guard cipherSuiteData.count >= 2 && cipherSuiteData.count % 2 == 0 else {
            throw TLSDecodeError.invalidFormat("Invalid cipher suite length")
        }
        var cipherSuites: [CipherSuite] = []
        var csReader = TLSReader(data: cipherSuiteData)
        while csReader.hasMore {
            let value = try csReader.readUInt16()
            if let suite = CipherSuite(rawValue: value) {
                cipherSuites.append(suite)
            }
            // Unknown cipher suites are ignored
        }

        // legacy_compression_methods
        let compressionMethods = try reader.readVector8()
        guard compressionMethods.count >= 1 && compressionMethods[0] == 0x00 else {
            throw TLSDecodeError.invalidFormat("Invalid compression methods")
        }

        // extensions
        let extensionData = try reader.readVector16()
        var extensions: [TLSExtension] = []
        var extReader = TLSReader(data: extensionData)
        while extReader.hasMore {
            let ext = try TLSExtension.decode(from: &extReader)
            extensions.append(ext)
        }

        return ClientHello(
            random: random,
            legacySessionID: legacySessionID,
            cipherSuites: cipherSuites,
            extensions: extensions
        )
    }

    // MARK: - Extension Helpers

    /// Find an extension by type
    public func findExtension<T: TLSExtensionValue>(_ type: T.Type) -> T? {
        for ext in extensions {
            if let value = ext.value as? T {
                return value
            }
        }
        return nil
    }

    /// Get key share extension
    public var keyShare: KeyShareClientHello? {
        for ext in extensions {
            if case .keyShare(let wrapper) = ext {
                if case .clientHello(let keyShare) = wrapper {
                    return keyShare
                }
            }
        }
        return nil
    }

    /// Get supported versions extension
    public var supportedVersions: SupportedVersionsClientHello? {
        for ext in extensions {
            if case .supportedVersions(let wrapper) = ext {
                if case .clientHello(let versions) = wrapper {
                    return versions
                }
            }
        }
        return nil
    }

    /// Get ALPN extension
    public var alpn: ALPNExtension? {
        findExtension(ALPNExtension.self)
    }

    /// Get supported groups extension
    public var supportedGroups: SupportedGroupsExtension? {
        for ext in extensions {
            if case .supportedGroups(let groups) = ext {
                return groups
            }
        }
        return nil
    }

    /// Get QUIC transport parameters
    public var quicTransportParameters: Data? {
        for ext in extensions {
            if case .quicTransportParameters(let data) = ext {
                return data
            }
        }
        return nil
    }

    /// Get pre-shared key extension
    public var preSharedKey: OfferedPsks? {
        for ext in extensions {
            if case .preSharedKey(.clientHello(let offered)) = ext {
                return offered
            }
        }
        return nil
    }

    /// Get early_data extension
    public var earlyData: Bool {
        for ext in extensions {
            if case .earlyData = ext {
                return true
            }
        }
        return false
    }
}
