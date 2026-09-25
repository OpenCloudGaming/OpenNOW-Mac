/// PEM File Loader for Certificates and Private Keys
///
/// Provides utilities to load PEM-encoded certificates and private keys
/// from files, converting them to DER format for use in TLS.

import Foundation
import Crypto

// MARK: - PEM Loader

/// Utility for loading PEM-encoded certificates and private keys
public enum PEMLoader {

    // MARK: - PEM Types

    /// PEM block types
    public enum PEMType: String, Sendable {
        case certificate = "CERTIFICATE"
        case privateKey = "PRIVATE KEY"
        case ecPrivateKey = "EC PRIVATE KEY"
        case rsaPrivateKey = "RSA PRIVATE KEY"
        case publicKey = "PUBLIC KEY"
    }

    // MARK: - Errors

    /// Errors during PEM loading
    public enum PEMError: Error, Sendable {
        case fileNotFound(String)
        case readError(String)
        case invalidPEMFormat(String)
        case noPEMBlockFound(PEMType)
        case base64DecodingFailed
        case unsupportedKeyType(String)
        case invalidKeyFormat(String)
        case asn1ParsingError(String)
    }

    // MARK: - Certificate Loading

    /// Load certificates from a PEM file
    /// - Parameter path: Path to the PEM file
    /// - Returns: Array of DER-encoded certificates
    /// - Throws: PEMError if loading fails
    public static func loadCertificates(fromPath path: String) throws -> [Data] {
        let pemContent = try readFile(at: path)
        return try parsePEMBlocks(pemContent, type: .certificate)
    }

    /// Load a single certificate from a PEM file
    /// - Parameter path: Path to the PEM file
    /// - Returns: DER-encoded certificate data
    /// - Throws: PEMError if loading fails
    public static func loadCertificate(fromPath path: String) throws -> Data {
        let certificates = try loadCertificates(fromPath: path)
        guard let first = certificates.first else {
            throw PEMError.noPEMBlockFound(.certificate)
        }
        return first
    }

    /// Parse certificates from PEM string
    /// - Parameter pemString: PEM-encoded string
    /// - Returns: Array of DER-encoded certificates
    public static func parseCertificates(from pemString: String) throws -> [Data] {
        return try parsePEMBlocks(pemString, type: .certificate)
    }

    // MARK: - Private Key Loading

    /// Load a private key from a PEM file
    /// - Parameter path: Path to the PEM file
    /// - Returns: SigningKey suitable for TLS operations
    /// - Throws: PEMError if loading fails
    public static func loadPrivateKey(fromPath path: String) throws -> SigningKey {
        let pemContent = try readFile(at: path)
        return try parsePrivateKey(from: pemContent)
    }

    /// Parse a private key from PEM string
    /// - Parameter pemString: PEM-encoded string
    /// - Returns: SigningKey suitable for TLS operations
    public static func parsePrivateKey(from pemString: String) throws -> SigningKey {
        // Try PKCS#8 format first (generic "PRIVATE KEY")
        if let derData = try? parsePEMBlocks(pemString, type: .privateKey).first {
            return try parsePrivateKeyFromPKCS8(derData)
        }

        // Try SEC1/RFC 5915 format ("EC PRIVATE KEY")
        if let derData = try? parsePEMBlocks(pemString, type: .ecPrivateKey).first {
            return try parseECPrivateKeyFromSEC1(derData)
        }

        // Try RSA format (not supported, but give a clear error)
        if (try? parsePEMBlocks(pemString, type: .rsaPrivateKey).first) != nil {
            throw PEMError.unsupportedKeyType("RSA keys are not supported. Use ECDSA (P-256, P-384) or Ed25519.")
        }

        throw PEMError.noPEMBlockFound(.privateKey)
    }

    // MARK: - File Operations

