/// TLS 1.3 Provider Protocol (RFC 9001)
///
/// Abstraction for TLS 1.3 implementation used in QUIC.
/// Allows swapping between different TLS backends (BoringSSL, etc.)
/// and mocking for tests.

import Foundation
import QUICCore
@preconcurrency import X509
import SwiftASN1

// MARK: - TLS 1.3 Provider Protocol

/// Protocol for TLS 1.3 implementations used with QUIC
///
/// QUIC uses TLS 1.3 for key agreement and authentication, but with
/// a modified record layer. The TLS handshake messages are carried
/// in CRYPTO frames, and the record layer encryption is replaced
/// with QUIC packet protection.
///
/// Implementations should:
/// - Handle TLS 1.3 handshake state machine
/// - Export secrets at each encryption level
/// - Support QUIC transport parameters extension (0x0039)
/// - Never send TLS alerts directly (return as errors)
public protocol TLS13Provider: Sendable {
    /// Starts the TLS handshake
    ///
    /// For clients, this generates the ClientHello message.
    /// For servers, this prepares to receive ClientHello.
    ///
    /// - Parameter isClient: true for client mode, false for server mode
    /// - Returns: Initial TLS output (typically ClientHello data for clients)
    func startHandshake(isClient: Bool) async throws -> [TLSOutput]

    /// Processes incoming TLS handshake data
    ///
    /// - Parameters:
    ///   - data: Received TLS handshake data
    ///   - level: The encryption level at which the data was received
    /// - Returns: Array of TLS outputs (may include data to send, keys, completion)
    func processHandshakeData(_ data: Data, at level: EncryptionLevel) async throws -> [TLSOutput]

    /// Gets the local transport parameters to be sent in the TLS extension
    ///
    /// Must be called before starting the handshake to include in ClientHello/EncryptedExtensions.
    ///
    /// - Returns: Encoded transport parameters
    func getLocalTransportParameters() -> Data

    /// Sets the local transport parameters
    ///
    /// - Parameter params: Encoded transport parameters to send
    func setLocalTransportParameters(_ params: Data) throws

    /// Gets the peer's transport parameters received in the TLS extension
    ///
    /// Available after processing ServerHello (client) or ClientHello (server).
    ///
    /// - Returns: Encoded transport parameters, or nil if not yet received
    func getPeerTransportParameters() -> Data?

    /// Whether the handshake is complete
    var isHandshakeComplete: Bool { get }

    /// Whether this is acting as a client
    var isClient: Bool { get }

    /// The negotiated ALPN protocol (if any)
    var negotiatedALPN: String? { get }

    /// Write a key update request
    ///
    /// Initiates a TLS KeyUpdate handshake message.
    /// This is used for 1-RTT key rotation.
    ///
    /// - Returns: TLS outputs for the key update
    func requestKeyUpdate() async throws -> [TLSOutput]

    /// Export keying material (RFC 5705 / RFC 8446 Section 7.5)
    ///
    /// - Parameters:
    ///   - label: The label for the export
    ///   - context: Optional context data
    ///   - length: Desired output length
    /// - Returns: Exported keying material
    func exportKeyingMaterial(
        label: String,
        context: Data?,
        length: Int
    ) throws -> Data

    /// Configures session resumption with 0-RTT support
    ///
    /// Must be called before `startHandshake()` on the client side.
    ///
    /// - Parameters:
    ///   - ticket: The session ticket data for resumption
    ///   - attemptEarlyData: Whether to attempt 0-RTT early data
    func configureResumption(ticket: SessionTicketData, attemptEarlyData: Bool) throws

    /// Whether 0-RTT was accepted by the server
    ///
    /// Only valid after receiving the server's EncryptedExtensions.
    /// Returns true if the server included the early_data extension.
    var is0RTTAccepted: Bool { get }

    /// Whether 0-RTT was attempted in this handshake
    var is0RTTAttempted: Bool { get }
}

// MARK: - Certificate Validator

