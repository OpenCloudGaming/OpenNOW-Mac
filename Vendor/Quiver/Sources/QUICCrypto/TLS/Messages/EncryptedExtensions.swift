/// TLS 1.3 EncryptedExtensions Message (RFC 8446 Section 4.3.1)
///
/// ```
/// struct {
///     Extension extensions<0..2^16-1>;
/// } EncryptedExtensions;
/// ```

import Foundation

/// TLS 1.3 EncryptedExtensions message
public struct EncryptedExtensions: Sendable {

    /// Extensions in the message
    public let extensions: [TLSExtension]

    // MARK: - Initialization

    public init(extensions: [TLSExtension]) {
        self.extensions = extensions
    }

    // MARK: - Encoding

    /// Encodes the EncryptedExtensions content (without handshake header)
    public func encode() -> Data {
        var extensionData = Data()
        for ext in extensions {
            extensionData.append(ext.encode())
        }

        var writer = TLSWriter(capacity: 2 + extensionData.count)
        writer.writeVector16(extensionData)
        return writer.finish()
    }

    /// Encodes as a complete handshake message (with header)
    public func encodeAsHandshake() -> Data {
        HandshakeCodec.encode(type: .encryptedExtensions, content: encode())
    }

    // MARK: - Decoding

    /// Decodes EncryptedExtensions from content data (without handshake header)
    public static func decode(from data: Data) throws -> EncryptedExtensions {
        var reader = TLSReader(data: data)
        let extensionData = try reader.readVector16()

        var extensions: [TLSExtension] = []
        var extReader = TLSReader(data: extensionData)
        while extReader.hasMore {
            let ext = try TLSExtension.decode(from: &extReader)
            extensions.append(ext)
        }

        return EncryptedExtensions(extensions: extensions)
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

    /// Get ALPN extension
    public var alpn: ALPNExtension? {
        findExtension(ALPNExtension.self)
    }

    /// Get selected ALPN protocol
    public var selectedALPN: String? {
        alpn?.selectedProtocol
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

    /// Get server name extension
    public var serverName: ServerNameExtension? {
        findExtension(ServerNameExtension.self)
    }
}