    /// Read file contents as string
    private static func readFile(at path: String) throws -> String {
        let url = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            throw PEMError.fileNotFound(path)
        }

        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw PEMError.readError("Failed to read file at \(path): \(error.localizedDescription)")
        }
    }

    // MARK: - PEM Parsing

    /// Parse PEM blocks of a specific type from content
    /// - Parameters:
    ///   - content: PEM-encoded content
    ///   - type: The type of PEM block to extract
    /// - Returns: Array of DER-encoded data blocks
    private static func parsePEMBlocks(_ content: String, type: PEMType) throws -> [Data] {
        let beginMarker = "-----BEGIN \(type.rawValue)-----"
        let endMarker = "-----END \(type.rawValue)-----"

        var results: [Data] = []
        var searchRange = content.startIndex..<content.endIndex

        while let beginRange = content.range(of: beginMarker, range: searchRange) {
            guard let endRange = content.range(of: endMarker, range: beginRange.upperBound..<content.endIndex) else {
                throw PEMError.invalidPEMFormat("Missing end marker for \(type.rawValue)")
            }

            // Extract base64 content between markers
            let base64Content = content[beginRange.upperBound..<endRange.lowerBound]
            let cleanedBase64 = base64Content
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: " ", with: "")

            guard let derData = Data(base64Encoded: cleanedBase64) else {
                throw PEMError.base64DecodingFailed
            }

            results.append(derData)
            searchRange = endRange.upperBound..<content.endIndex
        }

        if results.isEmpty {
            throw PEMError.noPEMBlockFound(type)
        }

        return results
    }

    // MARK: - PKCS#8 Parsing

    /// Parse a private key from PKCS#8 DER format
    /// - Parameter derData: DER-encoded PKCS#8 private key
    /// - Returns: SigningKey
    private static func parsePrivateKeyFromPKCS8(_ derData: Data) throws -> SigningKey {
        // PKCS#8 PrivateKeyInfo structure:
        // SEQUENCE {
        //   version INTEGER
        //   algorithm AlgorithmIdentifier
        //   privateKey OCTET STRING (contains the actual key)
        // }
        //
        // AlgorithmIdentifier:
        // SEQUENCE {
        //   algorithm OBJECT IDENTIFIER
        //   parameters ANY OPTIONAL
        // }

        var index = 0

        // Parse outer SEQUENCE
        guard derData.count > 2 else {
            throw PEMError.asn1ParsingError("Data too short")
        }

        guard derData[index] == 0x30 else { // SEQUENCE tag
            throw PEMError.asn1ParsingError("Expected SEQUENCE")
        }
        index += 1

        // Skip length (can be 1-3 bytes)
        let (_, lengthBytes) = try parseASN1Length(derData, at: index)
        index += lengthBytes

        // Skip version INTEGER
        guard derData[index] == 0x02 else { // INTEGER tag
            throw PEMError.asn1ParsingError("Expected INTEGER for version")
        }
        index += 1
        let versionLength = Int(derData[index])
        index += 1 + versionLength

        // Parse AlgorithmIdentifier SEQUENCE
        guard derData[index] == 0x30 else {
            throw PEMError.asn1ParsingError("Expected SEQUENCE for AlgorithmIdentifier")
        }
        index += 1
        let (algIdLength, algLengthBytes) = try parseASN1Length(derData, at: index)
        index += algLengthBytes

        // Parse algorithm OID
        guard derData[index] == 0x06 else { // OBJECT IDENTIFIER tag
            throw PEMError.asn1ParsingError("Expected OBJECT IDENTIFIER")
        }
        index += 1
        let oidLength = Int(derData[index])
        index += 1

        let oidBytes = Array(derData[index..<(index + oidLength)])
        index += oidLength

        // Determine key type from OID
        let keyType = try determineKeyType(fromOID: oidBytes)

        // Skip any remaining algorithm parameters
        let remainingAlgIdBytes = algIdLength - 2 - oidLength
        if remainingAlgIdBytes > 0 {
            index += remainingAlgIdBytes
        }

        // Parse privateKey OCTET STRING
        guard derData[index] == 0x04 else { // OCTET STRING tag
            throw PEMError.asn1ParsingError("Expected OCTET STRING for private key")
        }
        index += 1
        let (privateKeyLength, pkLengthBytes) = try parseASN1Length(derData, at: index)
        index += pkLengthBytes

        let privateKeyData = Data(derData[index..<(index + privateKeyLength)])

        return try createSigningKey(from: privateKeyData, type: keyType)
    }

    // MARK: - SEC1/RFC 5915 EC Private Key Parsing

    /// Parse an EC private key from SEC1/RFC 5915 DER format
    /// - Parameter derData: DER-encoded SEC1 EC private key
    /// - Returns: SigningKey
    private static func parseECPrivateKeyFromSEC1(_ derData: Data) throws -> SigningKey {
        // ECPrivateKey structure (RFC 5915):
        // SEQUENCE {
        //   version INTEGER (1)
        //   privateKey OCTET STRING
        //   [0] parameters ECParameters (curve OID) OPTIONAL
        //   [1] publicKey BIT STRING OPTIONAL
        // }

        var index = 0

        // Parse outer SEQUENCE
        guard derData[index] == 0x30 else {
            throw PEMError.asn1ParsingError("Expected SEQUENCE")
        }
        index += 1
        let (_, lengthBytes) = try parseASN1Length(derData, at: index)
        index += lengthBytes

        // Skip version INTEGER
        guard derData[index] == 0x02 else {
            throw PEMError.asn1ParsingError("Expected INTEGER for version")
        }
        index += 1
        let versionLength = Int(derData[index])
        index += 1 + versionLength

        // Parse privateKey OCTET STRING
        guard derData[index] == 0x04 else {
            throw PEMError.asn1ParsingError("Expected OCTET STRING for private key")
        }
        index += 1
        let privateKeyLength = Int(derData[index])
        index += 1

        let rawPrivateKey = Data(derData[index..<(index + privateKeyLength)])
        index += privateKeyLength

        // Try to find the curve OID in [0] tagged parameters
        var curveType: KeyType = .p256  // Default to P-256

        if index < derData.count && derData[index] == 0xA0 { // Context tag [0]
            index += 1
            let (paramLength, paramLengthBytes) = try parseASN1Length(derData, at: index)
            index += paramLengthBytes

            // Parse the OID inside
            if index < derData.count && derData[index] == 0x06 {
                index += 1
                let oidLength = Int(derData[index])
                index += 1
                let oidBytes = Array(derData[index..<min(index + oidLength, derData.count)])
                curveType = try determineCurveType(fromOID: oidBytes)
            }
            _ = paramLength // Acknowledge we've processed the parameter
        }

        // Determine key type from private key length if OID wasn't found
        if curveType == .p256 {
            if rawPrivateKey.count == 32 {
                curveType = .p256
            } else if rawPrivateKey.count == 48 {
                curveType = .p384
            }
        }

        return try createSigningKey(fromRaw: rawPrivateKey, type: curveType)
    }

    // MARK: - ASN.1 Helpers

    /// Parse ASN.1 length encoding
    /// - Parameters:
    ///   - data: The data buffer
    ///   - offset: Current offset in the buffer
    /// - Returns: Tuple of (length value, number of bytes consumed)
    private static func parseASN1Length(_ data: Data, at offset: Int) throws -> (Int, Int) {
        guard offset < data.count else {
            throw PEMError.asn1ParsingError("Unexpected end of data")
        }

        let firstByte = data[offset]

        if firstByte & 0x80 == 0 {
            // Short form: length is the value itself
            return (Int(firstByte), 1)
        } else {
            // Long form: first byte indicates number of length bytes
            let numLengthBytes = Int(firstByte & 0x7F)
            guard offset + 1 + numLengthBytes <= data.count else {
                throw PEMError.asn1ParsingError("Length extends beyond data")
            }

            var length = 0
            for i in 0..<numLengthBytes {
                length = (length << 8) | Int(data[offset + 1 + i])
            }

            return (length, 1 + numLengthBytes)
        }
    }

    // MARK: - Key Type Detection

    /// Key algorithm types
    private enum KeyType {
        case p256
        case p384
        case ed25519
    }

    /// Determine key type from algorithm OID bytes
    private static func determineKeyType(fromOID oidBytes: [UInt8]) throws -> KeyType {
        // Common OIDs:
        // id-ecPublicKey: 1.2.840.10045.2.1 -> [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
        // id-Ed25519: 1.3.101.112 -> [0x2B, 0x65, 0x70]

        if oidBytes == [0x2B, 0x65, 0x70] {
            return .ed25519
        }

        // For EC keys, we need to check the parameters for the curve
        if oidBytes == [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01] {
            // This is ecPublicKey, curve is in parameters (handled separately)
            return .p256  // Default, will be overridden by parameter parsing
        }

        throw PEMError.unsupportedKeyType("Unknown key algorithm OID: \(oidBytes.map { String(format: "%02X", $0) }.joined())")
    }

    /// Determine curve type from curve OID bytes
    private static func determineCurveType(fromOID oidBytes: [UInt8]) throws -> KeyType {
        // Common curve OIDs:
        // secp256r1 (P-256): 1.2.840.10045.3.1.7 -> [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
        // secp384r1 (P-384): 1.3.132.0.34 -> [0x2B, 0x81, 0x04, 0x00, 0x22]
        // secp521r1 (P-521): 1.3.132.0.35 -> [0x2B, 0x81, 0x04, 0x00, 0x23]

        if oidBytes == [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07] {
            return .p256
        }

        if oidBytes == [0x2B, 0x81, 0x04, 0x00, 0x22] {
            return .p384
        }

        throw PEMError.unsupportedKeyType("Unsupported curve OID: \(oidBytes.map { String(format: "%02X", $0) }.joined())")
    }

    // MARK: - SigningKey Creation

    /// Create a SigningKey from PKCS#8 private key data
    private static func createSigningKey(from pkcs8PrivateKey: Data, type: KeyType) throws -> SigningKey {
        switch type {
        case .ed25519:
            // Ed25519 PKCS#8 contains the raw key wrapped in OCTET STRING
            // Need to extract the 32-byte raw key
            let rawKey = try extractEd25519RawKey(from: pkcs8PrivateKey)
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
            return .ed25519(key)

        case .p256:
            // P-256 PKCS#8 contains SEC1 ECPrivateKey
            return try parseECPrivateKeyFromSEC1(pkcs8PrivateKey)

        case .p384:
            // P-384 PKCS#8 contains SEC1 ECPrivateKey
            return try parseECPrivateKeyFromSEC1(pkcs8PrivateKey)
        }
    }

    /// Create a SigningKey from raw key bytes
    private static func createSigningKey(fromRaw rawKey: Data, type: KeyType) throws -> SigningKey {
        switch type {
        case .p256:
            do {
                let key = try P256.Signing.PrivateKey(rawRepresentation: rawKey)
                return .p256(key)
            } catch {
                throw PEMError.invalidKeyFormat("Failed to create P-256 key: \(error)")
            }

        case .p384:
            do {
                let key = try P384.Signing.PrivateKey(rawRepresentation: rawKey)
                return .p384(key)
            } catch {
                throw PEMError.invalidKeyFormat("Failed to create P-384 key: \(error)")
            }

        case .ed25519:
            do {
                let key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
                return .ed25519(key)
            } catch {
                throw PEMError.invalidKeyFormat("Failed to create Ed25519 key: \(error)")
            }
        }
    }

    /// Extract raw Ed25519 key from PKCS#8 OCTET STRING wrapper
    private static func extractEd25519RawKey(from data: Data) throws -> Data {
        // Ed25519 private key in PKCS#8 is wrapped as:
        // OCTET STRING containing the 32-byte raw key
        // Sometimes there's an extra OCTET STRING wrapper

        var index = 0

        // Check for OCTET STRING wrapper
        if data.count > 2 && data[index] == 0x04 {
            index += 1
            let length = Int(data[index])
            index += 1

            // If length is 32, we have the raw key
            if length == 32 && index + 32 <= data.count {
                return Data(data[index..<(index + 32)])
            }

            // Check for another OCTET STRING wrapper
            if data[index] == 0x04 {
                index += 1
                let innerLength = Int(data[index])
                index += 1
                if innerLength == 32 && index + 32 <= data.count {
                    return Data(data[index..<(index + 32)])
                }
            }
        }

        // If data is exactly 32 bytes, use it directly
        if data.count == 32 {
            return data
        }

        throw PEMError.invalidKeyFormat("Could not extract Ed25519 raw key")
    }
}

