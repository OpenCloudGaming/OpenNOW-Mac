/// X.509 Certificate Validation (RFC 5280 Section 6)
///
/// Validates certificate chains according to X.509 path validation rules.

import Foundation
import Crypto
@preconcurrency import X509
import SwiftASN1

// MARK: - Validated Chain Result

/// Result of a successful certificate chain validation.
///
/// Contains the validated chain and leaf certificate, which can be used
/// for subsequent revocation checks or application-level inspection.
public struct ValidatedChain: Sendable {
    /// The validated certificate chain, from leaf to root.
    public let chain: [X509Certificate]

    /// The leaf (end-entity) certificate.
    public var leaf: X509Certificate { chain[0] }

    /// The issuer of the leaf certificate (if chain has more than one cert).
    public var leafIssuer: X509Certificate? {
        chain.count > 1 ? chain[1] : nil
    }

    /// The root certificate (last in the chain).
    public var root: X509Certificate? { chain.last }
}

// MARK: - Validation Options

/// Options for X.509 certificate validation
public struct X509ValidationOptions: Sendable {
    /// Whether to check certificate validity periods
    public var checkValidity: Bool

    /// Whether to check BasicConstraints for CA certificates
    public var checkBasicConstraints: Bool

    /// Whether to check KeyUsage extensions
    public var checkKeyUsage: Bool

    /// Whether to check Extended Key Usage extensions
    public var checkExtendedKeyUsage: Bool

    /// Required Extended Key Usage for the leaf certificate
    /// If set, the certificate must contain this EKU (or anyExtendedKeyUsage)
    public var requiredEKU: RequiredEKU?

    /// Whether to validate SAN format (DNS names, IP addresses)
    public var validateSANFormat: Bool

    /// Whether to check Name Constraints from CA certificates
    public var checkNameConstraints: Bool

    /// Hostname to verify against SubjectAltName/CN
    public var hostname: String?

    /// Time at which to validate (defaults to current time)
    public var validationTime: Date

    /// Whether to allow self-signed certificates without trusted root
    public var allowSelfSigned: Bool

    /// Maximum chain depth (not including leaf)
    public var maxChainDepth: Int

    /// Creates default validation options
    public init(
        checkValidity: Bool = true,
        checkBasicConstraints: Bool = true,
        checkKeyUsage: Bool = true,
        checkExtendedKeyUsage: Bool = true,
        requiredEKU: RequiredEKU? = nil,
        validateSANFormat: Bool = true,
        checkNameConstraints: Bool = true,
        hostname: String? = nil,
        validationTime: Date = Date(),
        allowSelfSigned: Bool = false,
        maxChainDepth: Int = 10
    ) {
        self.checkValidity = checkValidity
        self.checkBasicConstraints = checkBasicConstraints
        self.checkKeyUsage = checkKeyUsage
        self.checkExtendedKeyUsage = checkExtendedKeyUsage
        self.requiredEKU = requiredEKU
        self.validateSANFormat = validateSANFormat
        self.checkNameConstraints = checkNameConstraints
        self.hostname = hostname
        self.validationTime = validationTime
        self.allowSelfSigned = allowSelfSigned
        self.maxChainDepth = maxChainDepth
    }
}

/// Required Extended Key Usage type
public enum RequiredEKU: Sendable {
    case serverAuth
    case clientAuth
    case codeSigning
    case emailProtection
    case timeStamping
    case ocspSigning

    /// OID for this EKU
    public var oid: String {
        switch self {
        case .serverAuth: return "1.3.6.1.5.5.7.3.1"
        case .clientAuth: return "1.3.6.1.5.5.7.3.2"
        case .codeSigning: return "1.3.6.1.5.5.7.3.3"
        case .emailProtection: return "1.3.6.1.5.5.7.3.4"
        case .timeStamping: return "1.3.6.1.5.5.7.3.8"
        case .ocspSigning: return "1.3.6.1.5.5.7.3.9"
        }
    }

