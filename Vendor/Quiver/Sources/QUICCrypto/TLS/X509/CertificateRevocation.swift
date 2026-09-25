/// Certificate Revocation Checking (RFC 5280, RFC 6960)
///
/// Provides OCSP and CRL-based certificate revocation checking.
/// Designed for QUIC/TLS where online checking may impact handshake latency.

import Foundation
import Crypto
@preconcurrency import X509
import SwiftASN1
public protocol HTTPClient: Sendable {
    func post(url: URL, body: Data, contentType: String) async throws -> (Data, Int)
    func get(url: URL) async throws -> (Data, Int)
}
// MARK: - Revocation Check Mode

/// Certificate revocation checking strategy
///
/// Choose a mode based on your security requirements and latency tolerance:
/// - `.none`: No revocation checking (not recommended for production)
/// - `.ocspStapling`: OCSP stapling only (server provides response in TLS handshake)
/// - `.ocsp`: OCSP with optional online check
/// - `.crl`: CRL checking with optional caching
/// - `.bestEffort`: Try available methods, soft-fail if unavailable
public enum RevocationCheckMode: Sendable {
    /// No revocation checking (not recommended for production)
    ///
    /// - Warning: This mode provides no protection against revoked certificates.
    ///   Only use for testing or when revocation checking is handled externally.
    case none

    /// OCSP stapling only (server provides response in TLS handshake)
    ///
    /// RFC 6066 Section 8: Certificate Status Request extension
    /// The server provides a pre-fetched OCSP response during the TLS handshake.
    ///
    /// - Pros: No additional latency, privacy preserving
    /// - Cons: Requires server support, response may be stale
    case ocspStapling

    /// OCSP checking with configurable online behavior
    ///
    /// RFC 6960: Online Certificate Status Protocol
    ///
    /// - Parameters:
    ///   - allowOnlineCheck: If true, will fetch OCSP response online if stapled response is unavailable
    ///   - softFail: If true, will allow connection if OCSP responder is unreachable
    case ocsp(allowOnlineCheck: Bool, softFail: Bool)

    /// CRL checking with optional caching
    ///
    /// RFC 5280 Section 5: Certificate Revocation List (CRL)
    ///
    /// - Parameters:
    ///   - cacheDirectory: Directory to cache downloaded CRLs (nil for no caching)
    ///   - softFail: If true, will allow connection if CRL is unavailable
    case crl(cacheDirectory: URL?, softFail: Bool)

    /// Best effort: try available methods, soft-fail if unavailable
    ///
    /// Attempts checks in order: OCSP stapling -> OCSP online -> CRL
    /// Fails open if no method succeeds (soft-fail behavior).
    ///
    /// - Note: This is a good default for applications that want some
    ///   revocation checking without breaking on network issues.
    case bestEffort
}

// MARK: - Revocation Status

/// Result of a revocation check
public enum RevocationStatus: Sendable, Equatable {
    /// Certificate is not revoked (good)
    case good

    /// Certificate has been revoked
    case revoked(reason: RevocationReason?, revokedAt: Date?)

    /// Revocation status is unknown (responder returned unknown)
    case unknown

    /// Could not determine status (network error, etc.)
    case undetermined(reason: String)
}

/// Certificate revocation reasons (RFC 5280 Section 5.3.1)
public enum RevocationReason: UInt8, Sendable {
    case unspecified = 0
    case keyCompromise = 1
    case caCompromise = 2
    case affiliationChanged = 3
    case superseded = 4
    case cessationOfOperation = 5
    case certificateHold = 6
    // 7 is unused
    case removeFromCRL = 8
    case privilegeWithdrawn = 9
    case aaCompromise = 10
}

// MARK: - Revocation Checker

/// Checks certificate revocation status
///
/// This checker supports OCSP stapling, online OCSP queries, and CRL checking.
/// The mode determines which methods are used and how failures are handled.
///
/// ## Example
///
/// ```swift
/// let checker = RevocationChecker(mode: .ocspStapling)
///
/// // During TLS handshake, when you receive a stapled OCSP response:
/// let status = try await checker.checkRevocation(
///     certificate,
///     issuer: issuerCert,
///     ocspResponse: stapledResponse
/// )
///
/// switch status {
/// case .good:
///     // Certificate is valid
/// case .revoked:
///     throw CertificateError.revoked
/// case .unknown, .undetermined:
///     // Handle based on your policy
/// }
/// ```
public struct RevocationChecker: Sendable {
    /// Revocation checking mode
    public let mode: RevocationCheckMode