// MARK: - Convenience Extensions

extension PEMLoader {

    /// Load certificate chain and private key from PEM files
    /// - Parameters:
    ///   - certificatePath: Path to certificate PEM file (may contain chain)
    ///   - privateKeyPath: Path to private key PEM file
    /// - Returns: Tuple of (certificate chain as [Data], signing key)
    public static func loadCertificateAndKey(
        certificatePath: String,
        privateKeyPath: String
    ) throws -> (certificateChain: [Data], signingKey: SigningKey) {
        let certificates = try loadCertificates(fromPath: certificatePath)
        let signingKey = try loadPrivateKey(fromPath: privateKeyPath)
        return (certificates, signingKey)
    }

    // MARK: - Trusted CA Loading Helpers

    /// Load trusted CA certificates from a PEM file as parsed `X509Certificate` objects.
    ///
    /// This is a convenience method for populating `TLSConfiguration.trustedRootCertificates`
    /// from PEM CA bundle files (e.g., `/etc/ssl/certs/ca-certificates.crt`).
    ///
    /// - Parameter path: Path to a PEM file containing one or more CA certificates
    /// - Returns: Array of parsed `X509Certificate` objects
    /// - Throws: `PEMError` if loading fails, or `X509Error` if parsing fails
    public static func loadCACertificates(fromPath path: String) throws -> [X509Certificate] {
        let derCerts = try loadCertificates(fromPath: path)
        return try derCerts.map { try X509Certificate.parse(from: $0) }
    }

    /// Parse trusted CA certificates from a PEM-encoded string as parsed `X509Certificate` objects.
    ///
    /// Useful for loading CA certificates from embedded strings or configuration values.
    ///
    /// - Parameter pemString: PEM-encoded string containing one or more CA certificates
    /// - Returns: Array of parsed `X509Certificate` objects
    /// - Throws: `PEMError` if parsing the PEM format fails, or `X509Error` if certificate parsing fails
    public static func parseCACertificates(from pemString: String) throws -> [X509Certificate] {
        let derCerts = try parseCertificates(from: pemString)
        return try derCerts.map { try X509Certificate.parse(from: $0) }
    }

    /// Parse trusted CA certificates from DER-encoded data into `X509Certificate` objects.
    ///
    /// - Parameter derCertificates: Array of DER-encoded certificate data
    /// - Returns: Array of parsed `X509Certificate` objects
    /// - Throws: `X509Error` if any certificate fails to parse
    public static func parseCACertificates(fromDER derCertificates: [Data]) throws -> [X509Certificate] {
        try derCertificates.map { try X509Certificate.parse(from: $0) }
    }
}