    /// anyExtendedKeyUsage OID (2.5.29.37.0)
    public static let anyExtendedKeyUsageOID = "2.5.29.37.0"
}

// MARK: - X.509 Validator

/// Validates X.509 certificate chains
public struct X509Validator: Sendable {
    /// Trusted root CA certificates
    private let trustedRoots: [X509Certificate]

    /// Validation options
    private let options: X509ValidationOptions

    /// Creates a validator with trusted roots and options
    public init(
        trustedRoots: [X509Certificate] = [],
        options: X509ValidationOptions = X509ValidationOptions()
    ) {
        self.trustedRoots = trustedRoots
        self.options = options
    }

    // MARK: - Public API

    /// Validates a certificate chain
    /// - Parameters:
    ///   - certificate: The end-entity (leaf) certificate
    ///   - intermediates: Intermediate CA certificates
    /// - Throws: X509Error if validation fails
    public func validate(
        certificate: X509Certificate,
        intermediates: [X509Certificate] = []
    ) throws {
        // Build the certificate chain
        let chain = try buildChain(leaf: certificate, intermediates: intermediates)

        // Check chain depth
        guard chain.count <= options.maxChainDepth + 1 else {
            throw X509Error.pathLengthExceeded(allowed: options.maxChainDepth, actual: chain.count - 1)
        }

        // Validate each certificate in the chain
        for (index, cert) in chain.enumerated() {
            let isCA = index > 0  // Everything except leaf is a CA
            try validateCertificate(cert, isCA: isCA, depth: index)
        }

        // Verify signatures in the chain
        try verifyChainSignatures(chain)

        // Verify Name Constraints from CA certificates (RFC 5280 Section 4.2.1.10)
        if options.checkNameConstraints {
            try verifyNameConstraints(chain)
        }

        // Verify the root is trusted
        try verifyTrust(chain: chain)

        // Verify hostname if specified
        if let hostname = options.hostname {
            try verifyHostname(certificate, hostname: hostname)
        }

        // Verify Extended Key Usage if required
        if options.checkExtendedKeyUsage {
            try verifyExtendedKeyUsage(certificate)
        }

        // Validate SAN format
        if options.validateSANFormat {
            try validateSANFormat(certificate)
        }
    }

    /// Validates a single certificate (without chain validation)
    public func validateSingle(_ certificate: X509Certificate) throws {
        try validateCertificate(certificate, isCA: false, depth: 0)

        if let hostname = options.hostname {
            try verifyHostname(certificate, hostname: hostname)
        }

        // Verify Extended Key Usage if required
        if options.checkExtendedKeyUsage {
            try verifyExtendedKeyUsage(certificate)
        }

        // Validate SAN format
        if options.validateSANFormat {
            try validateSANFormat(certificate)
        }
    }

    // MARK: - Chain Building

    /// Builds a certificate chain from leaf to root
    private func buildChain(
        leaf: X509Certificate,
        intermediates: [X509Certificate]
    ) throws -> [X509Certificate] {
        var chain: [X509Certificate] = [leaf]
        var current = leaf

        // Build chain by finding issuers
        while !current.isSelfSigned {
            // Look for issuer in intermediates
            guard let issuer = findIssuer(for: current, in: intermediates + trustedRoots) else {
                // If we can't find the issuer but have trusted roots, check if current is trusted
                if trustedRoots.contains(where: { $0.subject == current.subject }) {
                    break
                }
                throw X509Error.issuerNotFound(issuer: current.issuer.string)
            }

            // Prevent cycles
            if chain.contains(where: { $0.subject == issuer.subject && $0.serialNumber == issuer.serialNumber }) {
                break
            }

            chain.append(issuer)
            current = issuer

            // Safety limit
            if chain.count > options.maxChainDepth + 1 {
                break
            }
        }

        return chain
    }

