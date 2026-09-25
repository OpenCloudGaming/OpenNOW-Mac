/// TLS 1.3 Certificate Message (RFC 8446 Section 4.4.2)
///
/// ```
/// struct {
///     opaque certificate_request_context<0..2^8-1>;
///     CertificateEntry certificate_list<0..2^24-1>;
/// } Certificate;
///
/// struct {
///     select (certificate_type) {
///         case RawPublicKey:
///             opaque ASN1_subjectPublicKeyInfo<1..2^24-1>;
///         case X509:
///             opaque cert_data<1..2^24-1>;
///     };
///     Extension extensions<0..2^16-1>;
/// } CertificateEntry;
/// ```

import Foundation

// MARK: - Certificate Entry

/// A certificate entry in the Certificate message
public struct CertificateEntry: Sendable {
    /// The certificate data (DER-encoded X.509)
    public let certData: Data

    /// Extensions for this certificate (e.g., OCSP status)
    public let extensions: [TLSExtension]

    public init(certData: Data, extensions: [TLSExtension] = []) {
        self.certData = certData
        self.extensions = extensions
    }

    public func encode() -> Data {
        var extensionData = Data()
        for ext in extensions {
            extensionData.append(ext.encode())
        }

        var writer = TLSWriter(capacity: 3 + certData.count + 2 + extensionData.count)
        // cert_data<1..2^24-1>
        writer.writeVector24(certData)
        // extensions<0..2^16-1>
        writer.writeVector16(extensionData)
        return writer.finish()
    }

    public static func decode(from reader: inout TLSReader) throws -> CertificateEntry {
        let certData = try reader.readVector24()
        let extensionData = try reader.readVector16()

        var extensions: [TLSExtension] = []
        var extReader = TLSReader(data: extensionData)
        while extReader.hasMore {
            let ext = try TLSExtension.decode(from: &extReader)
            extensions.append(ext)
        }

        return CertificateEntry(certData: certData, extensions: extensions)
    }
}

// MARK: - Certificate Message

/// TLS 1.3 Certificate message
public struct Certificate: Sendable {

    /// The certificate request context (empty for server certificates)
    public let certificateRequestContext: Data

    /// The certificate chain (leaf first)
    public let certificateList: [CertificateEntry]

    // MARK: - Initialization

    public init(certificateRequestContext: Data = Data(), certificateList: [CertificateEntry]) {
        self.certificateRequestContext = certificateRequestContext
        self.certificateList = certificateList
    }

    /// Create from raw certificate data (DER-encoded)
    public init(certificateRequestContext: Data = Data(), certificates: [Data]) {
        self.certificateRequestContext = certificateRequestContext
        self.certificateList = certificates.map { CertificateEntry(certData: $0) }
    }

    // MARK: - Encoding

    /// Encodes the Certificate content (without handshake header)
    public func encode() -> Data {
        var certListData = Data()
        for entry in certificateList {
            certListData.append(entry.encode())
        }

        var writer = TLSWriter(capacity: 1 + certificateRequestContext.count + 3 + certListData.count)
        // certificate_request_context<0..2^8-1>
        writer.writeVector8(certificateRequestContext)
        // certificate_list<0..2^24-1>
        writer.writeVector24(certListData)
        return writer.finish()
    }

    /// Encodes as a complete handshake message (with header)
    public func encodeAsHandshake() -> Data {
        HandshakeCodec.encode(type: .certificate, content: encode())
    }

    // MARK: - Decoding

    /// Decodes Certificate from content data (without handshake header)
    public static func decode(from data: Data) throws -> Certificate {
        var reader = TLSReader(data: data)

        // certificate_request_context
        let certificateRequestContext = try reader.readVector8()

        // certificate_list
        let certListData = try reader.readVector24()
        var certificateList: [CertificateEntry] = []
        var listReader = TLSReader(data: certListData)
        while listReader.hasMore {
            certificateList.append(try CertificateEntry.decode(from: &listReader))
        }

        return Certificate(
            certificateRequestContext: certificateRequestContext,
            certificateList: certificateList
        )
    }

    // MARK: - Helpers

    /// Get the leaf (end-entity) certificate
    public var leafCertificate: Data? {
        certificateList.first?.certData
    }

    /// Get all certificate data (without extensions)
    public var certificates: [Data] {
        certificateList.map { $0.certData }
    }

    /// Whether the certificate chain is empty
    public var isEmpty: Bool {
        certificateList.isEmpty
    }
}