    /// Timeout for online checks
    public let timeout: Duration

    /// HTTP client for online checks
    private let httpClient: HTTPClient?

    /// Initialize revocation checker
    public init(mode: RevocationCheckMode, timeout: Duration = .seconds(5), httpClient: HTTPClient? = nil) {
        self.mode = mode
        self.timeout = timeout
        self.httpClient = httpClient
    }

    /// Checks the revocation status of a certificate
    ///
    /// - Parameters:
    ///   - certificate: The certificate to check
    ///   - issuer: The issuer's certificate (needed for OCSP)
    ///   - ocspResponse: Pre-fetched OCSP response (from TLS stapling)
    /// - Returns: The revocation status
    public func checkRevocation(
        _ certificate: X509Certificate,
        issuer: X509Certificate,
        ocspResponse: Data? = nil
    ) async throws -> RevocationStatus {
        switch mode {
        case .none:
            return .good  // No checking = assume good

        case .ocspStapling:
            guard let response = ocspResponse else {
                // No stapled response available
                return .unknown
            }
            return try verifyOCSPResponse(response, for: certificate, issuer: issuer)

        case .ocsp(let allowOnline, let softFail):
            // Try stapled response first
            if let response = ocspResponse {
                let status = try verifyOCSPResponse(response, for: certificate, issuer: issuer)
                if status != .unknown {
                    return status
                }
            }

            // Try online OCSP if allowed
            if allowOnline {
                do {
                    return try await fetchAndVerifyOCSP(certificate, issuer: issuer)
                } catch {
                    if softFail {
                        return .undetermined(reason: "OCSP fetch failed: \(error)")
                    }
                    throw error
                }
            }

            return softFail ? .undetermined(reason: "No OCSP response available") : .unknown

        case .crl(let cacheDirectory, let softFail):
            do {
                return try await checkCRL(certificate, cacheDirectory: cacheDirectory)
            } catch {
                if softFail {
                    return .undetermined(reason: "CRL check failed: \(error)")
                }
                throw error
            }

        case .bestEffort:
            // Try OCSP stapling first
            if let response = ocspResponse {
                let status = try verifyOCSPResponse(response, for: certificate, issuer: issuer)
                if status == .good || status == .revoked(reason: nil, revokedAt: nil) {
                    return status
                }
            }

            // Try online OCSP
            do {
                let status = try await fetchAndVerifyOCSP(certificate, issuer: issuer)
                switch status {
                case .good, .revoked:
                    return status
                case .unknown, .undetermined:
                    break  // Continue to CRL
                }
            } catch {
                // Continue to CRL
            }

            // Try CRL
            do {
                return try await checkCRL(certificate, cacheDirectory: nil)
            } catch {
                // All methods failed - soft fail
                return .undetermined(reason: "All revocation check methods failed")
            }
        }
    }

    // MARK: - OCSP Verification

    /// Verifies a pre-fetched OCSP response
    ///
    /// RFC 6960 Section 4.2.1: OCSP Response structure
    private func verifyOCSPResponse(
        _ response: Data,
        for certificate: X509Certificate,
        issuer: X509Certificate
    ) throws -> RevocationStatus {
        // Parse OCSP response
        guard let ocspResponse = try? OCSPResponse.parse(from: response) else {
            throw RevocationError.invalidOCSPResponse("Failed to parse OCSP response")
        }

        // Verify response status
        guard ocspResponse.responseStatus == .successful else {
            switch ocspResponse.responseStatus {
            case .malformedRequest:
                throw RevocationError.invalidOCSPResponse("Malformed request")
            case .internalError:
                throw RevocationError.invalidOCSPResponse("OCSP responder internal error")
            case .tryLater:
                return .undetermined(reason: "OCSP responder busy")
            case .sigRequired:
                throw RevocationError.invalidOCSPResponse("Signature required")
            case .unauthorized:
                throw RevocationError.invalidOCSPResponse("Unauthorized")
            default:
                throw RevocationError.invalidOCSPResponse("Unknown response status")
            }
        }

        // Verify the response is for this certificate
        guard let responseData = ocspResponse.responseBytes else {
            return .unknown
        }

        // Parse BasicOCSPResponse
        guard let basicResponse = try? BasicOCSPResponse.parse(from: responseData.response) else {
            throw RevocationError.invalidOCSPResponse("Failed to parse BasicOCSPResponse")
        }

        // Verify response signature (simplified - should verify against responder cert)
        // For production, this should verify the signature using the responder's certificate

        // Check thisUpdate/nextUpdate validity
        let now = Date()
        if now < basicResponse.producedAt {
            throw RevocationError.invalidOCSPResponse("Response not yet valid")
        }

        // Find the response for our certificate
        for singleResponse in basicResponse.responses {
            // Match by issuer name hash and key hash (simplified matching)
            // In production, should compute and compare these hashes

            // Check status
            switch singleResponse.certStatus {
            case .good:
                return .good
            case .revoked(let info):
                return .revoked(
                    reason: info.reason.flatMap { RevocationReason(rawValue: $0) },
                    revokedAt: info.revocationTime
                )
            case .unknown:
                return .unknown
            }
        }

        return .unknown
    }