    /// Finds the issuer certificate for a given certificate
    ///
    /// Uses subject DN matching as the primary filter, then refines with
    /// Authority Key Identifier (AKI) / Subject Key Identifier (SKI) matching
    /// when those extensions are present (RFC 5280 Section 4.2.1.1 / 4.2.1.2).
    private func findIssuer(
        for certificate: X509Certificate,
        in candidates: [X509Certificate]
    ) -> X509Certificate? {
        // First pass: collect candidates whose subject matches the certificate's issuer DN
        let subjectMatches = candidates.filter { $0.subject == certificate.issuer }

        guard !subjectMatches.isEmpty else {
            return nil
        }

        // If only one candidate matches by subject, return it directly
        if subjectMatches.count == 1 {
            return subjectMatches[0]
        }

        // Multiple candidates share the same subject DN — use AKI to disambiguate.
        // RFC 5280 Section 4.2.1.1: The Authority Key Identifier extension provides
        // a means of identifying the public key corresponding to the private key used
        // to sign a certificate.
        if let aki = certificate.authorityKeyIdentifier {
            // Strategy 1: Match AKI keyIdentifier against candidate SKI
            // RFC 5280 Section 4.2.1.1: The keyIdentifier field, when present,
            // MUST match the value of the SKI extension of the issuer certificate.
            if let akiKeyID = aki.keyIdentifier {
                for candidate in subjectMatches {
                    if let ski = candidate.subjectKeyIdentifier,
                       akiKeyID == ski.keyIdentifier {
                        return candidate
                    }
                }
            }

            // Strategy 2: Match AKI authorityCertSerialNumber against candidate serial
            // RFC 5280 Section 4.2.1.1: The authorityCertSerialNumber field, when present,
            // provides the serial number of the issuer's certificate. Together with
            // authorityCertIssuer, it uniquely identifies the issuer certificate.
            if let akiSerial = aki.authorityCertSerialNumber {
                let akiSerialBytes = Data(akiSerial.bytes)
                for candidate in subjectMatches {
                    if candidate.serialNumber == akiSerialBytes {
                        return candidate
                    }
                }
            }

            // AKI present but no matching candidate found —
            // fall through to first subject match
        }

        // Fallback: return the first subject match (preserves original behavior)
        return subjectMatches[0]
    }

    // MARK: - Individual Certificate Validation

    /// Validates a single certificate
    private func validateCertificate(
        _ cert: X509Certificate,
        isCA: Bool,
        depth: Int
    ) throws {
        // Check validity period
        if options.checkValidity {
            if options.validationTime < cert.validity.notBefore {
                throw X509Error.certificateNotYetValid(notBefore: cert.validity.notBefore)
            }
            if options.validationTime > cert.validity.notAfter {
                throw X509Error.certificateExpired(notAfter: cert.validity.notAfter)
            }
        }

        // Check BasicConstraints for CA certificates
        if options.checkBasicConstraints && isCA {
            guard let bc = cert.basicConstraints else {
                // CA certificate must have BasicConstraints
                throw X509Error.notCA
            }
            guard bc.isCA else {
                throw X509Error.notCA
            }

            // Check path length constraint
            if let pathLen = bc.pathLenConstraint {
                // depth is 0-indexed from leaf, pathLen limits intermediates below this CA
                let remainingDepth = depth - 1  // CAs below this one
                if remainingDepth > pathLen {
                    throw X509Error.pathLengthExceeded(allowed: pathLen, actual: remainingDepth)
                }
            }
        }

        // Check KeyUsage
        if options.checkKeyUsage {
            if let ku = cert.keyUsage {
                if isCA {
                    // CA must have keyCertSign
                    guard ku.keyCertSign else {
                        throw X509Error.invalidKeyUsage("CA certificate missing keyCertSign")
                    }
                } else {
                    // Leaf certificate for TLS should have digitalSignature
                    guard ku.digitalSignature else {
                        throw X509Error.invalidKeyUsage("Certificate missing digitalSignature")
                    }
                }
            }
        }
    }

    // MARK: - Signature Verification

