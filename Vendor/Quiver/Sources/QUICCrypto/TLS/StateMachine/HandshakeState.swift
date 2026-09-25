/// TLS 1.3 Handshake State (RFC 8446 Section 2)
///
/// Defines the state machine for TLS 1.3 handshake.

import Foundation
import Crypto

// MARK: - Client Handshake State

/// Client-side handshake state
public enum ClientHandshakeState: Sendable, Equatable {
    /// Initial state before ClientHello is sent
    case start

    /// Waiting for ServerHello after sending ClientHello
    case waitServerHello

    /// Waiting for ServerHello after HelloRetryRequest (second attempt)
    case waitServerHelloRetry

    /// Waiting for EncryptedExtensions
    case waitEncryptedExtensions

    /// Waiting for CertificateRequest or Certificate
    /// (CertificateRequest is optional - server may or may not request client auth)
    case waitCertificateOrCertificateRequest

    /// Waiting for Certificate (after receiving CertificateRequest)
    case waitCertificate

    /// Waiting for CertificateVerify
    case waitCertificateVerify

    /// Waiting for Finished
    case waitFinished

    /// Handshake complete, connection established
    case connected

    /// Error state
    case failed(TLSHandshakeError)
}

// MARK: - Server Handshake State

/// Server-side handshake state
public enum ServerHandshakeState: Sendable, Equatable {
    /// Initial state, waiting for ClientHello
    case start

    /// Received ClientHello, need to send response
    case recvdClientHello

    /// Sent HelloRetryRequest, waiting for ClientHello2
    case sentHelloRetryRequest

    /// Waiting for client Certificate (when mTLS is enabled)
    case waitClientCertificate

    /// Waiting for client CertificateVerify (when mTLS is enabled)
    case waitClientCertificateVerify

    /// Waiting for client Finished
    case waitFinished

    /// Handshake complete, connection established
    case connected

    /// Error state
    case failed(TLSHandshakeError)
}

// MARK: - Handshake Error

/// Errors that can occur during TLS handshake
public enum TLSHandshakeError: Error, Sendable, Equatable {
    /// Unexpected message in current state
    case unexpectedMessage(String)

    /// Protocol version mismatch
    case unsupportedVersion

    /// No common cipher suite
    case noCipherSuiteMatch

    /// No common named group for key exchange
    case noKeyShareMatch

    /// No common ALPN protocol
    case noALPNMatch

    /// Certificate verification failed
    case certificateVerificationFailed(String)

    /// Signature verification failed
    case signatureVerificationFailed

    /// Finished message verification failed
    case finishedVerificationFailed

    /// Missing required extension
    case missingExtension(String)

    /// Invalid extension
    case invalidExtension(String)

    /// Key exchange failed
    case keyExchangeFailed(String)

    /// Decryption failed
    case decryptionFailed

    /// Internal error
    case internalError(String)

    /// Client certificate required but not provided
    case certificateRequired

    /// Decode error (malformed message)
    case decodeError(String)

    public static func == (lhs: TLSHandshakeError, rhs: TLSHandshakeError) -> Bool {
        switch (lhs, rhs) {
        case (.unexpectedMessage(let l), .unexpectedMessage(let r)): return l == r
        case (.unsupportedVersion, .unsupportedVersion): return true
        case (.noCipherSuiteMatch, .noCipherSuiteMatch): return true
        case (.noKeyShareMatch, .noKeyShareMatch): return true
        case (.noALPNMatch, .noALPNMatch): return true
        case (.certificateVerificationFailed(let l), .certificateVerificationFailed(let r)): return l == r
        case (.signatureVerificationFailed, .signatureVerificationFailed): return true
        case (.finishedVerificationFailed, .finishedVerificationFailed): return true
        case (.missingExtension(let l), .missingExtension(let r)): return l == r
        case (.invalidExtension(let l), .invalidExtension(let r)): return l == r
        case (.keyExchangeFailed(let l), .keyExchangeFailed(let r)): return l == r
        case (.decryptionFailed, .decryptionFailed): return true
        case (.internalError(let l), .internalError(let r)): return l == r
        case (.certificateRequired, .certificateRequired): return true
        case (.decodeError(let l), .decodeError(let r)): return l == r
        default: return false
        }
    }

    /// Convert this error to a TLS Alert for sending to the peer
    public var toAlert: TLSAlert {
        switch self {
        case .unexpectedMessage:
            return TLSAlert(description: .unexpectedMessage)
        case .unsupportedVersion:
            return TLSAlert(description: .protocolVersion)
        case .noCipherSuiteMatch:
            return TLSAlert(description: .handshakeFailure)
        case .noKeyShareMatch:
            return TLSAlert(description: .handshakeFailure)
        case .noALPNMatch:
            return TLSAlert(description: .noApplicationProtocol)
        case .certificateVerificationFailed:
            return TLSAlert(description: .badCertificate)
        case .signatureVerificationFailed:
            return TLSAlert(description: .decryptError)
        case .finishedVerificationFailed:
            return TLSAlert(description: .decryptError)
        case .missingExtension:
            return TLSAlert(description: .missingExtension)
        case .invalidExtension:
            return TLSAlert(description: .illegalParameter)
        case .keyExchangeFailed:
            return TLSAlert(description: .handshakeFailure)
        case .decryptionFailed:
            return TLSAlert(description: .decryptError)
        case .internalError:
            return TLSAlert(description: .internalError)
        case .certificateRequired:
            return TLSAlert(description: .certificateRequired)
        case .decodeError:
            return TLSAlert(description: .decodeError)
        }
    }
}

