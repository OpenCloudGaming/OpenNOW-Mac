/// CertificateRequest - TLS 1.3 CertificateRequest message (RFC 8446 Section 4.3.2)
///
/// Used by servers to request client authentication in mutual TLS.
///
/// ```
/// struct {
///     opaque certificate_request_context<0..2^8-1>;
///     Extension extensions<2..2^16-1>;
/// } CertificateRequest;
/// ```

import Foundation

/// TLS 1.3 CertificateRequest message
public struct CertificateRequest: Sendable {

    /// The certificate_request_context is an opaque string that identifies
    /// the certificate request and is echoed in the client's Certificate message.
    public let certificateRequestContext: Data

    /// Extensions in this message indicate parameters the server wants
    /// for the client's certificate (e.g., signature_algorithms).
    public let extensions: [TLSExtension]

    // MARK: - Initialization

    /// Creates a CertificateRequest message
    ///
    /// - Parameters:
    ///   - certificateRequestContext: Context to be echoed by client (can be empty)
    ///   - extensions: Extensions specifying certificate requirements
    public init(
        certificateRequestContext: Data = Data(),
        extensions: [TLSExtension] = []
    ) {
        self.certificateRequestContext = certificateRequestContext
        self.extensions = extensions
    }

    /// Creates a CertificateRequest with default signature algorithms
    ///
    /// - Parameter certificateRequestContext: Context to be echoed by client
    /// - Returns: A CertificateRequest with standard signature algorithms
    public static func withDefaultSignatureAlgorithms(
        certificateRequestContext: Data = Data()
    ) -> CertificateRequest {
        // RFC 8446: signature_algorithms extension is REQUIRED
        let signatureAlgorithms = SignatureAlgorithmsExtension(supportedSignatureAlgorithms: [
            .ecdsa_secp256r1_sha256,
            .ecdsa_secp384r1_sha384,
            .ed25519,
            .rsa_pss_rsae_sha256,
            .rsa_pss_rsae_sha384,
            .rsa_pss_rsae_sha512
        ])

        return CertificateRequest(
            certificateRequestContext: certificateRequestContext,
            extensions: [.signatureAlgorithms(signatureAlgorithms)]
        )
    }

    // MARK: - Encoding

    /// Encodes the CertificateRequest content (without handshake header)
    public func encode() -> Data {
        var data = Data()

        // certificate_request_context<0..2^8-1>
        data.append(UInt8(certificateRequestContext.count))
        data.append(certificateRequestContext)

        // extensions<2..2^16-1>
        var extensionsData = Data()
        for ext in extensions {
            extensionsData.append(ext.encode())
        }

        // Extensions length (2 bytes)
        data.append(UInt8((extensionsData.count >> 8) & 0xFF))
        data.append(UInt8(extensionsData.count & 0xFF))
        data.append(extensionsData)

        return data
    }

    /// Encodes the CertificateRequest as a complete handshake message
    public func encodeAsHandshake() -> Data {
        let content = encode()
        return HandshakeCodec.encode(type: .certificateRequest, content: content)
    }

    // MARK: - Decoding

    /// Decodes a CertificateRequest from raw data
    ///
    /// - Parameter data: The raw CertificateRequest content (without handshake header)
    /// - Returns: Decoded CertificateRequest
    /// - Throws: If decoding fails
    public static func decode(from data: Data) throws -> CertificateRequest {
        var offset = 0

        guard data.count >= 1 else {
            throw TLSHandshakeError.decodeError("CertificateRequest too short")
        }

        // certificate_request_context<0..2^8-1>
        let contextLength = Int(data[offset])
        offset += 1

        guard data.count >= offset + contextLength else {
            throw TLSHandshakeError.decodeError("CertificateRequest context truncated")
        }

        let context = Data(data[offset..<(offset + contextLength)])
        offset += contextLength

        // extensions<2..2^16-1>
        guard data.count >= offset + 2 else {
            throw TLSHandshakeError.decodeError("CertificateRequest extensions length truncated")
        }

        let extensionsLength = Int(data[offset]) << 8 | Int(data[offset + 1])
        offset += 2

        guard data.count >= offset + extensionsLength else {
            throw TLSHandshakeError.decodeError("CertificateRequest extensions truncated")
        }

        let extensionsData = Data(data[offset..<(offset + extensionsLength)])
        let extensions = try TLSExtension.decodeExtensions(from: extensionsData)

        return CertificateRequest(
            certificateRequestContext: context,
            extensions: extensions
        )
    }

    // MARK: - Accessors

    /// Gets the signature algorithms requested by the server
    public var signatureAlgorithms: [SignatureScheme]? {
        for ext in extensions {
            if case .signatureAlgorithms(let sigAlgs) = ext {
                return sigAlgs.supportedSignatureAlgorithms
            }
        }
        return nil
    }
}