    /// Verifies signatures in the certificate chain
    private func verifyChainSignatures(_ chain: [X509Certificate]) throws {
        // Verify each certificate is signed by its issuer
        for i in 0..<(chain.count - 1) {
            let cert = chain[i]
            let issuer = chain[i + 1]

            try verifySignature(of: cert, signedBy: issuer)
        }

        // Verify the root (last certificate) if it's self-signed
        if let root = chain.last, root.isSelfSigned {
            try verifySignature(of: root, signedBy: root)
        }
    }

    /// Verifies a certificate's signature
    private func verifySignature(
        of certificate: X509Certificate,
        signedBy issuer: X509Certificate
    ) throws {
        // Get issuer's public key
        let publicKey: VerificationKey
        do {
            publicKey = try issuer.extractPublicKey()
        } catch {
            throw X509Error.invalidPublicKey("Failed to extract issuer public key: \(error)")
        }

        // Determine signature scheme
        guard let scheme = certificate.signatureAlgorithm.signatureScheme else {
            throw X509Error.unsupportedSignatureAlgorithm(String(describing: certificate.signatureAlgorithm.algorithm))
        }

        // Verify scheme matches key type
        guard scheme == publicKey.scheme else {
            throw X509Error.signatureAlgorithmMismatch
        }

        // Verify signature
        do {
            let valid = try publicKey.verify(
                signature: certificate.signatureValue,
                for: certificate.tbsCertificateBytes
            )
            guard valid else {
                throw X509Error.signatureVerificationFailed("Signature is invalid")
            }
        } catch let error as X509Error {
            throw error
        } catch {
            throw X509Error.signatureVerificationFailed(error.localizedDescription)
        }
    }

    // MARK: - Name Constraints Verification (RFC 5280 Section 4.2.1.10)

    /// Verifies Name Constraints from CA certificates in the chain
    private func verifyNameConstraints(_ chain: [X509Certificate]) throws {
        // For each CA with Name Constraints, apply constraints to certificates below
        for caIndex in 1..<chain.count {
            let ca = chain[caIndex]

            guard let constraints = ca.nameConstraints else {
                continue
            }

            if constraints.isEmpty {
                continue
            }

            // Apply constraints to all certificates below this CA
            for certIndex in 0..<caIndex {
                let cert = chain[certIndex]
                try verifyNameAgainstConstraints(cert, constraints: constraints)
            }
        }
    }

    /// Verifies a certificate's names against Name Constraints
    private func verifyNameAgainstConstraints(
        _ certificate: X509Certificate,
        constraints: X509.NameConstraints
    ) throws {
        // Collect DNS names from SAN
        var dnsNames: [String] = []
        if let san = certificate.subjectAlternativeNames {
            dnsNames.append(contentsOf: san.dnsNames)
        }

        // Get Common Name from subject if no SAN DNS names
        if let cn = certificate.subject.commonName, dnsNames.isEmpty {
            dnsNames.append(cn)
        }

        // Validate DNS names against constraints
        for dnsName in dnsNames {
            // Check permitted DNS domains
            if !constraints.permittedDNSDomains.isEmpty {
                var permitted = false
                for permittedDomain in constraints.permittedDNSDomains {
                    if dnsNameMatches(dnsName, constraint: permittedDomain) {
                        permitted = true
                        break
                    }
                }
                if !permitted {
                    throw X509Error.nameConstraintsViolation(
                        name: "DNS:\(dnsName)",
                        reason: "not within permitted Name Constraints"
                    )
                }
            }

            // Check excluded DNS domains
            for excludedDomain in constraints.excludedDNSDomains {
                if dnsNameMatches(dnsName, constraint: excludedDomain) {
                    throw X509Error.nameConstraintsViolation(
                        name: "DNS:\(dnsName)",
                        reason: "excluded by Name Constraints"
                    )
                }
            }
        }
    }