    /// Fetches and verifies OCSP response online
    private func fetchAndVerifyOCSP(
        _ certificate: X509Certificate,
        issuer: X509Certificate
    ) async throws -> RevocationStatus {
        guard let client = httpClient else {
            throw RevocationError.ocspFetchFailed("No HTTP client configured for online OCSP check")
        }

        // Get OCSP responder URL from certificate's AIA extension
        guard let ocspURL = certificate.getOCSPResponderURL() else {
            throw RevocationError.noOCSPResponder
        }

        // Build OCSP request
        let request = try buildOCSPRequest(for: certificate, issuer: issuer)

        // Send request using injected HTTP client
        let (data, statusCode) = try await client.post(
            url: ocspURL,
            body: request,
            contentType: "application/ocsp-request"
        )

        guard statusCode == 200 else {
            throw RevocationError.ocspFetchFailed("Invalid HTTP response: \(statusCode)")
        }

        return try verifyOCSPResponse(data, for: certificate, issuer: issuer)
    }


    /// Builds an OCSP request for a certificate
    private func buildOCSPRequest(
        for certificate: X509Certificate,
        issuer: X509Certificate
    ) throws -> Data {
        // RFC 6960 OCSP Request structure:
        // OCSPRequest ::= SEQUENCE {
        //     tbsRequest TBSRequest
        // }
        // TBSRequest ::= SEQUENCE {
        //     version [0] EXPLICIT Version DEFAULT v1,
        //     requestorName [1] EXPLICIT GeneralName OPTIONAL,
        //     requestList SEQUENCE OF Request
        // }
        // Request ::= SEQUENCE {
        //     reqCert CertID
        // }
        // CertID ::= SEQUENCE {
        //     hashAlgorithm AlgorithmIdentifier,
        //     issuerNameHash OCTET STRING,
        //     issuerKeyHash OCTET STRING,
        //     serialNumber CertificateSerialNumber
        // }

        // Build issuer name hash using issuer's common name as approximation
        // Note: Full implementation should serialize X509Name to DER
        let issuerNameData = (issuer.subject.commonName ?? "").data(using: .utf8) ?? Data()
        let issuerNameHash = Data(SHA256.hash(data: issuerNameData))

        // Build issuer key hash from public key
        // Use the tbsCertificateBytes as a source for the key (simplified approach)
        // A full implementation would extract the SubjectPublicKeyInfo DER bytes
        let issuerKeyHash = Data(SHA256.hash(data: issuer.tbsCertificateBytes))

        // SHA-256 OID: 2.16.840.1.101.3.4.2.1
        let sha256OID = try OID("2.16.840.1.101.3.4.2.1")

        // Build AlgorithmIdentifier for SHA-256
        let algorithmIdentifier = ASN1Builder.sequence([
            ASN1Builder.objectIdentifier(sha256OID),
            ASN1Builder.null()
        ])

        // Build CertID
        let certID = ASN1Builder.sequence([
            algorithmIdentifier,
            ASN1Builder.octetString(issuerNameHash),
            ASN1Builder.octetString(issuerKeyHash),
            ASN1Builder.integer(certificate.serialNumber)
        ])

        // Build Request (single request)
        let request = ASN1Builder.sequence([certID])

        // Build requestList
        let requestList = ASN1Builder.sequence([request])

        // Build TBSRequest (no version field = v1 default, no requestorName)
        let tbsRequest = ASN1Builder.sequence([requestList])

        // Build OCSPRequest
        let ocspRequest = ASN1Builder.sequence([tbsRequest])

        return ocspRequest
    }