/// Certificate validator callback type for custom certificate validation.
///
/// This callback allows applications to implement custom certificate validation logic.
/// The TLS layer handles signature verification (CertificateVerify), while this callback
/// handles content validation (e.g., checking extensions, deriving application-specific data).
///
/// - Parameter certificates: The peer's certificate chain (DER encoded), leaf first
/// - Returns: Application-specific peer info (e.g., verified peer identity), or nil if not needed
/// - Throws: If certificate validation fails (will abort the handshake)
///
/// ## Example
/// ```swift
/// config.certificateValidator = { certChain in
///     guard let certData = certChain.first else { throw MyError.noCertificate }
///     let peerIdentity = try extractPeerIdentity(from: certData)
///     return peerIdentity
/// }
/// ```
public typealias CertificateValidator = @Sendable ([Data]) throws -> (any Sendable)?

// MARK: - TLS Configuration

/// Configuration for TLS 1.3 provider
public struct TLSConfiguration: Sendable {
    /// Application Layer Protocol Negotiation protocols (in preference order)
    public var alpnProtocols: [String]

    /// Path to certificate file (PEM format) - for servers
    public var certificatePath: String?

    /// Path to private key file (PEM format) - for servers
    public var privateKeyPath: String?

    /// Certificate chain (DER encoded) - alternative to file path
    public var certificateChain: [Data]?

    /// Private key (DER encoded) - alternative to file path
    public var privateKey: Data?

    /// Signing key for CertificateVerify (server and client for mTLS)
    public var signingKey: SigningKey?

    /// Whether to verify peer certificates (default: true)
    public var verifyPeer: Bool

    /// Trusted CA certificates for peer verification (DER encoded)
    public var trustedCACertificates: [Data]?

    /// Parsed trusted root certificates for chain validation
    public var trustedRootCertificates: [X509Certificate]?

    /// Expected peer public key for verification (x963 format for ECDSA)
    /// Used for simplified verification when full X.509 parsing is not needed
    public var expectedPeerPublicKey: Data?

    /// Whether to allow self-signed certificates
    public var allowSelfSigned: Bool

    /// Server name for SNI (client only)
    public var serverName: String?

    /// Session ticket for resumption (client only)
    public var sessionTicket: Data?

    /// Maximum early data size for 0-RTT (0 to disable)
    public var maxEarlyDataSize: UInt32

    /// Supported key exchange groups (in preference order)
    /// Used by server to select key share group or send HelloRetryRequest
    public var supportedGroups: [NamedGroup]

    /// Revocation checking mode for peer certificates.
    ///
    /// Controls how certificate revocation is checked during TLS handshake.
    /// Revocation checking is performed asynchronously after the synchronous
    /// certificate chain validation succeeds.
    ///
    /// - `.none`: No revocation checking (default)
    /// - `.ocspStapling`: OCSP stapling only (server provides response)
    /// - `.ocsp(allowOnlineCheck:softFail:)`: OCSP with optional online check
    /// - `.crl(cacheDirectory:softFail:)`: CRL checking with optional caching
    /// - `.bestEffort`: Try available methods, soft-fail if unavailable
    ///
    /// - Important: For production deployments, consider enabling at least
    ///   `.ocspStapling` or `.bestEffort` to detect revoked certificates.
    public var revocationCheckMode: RevocationCheckMode

    /// HTTP client for online revocation checks (OCSP, CRL).
    ///
    /// Required when `revocationCheckMode` involves online checks
    /// (`.ocsp(allowOnlineCheck: true, ...)`, `.crl(...)`, or `.bestEffort`).
    ///
    /// If `nil` and online checking is requested, online checks are skipped
    /// and the behavior depends on the `softFail` setting of the mode.
    public var revocationHTTPClient: HTTPClient?

    /// Replay protection for 0-RTT early data (server only)
    ///
    /// When set, the server will check incoming 0-RTT tickets against this
    /// replay protection instance. If a ticket has been seen before, the
    /// 0-RTT data is rejected but the handshake continues with 1-RTT.
    ///
    /// - Important: For production deployments, always set this to prevent
    ///   replay attacks on 0-RTT data.
    public var replayProtection: ReplayProtection?

    // MARK: - Mutual TLS (mTLS) Configuration

