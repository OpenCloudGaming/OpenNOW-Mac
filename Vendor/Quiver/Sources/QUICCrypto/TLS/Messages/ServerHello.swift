/// TLS 1.3 ServerHello Message (RFC 8446 Section 4.1.3)
///
/// ```
/// struct {
///     ProtocolVersion legacy_version = 0x0303;    /* TLS v1.2 */
///     Random random;
///     opaque legacy_session_id_echo<0..32>;
///     CipherSuite cipher_suite;
///     uint8 legacy_compression_method = 0;
///     Extension extensions<6..2^16-1>;
/// } ServerHello;
/// ```

import Foundation
import Crypto
/// TLS 1.3 ServerHello message
public struct ServerHello: Sendable {

    /// 32 bytes of random data
    public let random: Data

    /// Legacy session ID echo (must match ClientHello)
    public let legacySessionIDEcho: Data

    /// Selected cipher suite
    public let cipherSuite: CipherSuite

    /// Extensions (must contain key_share and supported_versions)
    public let extensions: [TLSExtension]

    // MARK: - Computed Properties

    /// Whether this is a HelloRetryRequest
    public var isHelloRetryRequest: Bool {
        random == TLSConstants.helloRetryRequestRandom
    }

    // MARK: - Initialization

    /// Creates a ServerHello with the specified parameters
    public init(
        random: Data,
        legacySessionIDEcho: Data,
        cipherSuite: CipherSuite,
        extensions: [TLSExtension]
    ) {
        precondition(random.count == TLSConstants.randomLength, "Random must be 32 bytes")
        self.random = random
        self.legacySessionIDEcho = legacySessionIDEcho
        self.cipherSuite = cipherSuite
        self.extensions = extensions
    }

    /// Creates a ServerHello with generated random
    public init(
        legacySessionIDEcho: Data,
        cipherSuite: CipherSuite,
        extensions: [TLSExtension]
    ) {
        let key = SymmetricKey(size: .bits256)
        let random = key.withUnsafeBytes { Data($0) }
        self.init(random: random, legacySessionIDEcho: legacySessionIDEcho, cipherSuite: cipherSuite, extensions: extensions)
    }

    /// Creates a HelloRetryRequest
    public static func helloRetryRequest(
        legacySessionIDEcho: Data,
        cipherSuite: CipherSuite,
        extensions: [TLSExtension]
    ) -> ServerHello {
        ServerHello(
            random: TLSConstants.helloRetryRequestRandom,
            legacySessionIDEcho: legacySessionIDEcho,
            cipherSuite: cipherSuite,
            extensions: extensions
        )
    }

    // MARK: - Encoding

    /// Encodes the ServerHello content (without handshake header)
    public func encode() -> Data {
        var writer = TLSWriter(capacity: 128)

        // legacy_version (2 bytes) - always 0x0303 for TLS 1.3
        writer.writeUInt16(TLSConstants.legacyVersion)

        // random (32 bytes)
        writer.writeBytes(random)

        // legacy_session_id_echo (variable, 1-byte length)
        writer.writeVector8(legacySessionIDEcho)

        // cipher_suite (2 bytes)
        writer.writeUInt16(cipherSuite.rawValue)

        // legacy_compression_method (1 byte) - must be 0x00
        writer.writeUInt8(0x00)

        // extensions (variable, 2-byte length)
        var extensionData = Data(capacity: 64)
        for ext in extensions {
            extensionData.append(ext.encode())
        }
        writer.writeVector16(extensionData)

        return writer.finish()
    }

    /// Encodes as a complete handshake message (with header)
    public func encodeAsHandshake() -> Data {
        HandshakeCodec.encode(type: .serverHello, content: encode())
    }

    // MARK: - Decoding

    /// Decodes a ServerHello from content data (without handshake header)
    public static func decode(from data: Data) throws -> ServerHello {
        var reader = TLSReader(data: data)

        // legacy_version
        let legacyVersion = try reader.readUInt16()
        guard legacyVersion == TLSConstants.legacyVersion else {
            throw TLSDecodeError.unsupportedVersion(legacyVersion)
        }

        // random
        let random = try reader.readBytes(TLSConstants.randomLength)

        // legacy_session_id_echo
        let legacySessionIDEcho = try reader.readVector8()

        // cipher_suite
        let cipherSuiteValue = try reader.readUInt16()
        guard let cipherSuite = CipherSuite(rawValue: cipherSuiteValue) else {
            throw TLSDecodeError.invalidFormat("Unknown cipher suite: \(cipherSuiteValue)")
        }

        // legacy_compression_method
        let compressionMethod = try reader.readUInt8()
        guard compressionMethod == 0x00 else {
            throw TLSDecodeError.invalidFormat("Invalid compression method: \(compressionMethod)")
        }

        // extensions
        let extensionData = try reader.readVector16()
        var extensions: [TLSExtension] = []
        var extReader = TLSReader(data: extensionData)
        while extReader.hasMore {
            let ext = try TLSExtension.decode(from: &extReader)
            extensions.append(ext)
        }

        return ServerHello(
            random: random,
            legacySessionIDEcho: legacySessionIDEcho,
            cipherSuite: cipherSuite,
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
    public var keyShare: KeyShareServerHello? {
        for ext in extensions {
            if case .keyShare(let wrapper) = ext {
                if case .serverHello(let keyShare) = wrapper {
                    return keyShare
                }
            }
        }
        return nil
    }

    /// Get supported versions extension
    public var supportedVersions: SupportedVersionsServerHello? {
        for ext in extensions {
            if case .supportedVersions(let wrapper) = ext {
                if case .serverHello(let versions) = wrapper {
                    return versions
                }
            }
        }
        return nil
    }

    /// Get the requested key share group from HelloRetryRequest
    /// Returns nil if this is not an HRR or if the key_share extension is missing
    public var helloRetryRequestSelectedGroup: NamedGroup? {
        guard isHelloRetryRequest else { return nil }

        for ext in extensions {
            if case .keyShare(let wrapper) = ext {
                // In HRR, key_share contains just a NamedGroup (2 bytes)
                // The current decoding might try to decode it as KeyShareServerHello
                // which would fail if the data is only 2 bytes
                if case .helloRetryRequest(let hrr) = wrapper {
                    return hrr.selectedGroup
                }
                // Fallback: try to extract from serverHello if it somehow decoded
                if case .serverHello(let keyShare) = wrapper {
                    return keyShare.serverShare.group
                }
            }
        }
        return nil
    }
}