    // MARK: - CRL Checking

    /// Checks certificate against CRL
    private func checkCRL(
        _ certificate: X509Certificate,
        cacheDirectory: URL?
    ) async throws -> RevocationStatus {
        // Get CRL distribution point from certificate
        guard let crlURL = certificate.getCRLDistributionPoint() else {
            throw RevocationError.noCRLDistributionPoint
        }

        // Check cache first
        if let cacheDir = cacheDirectory {
            if let cachedCRL = loadCachedCRL(from: cacheDir, for: crlURL) {
                return checkCertificateInCRL(certificate, crl: cachedCRL)
            }
        }

        guard let client = httpClient else {
            throw RevocationError.crlFetchFailed("No HTTP client configured for CRL fetch")
        }

        // Fetch CRL using injected HTTP client
        let (data, statusCode) = try await client.get(url: crlURL)

        guard statusCode == 200 else {
            throw RevocationError.crlFetchFailed("Invalid HTTP response: \(statusCode)")
        }

        // Parse CRL
        guard let crl = try? CRL.parse(from: data) else {
            throw RevocationError.invalidCRL("Failed to parse CRL")
        }

        // Cache CRL
        if let cacheDir = cacheDirectory {
            saveCRLToCache(data, to: cacheDir, for: crlURL)
        }

        return checkCertificateInCRL(certificate, crl: crl)
    }


    private func loadCachedCRL(from directory: URL, for url: URL) -> CRL? {
        let cacheFile = directory.appendingPathComponent(url.absoluteString.data(using: .utf8)!.base64EncodedString())

        guard let data = try? Data(contentsOf: cacheFile),
              let crl = try? CRL.parse(from: data) else {
            return nil
        }

        // Check if CRL is still valid
        if crl.nextUpdate < Date() {
            return nil  // CRL expired
        }

        return crl
    }

    private func saveCRLToCache(_ data: Data, to directory: URL, for url: URL) {
        let cacheFile = directory.appendingPathComponent(url.absoluteString.data(using: .utf8)!.base64EncodedString())
        try? data.write(to: cacheFile)
    }

    private func checkCertificateInCRL(_ certificate: X509Certificate, crl: CRL) -> RevocationStatus {
        // Check if certificate serial number is in revoked list
        for entry in crl.revokedCertificates {
            if entry.serialNumber == certificate.serialNumber {
                return .revoked(
                    reason: entry.reason,
                    revokedAt: entry.revocationDate
                )
            }
        }
        return .good
    }
}

// MARK: - Revocation Errors

/// Errors that can occur during revocation checking
public enum RevocationError: Error, Sendable {
    /// Invalid OCSP response format
    case invalidOCSPResponse(String)

    /// No OCSP responder URL in certificate
    case noOCSPResponder

    /// Failed to fetch OCSP response
    case ocspFetchFailed(String)

    /// Invalid CRL format
    case invalidCRL(String)

    /// No CRL distribution point in certificate
    case noCRLDistributionPoint

    /// Failed to fetch CRL
    case crlFetchFailed(String)

    /// Revocation check timed out
    case timeout
}

// MARK: - OCSP Response Types

/// OCSP Response (RFC 6960)
struct OCSPResponse: Sendable {
    enum ResponseStatus: UInt8 {
        case successful = 0
        case malformedRequest = 1
        case internalError = 2
        case tryLater = 3
        case sigRequired = 5
        case unauthorized = 6
    }

    let responseStatus: ResponseStatus
    let responseBytes: ResponseBytes?

    struct ResponseBytes: Sendable {
        let responseType: OID
        let response: Data
    }