    /// Whether to require client certificate (server only).
    ///
    /// When `true`, the server sends a CertificateRequest message after EncryptedExtensions,
    /// and the client must respond with Certificate and CertificateVerify messages.
    ///
    /// RFC 8446 Section 4.3.2: "A server which is authenticating with a certificate
    /// MAY optionally request a certificate from the client."
    ///
    /// - Note: Set to `true` when mutual authentication is required.
    public var requireClientCertificate: Bool

    /// Custom certificate validator for peer certificates.
    ///
    /// Called after TLS signature verification (CertificateVerify) succeeds, but before
    /// the handshake is considered complete. This allows applications to:
    /// - Validate certificate content (extensions, constraints)
    /// - Extract application-specific data (e.g., peer identity)
    /// - Implement custom trust models (e.g., self-signed with specific extensions)
    ///
    /// If `nil`, only TLS-level verification is performed:
    /// - Certificate chain validation (if `trustedRootCertificates` is set)
    /// - CertificateVerify signature verification
    ///
    /// The returned value is stored and can be retrieved after handshake completion.
    ///
    /// - Important: This callback is called for BOTH server and client certificates
    ///   when mutual TLS is enabled.
    public var certificateValidator: CertificateValidator?

    /// Creates a default configuration
    public init() {
        self.alpnProtocols = ["h3"]
        self.certificatePath = nil
        self.privateKeyPath = nil
        self.certificateChain = nil
        self.privateKey = nil
        self.signingKey = nil
        self.verifyPeer = true
        self.trustedCACertificates = nil
        self.trustedRootCertificates = nil
        self.allowSelfSigned = false
        self.serverName = nil
        self.sessionTicket = nil
        self.maxEarlyDataSize = 0
        self.supportedGroups = [.x25519, .secp256r1]
        self.revocationCheckMode = .none
        self.revocationHTTPClient = nil
        self.replayProtection = nil
        self.requireClientCertificate = false
        self.certificateValidator = nil
    }

    /// Creates a client configuration
    public static func client(
        serverName: String? = nil,
        alpnProtocols: [String] = ["h3"]
    ) -> TLSConfiguration {
        var config = TLSConfiguration()
        config.serverName = serverName
        config.alpnProtocols = alpnProtocols
        return config
    }

    /// Creates a server configuration with inline signing key
    public static func server(
        signingKey: SigningKey,
        certificateChain: [Data],
        alpnProtocols: [String] = ["h3"]
    ) -> TLSConfiguration {
        var config = TLSConfiguration()
        config.signingKey = signingKey
        config.certificateChain = certificateChain
        config.alpnProtocols = alpnProtocols
        return config
    }

    /// Creates a server configuration with file paths
    ///
    /// This method loads the certificate and private key from PEM files
    /// and populates `certificateChain` and `signingKey`.
    ///
    /// - Parameters:
    ///   - certificatePath: Path to the PEM-encoded certificate file (may contain a chain)
    ///   - privateKeyPath: Path to the PEM-encoded private key file
    ///   - alpnProtocols: ALPN protocols to advertise
    /// - Returns: A configured TLSConfiguration
    /// - Throws: `PEMLoader.PEMError` if loading fails
    public static func server(
        certificatePath: String,
        privateKeyPath: String,
        alpnProtocols: [String] = ["h3"]
    ) throws -> TLSConfiguration {
        var config = TLSConfiguration()
        config.certificatePath = certificatePath
        config.privateKeyPath = privateKeyPath
        config.alpnProtocols = alpnProtocols

        // Load certificate and key from PEM files
        let (certificates, signingKey) = try PEMLoader.loadCertificateAndKey(
            certificatePath: certificatePath,
            privateKeyPath: privateKeyPath
        )
        config.certificateChain = certificates
        config.signingKey = signingKey

        return config
    }

    // MARK: - Trusted Root Helpers