// MARK: - Handshake Context

/// Context maintained during handshake
public struct HandshakeContext: Sendable {
    /// The negotiated cipher suite
    public var cipherSuite: CipherSuite?

    /// Our ephemeral key exchange key pair
    public var keyExchange: KeyExchange?

    /// The shared secret from key agreement
    public var sharedSecret: SharedSecret?

    /// The transcript hash
    public var transcriptHash: TranscriptHash

    /// The key schedule
    public var keySchedule: TLSKeySchedule

    /// Negotiated ALPN protocol
    public var negotiatedALPN: String?

    /// Local transport parameters (for QUIC)
    public var localTransportParameters: Data?

    /// Peer transport parameters (for QUIC)
    public var peerTransportParameters: Data?

    /// Client random (from ClientHello)
    public var clientRandom: Data?

    /// Server random (from ServerHello)
    public var serverRandom: Data?

    /// Session ID (for middlebox compatibility)
    public var sessionID: Data?

    /// Client handshake traffic secret
    public var clientHandshakeSecret: SymmetricKey?

    /// Server handshake traffic secret
    public var serverHandshakeSecret: SymmetricKey?

    /// Client application traffic secret
    public var clientApplicationSecret: SymmetricKey?

    /// Server application traffic secret
    public var serverApplicationSecret: SymmetricKey?

    /// Exporter master secret (RFC 8446 Section 7.5)
    public var exporterMasterSecret: SymmetricKey?

    /// Peer certificates (raw DER data)
    public var peerCertificates: [Data]?

    /// Parsed peer leaf certificate (for signature verification)
    public var peerCertificate: X509Certificate?

    /// Peer's public key extracted from certificate
    public var peerVerificationKey: VerificationKey?

    /// Original ClientHello1 hash (for HelloRetryRequest handling)
    public var originalClientHello1Hash: Data?

    /// Whether we have already received a HelloRetryRequest
    public var receivedHelloRetryRequest: Bool = false

    /// Whether we have already sent a HelloRetryRequest (server-side)
    public var sentHelloRetryRequest: Bool = false

    /// The key exchange group requested in HelloRetryRequest (server-side)
    public var helloRetryRequestGroup: NamedGroup?

    // MARK: - PSK/Session Resumption

    /// Session ticket data for resumption (client-side)
    public var sessionTicket: SessionTicketData?

    /// Whether PSK was used for this handshake
    public var pskUsed: Bool = false

    /// Selected PSK identity index (for PSK handshakes)
    public var selectedPskIdentity: UInt16?

    /// Resumption master secret (for deriving new PSKs)
    public var resumptionMasterSecret: SymmetricKey?

    /// Binder key for PSK binder computation
    public var binderKey: SymmetricKey?

    /// Early data state tracking
    public var earlyDataState: EarlyDataState = EarlyDataState()

    /// Client early traffic secret (for 0-RTT)
    public var clientEarlyTrafficSecret: SymmetricKey?

    // MARK: - Mutual TLS (mTLS) State

    /// Whether server requested client certificate (client-side flag).
    ///
    /// Set to `true` when client receives CertificateRequest from server.
    /// Used to determine if client needs to send Certificate/CertificateVerify.
    public var clientCertificateRequested: Bool = false

    /// The certificate_request_context from CertificateRequest (client-side).
    ///
    /// RFC 8446 Section 4.4.2: "The certificate_request_context MUST be echoed
    /// in the Certificate message."
    public var certificateRequestContext: Data = Data()

    /// Whether server is expecting client certificate (server-side flag).
    ///
    /// Set to `true` when server sends CertificateRequest.
    public var expectingClientCertificate: Bool = false

    /// Client's certificates received by server (raw DER data).
    ///
    /// Stored after receiving client's Certificate message.
    public var clientCertificates: [Data]?

    /// Parsed client leaf certificate (server-side).
    ///
    /// Used for signature verification in CertificateVerify.
    public var clientCertificate: X509Certificate?

    /// Client's public key extracted from certificate (server-side).
    ///
    /// Used to verify client's CertificateVerify signature.
    public var clientVerificationKey: VerificationKey?

    /// Application-specific peer info from certificate validator.
    ///
    /// Stores the return value from `TLSConfiguration.certificateValidator`.
    /// For example, this could be an application-specific peer identity.
    public var validatedPeerInfo: (any Sendable)?

    /// Validated certificate chain from X.509 validation (Phase B).
    ///
    /// Stored after synchronous chain validation succeeds in `processCertificate()`
    /// (client-side) or `processClientCertificate()` (server-side).
    /// Used by `TLS13Handler` to perform async revocation checks after
    /// the synchronous state machine processing completes.
    public var validatedChain: ValidatedChain?

    public init() {
        self.transcriptHash = TranscriptHash()
        self.keySchedule = TLSKeySchedule()
    }
}