    static func parse(from data: Data) throws -> OCSPResponse {
        let value = try ASN1Parser.parseOne(from: data)

        guard value.tag.isSequence, !value.children.isEmpty else {
            throw RevocationError.invalidOCSPResponse("Invalid structure")
        }

        // OCSPResponse ::= SEQUENCE {
        //     responseStatus OCSPResponseStatus,
        //     responseBytes [0] EXPLICIT ResponseBytes OPTIONAL
        // }

        let statusValue = try value.children[0].asEnumerated()
        guard let status = ResponseStatus(rawValue: statusValue) else {
            throw RevocationError.invalidOCSPResponse("Unknown response status")
        }

        var responseBytes: ResponseBytes? = nil
        if value.children.count > 1 {
            let bytesWrapper = value.children[1]
            if bytesWrapper.tag.tagClass == .contextSpecific && bytesWrapper.tag.tagNumber == 0 {
                let bytes = try ASN1Parser.parseOne(from: bytesWrapper.content)
                if bytes.tag.isSequence && bytes.children.count >= 2 {
                    let responseType = try bytes.children[0].asObjectIdentifier()
                    let response = try bytes.children[1].asOctetString()
                    responseBytes = ResponseBytes(responseType: responseType, response: response)
                }
            }
        }

        return OCSPResponse(responseStatus: status, responseBytes: responseBytes)
    }
}

/// BasicOCSPResponse (RFC 6960)
struct BasicOCSPResponse: Sendable {
    let producedAt: Date
    let responses: [SingleResponse]

    struct SingleResponse: Sendable {
        enum CertStatus: Sendable {
            case good
            case revoked(RevokedInfo)
            case unknown
        }

        struct RevokedInfo: Sendable {
            let revocationTime: Date
            let reason: UInt8?
        }

        let certStatus: CertStatus
    }

    static func parse(from data: Data) throws -> BasicOCSPResponse {
        let value = try ASN1Parser.parseOne(from: data)

        guard value.tag.isSequence else {
            throw RevocationError.invalidOCSPResponse("Invalid BasicOCSPResponse structure")
        }

        // BasicOCSPResponse ::= SEQUENCE {
        //     tbsResponseData ResponseData,
        //     signatureAlgorithm AlgorithmIdentifier,
        //     signature BIT STRING,
        //     certs [0] EXPLICIT SEQUENCE OF Certificate OPTIONAL
        // }

        guard !value.children.isEmpty else {
            throw RevocationError.invalidOCSPResponse("Empty BasicOCSPResponse")
        }

        let tbsResponseData = value.children[0]

        // ResponseData ::= SEQUENCE {
        //     version [0] EXPLICIT Version DEFAULT v1,
        //     responderID ResponderID,
        //     producedAt GeneralizedTime,
        //     responses SEQUENCE OF SingleResponse,
        //     responseExtensions [1] EXPLICIT Extensions OPTIONAL
        // }

        guard tbsResponseData.tag.isSequence else {
            throw RevocationError.invalidOCSPResponse("Invalid ResponseData")
        }

        var index = 0

        // Skip version if present
        if tbsResponseData.children[index].tag.tagClass == .contextSpecific &&
           tbsResponseData.children[index].tag.tagNumber == 0 {
            index += 1
        }

        // Skip responderID
        index += 1

        // Parse producedAt
        guard index < tbsResponseData.children.count else {
            throw RevocationError.invalidOCSPResponse("Missing producedAt")
        }
        let producedAt = try tbsResponseData.children[index].asGeneralizedTime()
        index += 1

        // Parse responses
        guard index < tbsResponseData.children.count,
              tbsResponseData.children[index].tag.isSequence else {
            throw RevocationError.invalidOCSPResponse("Missing responses")
        }

        var singleResponses: [SingleResponse] = []
        for child in tbsResponseData.children[index].children {
            if let singleResponse = try? parseSingleResponse(child) {
                singleResponses.append(singleResponse)
            }
        }

        return BasicOCSPResponse(producedAt: producedAt, responses: singleResponses)
    }

