/// TLS 1.3 CertificateVerify Message (RFC 8446 Section 4.4.3)
///
/// ```
/// struct {
///     SignatureScheme algorithm;
///     opaque signature<0..2^16-1>;
/// } CertificateVerify;
/// ```
///
/// The signature is computed over:
/// ```
/// 64 spaces + "TLS 1.3, server CertificateVerify" + 0x00 + Transcript-Hash
/// ```
/// or for client:
/// ```
/// 64 spaces + "TLS 1.3, client CertificateVerify" + 0x00 + Transcript-Hash
/// ```

import Foundation

// MARK: - Certificate Verify Message

/// TLS 1.3 CertificateVerify message
public struct CertificateVerify: Sendable {

    /// Context string for server CertificateVerify
    public static let serverContext = "TLS 1.3, server CertificateVerify"

    /// Context string for client CertificateVerify
    public static let clientContext = "TLS 1.3, client CertificateVerify"

    /// The signature algorithm used
    public let algorithm: SignatureScheme

    /// The signature bytes
    public let signature: Data

    // MARK: - Initialization

    public init(algorithm: SignatureScheme, signature: Data) {
        self.algorithm = algorithm
        self.signature = signature
    }

    // MARK: - Encoding

    /// Encodes the CertificateVerify content (without handshake header)
    public func encode() -> Data {
        var writer = TLSWriter(capacity: 2 + 2 + signature.count)
        // algorithm (2 bytes)
        writer.writeUInt16(algorithm.rawValue)
        // signature<0..2^16-1>
        writer.writeVector16(signature)
        return writer.finish()
    }

    /// Encodes as a complete handshake message (with header)
    public func encodeAsHandshake() -> Data {
        HandshakeCodec.encode(type: .certificateVerify, content: encode())
    }

    // MARK: - Decoding

    /// Decodes CertificateVerify from content data (without handshake header)
    public static func decode(from data: Data) throws -> CertificateVerify {
        var reader = TLSReader(data: data)

        // algorithm
        let algorithmValue = try reader.readUInt16()
        guard let algorithm = SignatureScheme(rawValue: algorithmValue) else {
            throw TLSDecodeError.invalidFormat("Unknown signature scheme: \(algorithmValue)")
        }

        // signature
        let signature = try reader.readVector16()

        return CertificateVerify(algorithm: algorithm, signature: signature)
    }

    // MARK: - Signature Content Construction

    /// Constructs the content to be signed for CertificateVerify
    /// - Parameters:
    ///   - transcriptHash: The hash of the handshake transcript
    ///   - isServer: Whether this is for server (true) or client (false)
    /// - Returns: The content to sign
    public static func constructSignatureContent(
        transcriptHash: Data,
        isServer: Bool
    ) -> Data {
        let context = isServer ? serverContext : clientContext
        let contextData = Data(context.utf8)

        // 64 spaces + context + 0x00 + transcript_hash
        var content = Data(repeating: 0x20, count: 64)  // 64 spaces
        content.append(contextData)
        content.append(0x00)
        content.append(transcriptHash)

        return content
    }
}