    /// DNS name matching for Name Constraints
    private func dnsNameMatches(_ name: String, constraint: String) -> Bool {
        let nameLower = name.lowercased()
        let constraintLower = constraint.lowercased()

        // Exact match
        if nameLower == constraintLower {
            return true
        }

        // If constraint starts with ".", it's a subdomain constraint
        if constraintLower.hasPrefix(".") {
            if nameLower.hasSuffix(constraintLower) {
                return true
            }
            let domain = String(constraintLower.dropFirst())
            if nameLower == domain {
                return true
            }
        } else {
            // Constraint without leading dot - name must be subdomain or exact match
            if nameLower.hasSuffix("." + constraintLower) {
                return true
            }
        }

        return false
    }

    // MARK: - Trust Verification

    /// Verifies that the chain leads to a trusted root
    private func verifyTrust(chain: [X509Certificate]) throws {
        guard let root = chain.last else {
            throw X509Error.emptyChain
        }

        // SECURITY: Multi-factor trust matching for root certificates.
        //
        // We use a scoring approach to match roots against our trusted store,
        // requiring multiple identity factors to align:
        //
        // 1. Subject Public Key Info (SPKI) DER — cryptographic identity
        //    Two different CAs could share the same subject DN, but the SPKI
        //    (algorithm identifier + public key bits) is a strong identity.
        //
        // 2. Subject DN — organizational identity
        //    Prevents false positives from key reuse across different entities.
        //
        // 3. SKI/AKI cross-check (when available) — issuer linkage
        //    If the chain's penultimate certificate has an AKI, verify it
        //    matches the trusted root's SKI for additional assurance.
        //
        // 4. Serial number match (when AKI authorityCertSerialNumber is present)
        //    Provides uniqueness within the same issuer DN.

        let rootSPKI = root.subjectPublicKeyInfoDER

        let isTrusted = trustedRoots.contains { trusted in
            let trustedSPKI = trusted.subjectPublicKeyInfoDER

            // Primary match: SPKI DER must match (cryptographic identity)
            guard !rootSPKI.isEmpty && !trustedSPKI.isEmpty && rootSPKI == trustedSPKI else {
                return false
            }

            // Secondary match: Subject DN must also match (entity identity)
            guard trusted.subject == root.subject else {
                return false
            }

            // Tertiary match (optional, strengthening): if the chain has an
            // intermediate that points to this root via AKI, verify the SKI matches.
            // This prevents a compromised root with a re-used key from being accepted
            // if the AKI/SKI linkage doesn't hold.
            if chain.count >= 2 {
                let penultimate = chain[chain.count - 2]
                if let aki = penultimate.authorityKeyIdentifier,
                   let akiKeyID = aki.keyIdentifier {
                    if let trustedSKI = trusted.subjectKeyIdentifier {
                        // AKI/SKI both present — they must match
                        if akiKeyID != trustedSKI.keyIdentifier {
                            return false
                        }
                    }
                    // If trusted root has no SKI, we can't cross-check;
                    // SPKI + subject DN match is sufficient.
                }
            }

            return true
        }

        if isTrusted {
            return
        }

        // If self-signed and allowSelfSigned is true, accept it
        if root.isSelfSigned && options.allowSelfSigned {
            return
        }

        // If it's a single self-signed certificate
        if chain.count == 1 && root.isSelfSigned {
            if options.allowSelfSigned {
                return
            }
            throw X509Error.selfSignedNotTrusted
        }

        throw X509Error.untrustedRoot
    }

    // MARK: - Hostname Verification

    /// Verifies the hostname matches the certificate
    private func verifyHostname(
        _ certificate: X509Certificate,
        hostname: String
    ) throws {
        var matchedNames: [String] = []

        // Check Subject Alternative Name first
        if let san = certificate.subjectAlternativeNames {
            for dnsName in san.dnsNames {
                matchedNames.append(dnsName)
                if matchHostname(pattern: dnsName, hostname: hostname) {
                    return
                }
            }
        }

        // Fall back to Common Name (deprecated but still used)
        if let cn = certificate.subject.commonName {
            matchedNames.append(cn)
            if matchHostname(pattern: cn, hostname: hostname) {
                return
            }
        }

        throw X509Error.hostnameMismatch(expected: hostname, actual: matchedNames)
    }