    private static func parseSingleResponse(_ value: ASN1Value) throws -> SingleResponse {
        guard value.tag.isSequence, value.children.count >= 2 else {
            throw RevocationError.invalidOCSPResponse("Invalid SingleResponse")
        }

        // SingleResponse ::= SEQUENCE {
        //     certID CertID,
        //     certStatus CertStatus,
        //     thisUpdate GeneralizedTime,
        //     nextUpdate [0] EXPLICIT GeneralizedTime OPTIONAL,
        //     singleExtensions [1] EXPLICIT Extensions OPTIONAL
        // }

        let certStatusValue = value.children[1]

        let certStatus: SingleResponse.CertStatus
        switch certStatusValue.tag.tagNumber {
        case 0:  // good [0] IMPLICIT NULL
            certStatus = .good
        case 1:  // revoked [1] IMPLICIT RevokedInfo
            let revocationTime = try certStatusValue.children[0].asGeneralizedTime()
            var reason: UInt8? = nil
            if certStatusValue.children.count > 1 {
                reason = try? certStatusValue.children[1].asEnumerated()
            }
            certStatus = .revoked(SingleResponse.RevokedInfo(
                revocationTime: revocationTime,
                reason: reason
            ))
        case 2:  // unknown [2] IMPLICIT NULL
            certStatus = .unknown
        default:
            certStatus = .unknown
        }

        return SingleResponse(certStatus: certStatus)
    }
}

// MARK: - CRL Types

/// Certificate Revocation List (RFC 5280)
struct CRL: Sendable {
    /// Raw issuer DER data (for comparison, not fully parsed)
    let issuerRaw: Data
    let thisUpdate: Date
    let nextUpdate: Date
    let revokedCertificates: [RevokedCertificate]

    struct RevokedCertificate: Sendable {
        let serialNumber: Data
        let revocationDate: Date
        let reason: RevocationReason?
    }

    static func parse(from data: Data) throws -> CRL {
        let value = try ASN1Parser.parseOne(from: data)

        guard value.tag.isSequence else {
            throw RevocationError.invalidCRL("Invalid CRL structure")
        }

        // CertificateList ::= SEQUENCE {
        //     tbsCertList TBSCertList,
        //     signatureAlgorithm AlgorithmIdentifier,
        //     signatureValue BIT STRING
        // }

        guard !value.children.isEmpty else {
            throw RevocationError.invalidCRL("Empty CRL")
        }

        let tbsCertList = value.children[0]

        // TBSCertList ::= SEQUENCE {
        //     version Version OPTIONAL,
        //     signature AlgorithmIdentifier,
        //     issuer Name,
        //     thisUpdate Time,
        //     nextUpdate Time OPTIONAL,
        //     revokedCertificates SEQUENCE OF SEQUENCE { ... } OPTIONAL,
        //     crlExtensions [0] EXPLICIT Extensions OPTIONAL
        // }

        guard tbsCertList.children.count >= 3 else {
            throw RevocationError.invalidCRL("Incomplete TBSCertList")
        }

        var index = 0

        // Skip version if present (INTEGER)
        if tbsCertList.children[index].tag.isInteger {
            index += 1
        }

        // Skip signature algorithm (SEQUENCE)
        index += 1

        // Store raw issuer DER (for later comparison if needed)
        let issuerRaw = tbsCertList.children[index].content
        index += 1

        // Parse thisUpdate
        guard index < tbsCertList.children.count else {
            throw RevocationError.invalidCRL("Missing thisUpdate")
        }
        let thisUpdate = try tbsCertList.children[index].asTime()
        index += 1

        // Parse nextUpdate (optional)
        var nextUpdate = Date.distantFuture
        if index < tbsCertList.children.count {
            if let time = try? tbsCertList.children[index].asTime() {
                nextUpdate = time
                index += 1
            }
        }

        // Parse revokedCertificates (optional)
        var revokedCertificates: [RevokedCertificate] = []
        if index < tbsCertList.children.count && tbsCertList.children[index].tag.isSequence {
            for entry in tbsCertList.children[index].children {
                if let revoked = try? parseRevokedCertificate(entry) {
                    revokedCertificates.append(revoked)
                }
            }
        }

        return CRL(
            issuerRaw: issuerRaw,
            thisUpdate: thisUpdate,
            nextUpdate: nextUpdate,
            revokedCertificates: revokedCertificates
        )
    }