    /// Returns the effective trusted root certificates for validation.
    ///
    /// This method resolves the trusted roots by:
    /// 1. Using `trustedRootCertificates` if already set (parsed `X509Certificate` objects)
    /// 2. Falling back to parsing `trustedCACertificates` (raw DER bytes) if set
    /// 3. Returns an empty array if neither is set
    ///
    /// This ensures that `trustedCACertificates` (DER) is no longer a dead field —
    /// it is automatically parsed when `trustedRootCertificates` is not explicitly provided.
    public var effectiveTrustedRoots: [X509Certificate] {
        if let roots = trustedRootCertificates, !roots.isEmpty {
            return roots
        }
        // Fall back to parsing DER-encoded CA certificates
        if let derCerts = trustedCACertificates, !derCerts.isEmpty {
            return derCerts.compactMap { try? X509Certificate.parse(from: $0) }
        }
        return []
    }

    /// Loads trusted CA certificates from a PEM file and sets `trustedRootCertificates`.
    ///
    /// This is a convenience method for configuring trusted CAs from PEM files,
    /// which is the most common format for CA bundles (e.g., `/etc/ssl/certs/ca-certificates.crt`).
    ///
    /// - Parameter path: Path to a PEM file containing one or more CA certificates
    /// - Throws: `PEMLoader.PEMError` if loading or parsing fails
    public mutating func loadTrustedCAs(fromPEMFile path: String) throws {
        let derCerts = try PEMLoader.loadCertificates(fromPath: path)
        let parsed = try derCerts.map { try X509Certificate.parse(from: $0) }
        if trustedRootCertificates == nil {
            trustedRootCertificates = parsed
        } else {
            trustedRootCertificates?.append(contentsOf: parsed)
        }
    }

    /// Loads trusted CA certificates from PEM-encoded string data and sets `trustedRootCertificates`.
    ///
    /// - Parameter pemString: PEM-encoded string containing one or more CA certificates
    /// - Throws: `PEMLoader.PEMError` if parsing fails
    public mutating func loadTrustedCAs(fromPEMString pemString: String) throws {
        let derCerts = try PEMLoader.parseCertificates(from: pemString)
        let parsed = try derCerts.map { try X509Certificate.parse(from: $0) }
        if trustedRootCertificates == nil {
            trustedRootCertificates = parsed
        } else {
            trustedRootCertificates?.append(contentsOf: parsed)
        }
    }

    /// Adds DER-encoded CA certificates to the trusted root store.
    ///
    /// Parses the provided DER data into `X509Certificate` objects and appends
    /// them to `trustedRootCertificates`.
    ///
    /// - Parameter derCertificates: Array of DER-encoded certificate data
    /// - Throws: If any certificate fails to parse
    public mutating func addTrustedCAs(derEncoded derCertificates: [Data]) throws {
        let parsed = try derCertificates.map { try X509Certificate.parse(from: $0) }
        if trustedRootCertificates == nil {
            trustedRootCertificates = parsed
        } else {
            trustedRootCertificates?.append(contentsOf: parsed)
        }
    }

    /// Whether this configuration has certificate material for server authentication
    public var hasCertificate: Bool {
        (certificateChain != nil && signingKey != nil) ||
        (certificatePath != nil && privateKeyPath != nil)
    }

    // MARK: - PEM Loading

    /// Loads certificate and private key from the configured file paths.
    ///
    /// Call this method to populate `certificateChain` and `signingKey` from
    /// `certificatePath` and `privateKeyPath`.
    ///
    /// - Throws: `PEMLoader.PEMError` if loading fails
    public mutating func loadFromPaths() throws {
        guard let certPath = certificatePath,
              let keyPath = privateKeyPath else {
            return  // Nothing to load
        }

        // Only load if not already populated
        guard certificateChain == nil || signingKey == nil else {
            return
        }

        let (certificates, key) = try PEMLoader.loadCertificateAndKey(
            certificatePath: certPath,
            privateKeyPath: keyPath
        )
        self.certificateChain = certificates
        self.signingKey = key
    }

    /// Returns a copy with certificates loaded from paths (if needed).
    ///
    /// This is useful for getting a resolved configuration without mutating the original.
    ///
    /// - Returns: A TLSConfiguration with `certificateChain` and `signingKey` populated
    /// - Throws: `PEMLoader.PEMError` if loading fails
    public func withLoadedCertificates() throws -> TLSConfiguration {
        var copy = self
        try copy.loadFromPaths()
        return copy
    }
}