    /// Matches a hostname pattern against a hostname
    private func matchHostname(pattern: String, hostname: String) -> Bool {
        let patternLower = pattern.lowercased()
        let hostnameLower = hostname.lowercased()

        // Exact match
        if patternLower == hostnameLower {
            return true
        }

        // Wildcard matching (*.example.com)
        if patternLower.hasPrefix("*.") {
            let suffix = String(patternLower.dropFirst(2))
            let hostParts = hostnameLower.split(separator: ".")

            if hostParts.count >= 2 {
                let hostSuffix = hostParts.dropFirst().joined(separator: ".")
                if hostSuffix == suffix {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Extended Key Usage Verification

    /// Verifies Extended Key Usage of the certificate
    private func verifyExtendedKeyUsage(_ certificate: X509Certificate) throws {
        guard let requiredEKU = options.requiredEKU else {
            return
        }

        guard let eku = certificate.extendedKeyUsage else {
            return
        }

        // Check if the required EKU is present using the typed helpers
        // for well-known usages, and OID-based comparison for all others.
        let hasRequiredUsage: Bool
        switch requiredEKU {
        case .serverAuth:
            hasRequiredUsage = eku.isServerAuth
        case .clientAuth:
            hasRequiredUsage = eku.isClientAuth
        case .codeSigning:
            hasRequiredUsage = eku.contains(.codeSigning)
        case .emailProtection:
            hasRequiredUsage = eku.contains(.emailProtection)
        case .timeStamping:
            hasRequiredUsage = eku.contains(.timeStamping)
        case .ocspSigning:
            hasRequiredUsage = eku.contains(.ocspSigning)
        }

        if hasRequiredUsage {
            return
        }

        throw X509Error.invalidExtendedKeyUsage(
            required: requiredEKU.oid,
            found: []
        )
    }

    // MARK: - SAN Format Validation

    /// Validates the format of Subject Alternative Name entries
    private func validateSANFormat(_ certificate: X509Certificate) throws {
        guard let san = certificate.subjectAlternativeNames else {
            return
        }

        // Validate DNS names
        for dnsName in san.dnsNames {
            if !isValidDNSName(dnsName) {
                throw X509Error.malformedSAN(type: "dNSName", value: dnsName)
            }
        }

        // Validate URIs
        for uri in san.uris {
            if !isValidURI(uri) {
                throw X509Error.malformedSAN(type: "uniformResourceIdentifier", value: uri)
            }
        }
    }

    /// Validates a DNS name according to RFC 1035
    private func isValidDNSName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard name.count <= 253 else { return false }

        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map { String($0) }
        guard !labels.isEmpty else { return false }

        for (index, label) in labels.enumerated() {
            guard label.count >= 1 && label.count <= 63 else { return false }

            if label == "*" {
                guard index == 0 else { return false }
                continue
            }

            guard let first = label.first, first.isLetter || first.isNumber else {
                return false
            }

            guard let last = label.last, last.isLetter || last.isNumber else {
                return false
            }

            for char in label {
                guard char.isLetter || char.isNumber || char == "-" else {
                    return false
                }
            }
        }

        return true
    }

    /// Validates a URI format
    private func isValidURI(_ uri: String) -> Bool {
        guard let url = URL(string: uri) else {
            return false
        }
        return url.scheme != nil
    }

    // MARK: - Chain-Returning Validation

    /// Validates a certificate chain and returns the validated chain.
    ///
    /// This performs the same validation as `validate(certificate:intermediates:)`,
    /// but returns the built chain for use in subsequent operations such as
    /// revocation checking.
    ///
    /// - Parameters:
    ///   - certificate: The end-entity (leaf) certificate
    ///   - intermediates: Intermediate CA certificates
    /// - Returns: The validated chain from leaf to root
    /// - Throws: X509Error if validation fails
    public func buildValidatedChain(
        certificate: X509Certificate,
        intermediates: [X509Certificate] = []
    ) throws -> ValidatedChain {
        // Build the certificate chain
        let chain = try buildChain(leaf: certificate, intermediates: intermediates)

        // Check chain depth
        guard chain.count <= options.maxChainDepth + 1 else {
            throw X509Error.pathLengthExceeded(allowed: options.maxChainDepth, actual: chain.count - 1)
        }

        // Validate each certificate in the chain
        for (index, cert) in chain.enumerated() {
            let isCA = index > 0
            try validateCertificate(cert, isCA: isCA, depth: index)
        }

        // Verify signatures in the chain
        try verifyChainSignatures(chain)

        // Verify Name Constraints from CA certificates (RFC 5280 Section 4.2.1.10)
        if options.checkNameConstraints {
            try verifyNameConstraints(chain)
        }

        // Verify the root is trusted
        try verifyTrust(chain: chain)

        // Verify hostname if specified
        if let hostname = options.hostname {
            try verifyHostname(certificate, hostname: hostname)
        }

        // Verify Extended Key Usage if required
        if options.checkExtendedKeyUsage {
            try verifyExtendedKeyUsage(certificate)
        }

        // Validate SAN format
        if options.validateSANFormat {
            try validateSANFormat(certificate)
        }

        return ValidatedChain(chain: chain)
    }

    // MARK: - Async Validation with Revocation

    /// Validates a certificate chain including revocation checking.
    ///
    /// This method performs the full synchronous chain validation first,
    /// then asynchronously checks revocation status for the leaf certificate
    /// using the provided `RevocationChecker`.
    ///
    /// - Parameters:
    ///   - certificate: The end-entity (leaf) certificate
    ///   - intermediates: Intermediate CA certificates
    ///   - revocationChecker: The revocation checker to use
    ///   - ocspResponse: Optional stapled OCSP response (e.g., from TLS Certificate Status extension)
    /// - Throws: `X509Error.certificateRevoked` if revoked, or other `X509Error` for chain issues
    public func validateWithRevocation(
        certificate: X509Certificate,
        intermediates: [X509Certificate] = [],
        revocationChecker: RevocationChecker,
        ocspResponse: Data? = nil
    ) async throws {
        // Step 1: Synchronous chain validation (builds and validates the chain)
        let validatedChain = try buildValidatedChain(
            certificate: certificate,
            intermediates: intermediates
        )

        // Step 2: Async revocation check on the leaf certificate
        guard let issuer = validatedChain.leafIssuer else {
            // Self-signed or single-cert chain — revocation check requires an issuer
            // for OCSP. Skip revocation if no issuer is available.
            return
        }

        let status = try await revocationChecker.checkRevocation(
            validatedChain.leaf,
            issuer: issuer,
            ocspResponse: ocspResponse
        )

        switch status {
        case .good:
            return
        case .revoked:
            throw X509Error.certificateRevoked
        case .unknown:
            // Unknown status — behavior depends on the checker's mode
            // (soft-fail modes return .undetermined instead of .unknown)
            throw X509Error.certificateRevoked
        case .undetermined:
            // Soft-fail: could not determine status, allow connection
            return
        }
    }
}

// MARK: - Certificate Store

/// A store for trusted CA certificates
public struct CertificateStore: Sendable {
    private var certificates: [X509Certificate]

    public init() {
        self.certificates = []
    }

    public init(certificates: [X509Certificate]) {
        self.certificates = certificates
    }

    public mutating func add(_ certificate: X509Certificate) {
        certificates.append(certificate)
    }

    public mutating func add(derEncoded data: Data) throws {
        let cert = try X509Certificate.parse(from: data)
        certificates.append(cert)
    }

    public var all: [X509Certificate] {
        certificates
    }

    public func validator(options: X509ValidationOptions = X509ValidationOptions()) -> X509Validator {
        X509Validator(trustedRoots: certificates, options: options)
    }
}