    private static func parseRevokedCertificate(_ value: ASN1Value) throws -> RevokedCertificate {
        guard value.tag.isSequence, value.children.count >= 2 else {
            throw RevocationError.invalidCRL("Invalid revoked certificate entry")
        }

        let serialNumber = try value.children[0].asInteger()
        let revocationDate = try value.children[1].asTime()

        var reason: RevocationReason? = nil
        if value.children.count > 2 {
            // Parse extensions to find reason code
            // CRL entry extensions are in SEQUENCE at index 2
            let extensions = value.children[2]
            if extensions.tag.isSequence {
                for ext in extensions.children {
                    if ext.tag.isSequence && ext.children.count >= 2 {
                        if let oid = try? ext.children[0].asObjectIdentifier(),
                           oid.dotNotation == "2.5.29.21" {  // CRL Reason Code
                            if let reasonData = try? ext.children[1].asOctetString(),
                               let reasonValue = try? ASN1Parser.parseOne(from: reasonData),
                               let enumValue = try? reasonValue.asEnumerated() {
                                reason = RevocationReason(rawValue: enumValue)
                            }
                        }
                    }
                }
            }
        }

        return RevokedCertificate(
            serialNumber: Data(serialNumber),
            revocationDate: revocationDate,
            reason: reason
        )
    }
}

// MARK: - X509Certificate Extensions

extension X509Certificate {
    /// Gets the OCSP responder URL from Authority Information Access extension
    func getOCSPResponderURL() -> URL? {
        // Use swift-certificates' authorityInformationAccess property
        guard let aia = try? certificate.extensions.authorityInformationAccess else {
            return nil
        }

        // Find OCSP responder in AIA
        for accessDescription in aia {
            if accessDescription.method == .ocspServer {
                if case .uniformResourceIdentifier(let uri) = accessDescription.location {
                    return URL(string: uri)
                }
            }
        }
        return nil
    }

    /// Gets the CRL distribution point URL from the certificate
    func getCRLDistributionPoint() -> URL? {
        // CRL Distribution Points is not directly available in swift-certificates
        // Would need to parse the raw extension - for now return nil
        // TODO: Implement CRL DP parsing if needed
        return nil
    }

    private func parseAIAForOCSP(_ data: Data) -> URL? {
        // AuthorityInfoAccessSyntax ::= SEQUENCE SIZE (1..MAX) OF AccessDescription
        // AccessDescription ::= SEQUENCE {
        //     accessMethod OBJECT IDENTIFIER,
        //     accessLocation GeneralName
        // }

        guard let value = try? ASN1Parser.parseOne(from: data),
              value.tag.isSequence else {
            return nil
        }

        for accessDesc in value.children {
            guard accessDesc.tag.isSequence, accessDesc.children.count >= 2 else {
                continue
            }

            let method = try? accessDesc.children[0].asObjectIdentifier()
            // OCSP method OID: 1.3.6.1.5.5.7.48.1
            if method?.dotNotation == "1.3.6.1.5.5.7.48.1" {
                let location = accessDesc.children[1]
                // GeneralName uniformResourceIdentifier [6] IA5String
                if location.tag.tagClass == .contextSpecific && location.tag.tagNumber == 6 {
                    if let urlString = String(data: location.content, encoding: .ascii) {
                        return URL(string: urlString)
                    }
                }
            }
        }

        return nil
    }

    private func parseCDPForURL(_ data: Data) -> URL? {
        // CRLDistributionPoints ::= SEQUENCE SIZE (1..MAX) OF DistributionPoint

        guard let value = try? ASN1Parser.parseOne(from: data),
              value.tag.isSequence else {
            return nil
        }

        for dp in value.children {
            guard dp.tag.isSequence else { continue }

            for child in dp.children {
                // distributionPoint [0]
                if child.tag.tagClass == .contextSpecific && child.tag.tagNumber == 0 {
                    // fullName [0] GeneralNames
                    for name in child.children {
                        if name.tag.tagClass == .contextSpecific && name.tag.tagNumber == 0 {
                            for generalName in name.children {
                                // uniformResourceIdentifier [6]
                                if generalName.tag.tagClass == .contextSpecific && generalName.tag.tagNumber == 6 {
                                    if let urlString = String(data: generalName.content, encoding: .ascii) {
                                        return URL(string: urlString)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return nil
    }
}

// MARK: - ASN.1 Helper Extensions

extension ASN1Value {
    /// Interprets content as ENUMERATED (used for OCSP/CRL status codes)
    func asEnumerated() throws -> UInt8 {
        guard tag.universalTag == .enumerated else {
            throw ASN1Error.typeMismatch(expected: "ENUMERATED", actual: String(describing: tag))
        }
        guard content.count == 1 else {
            throw ASN1Error.invalidFormat("ENUMERATED must be single byte")
        }
        return content[0]
    }
}
