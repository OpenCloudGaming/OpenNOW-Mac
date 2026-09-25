/// TLS Output Types (RFC 9001)
///
/// Output events from TLS processing during QUIC handshake.

import Foundation
import Crypto
import QUICCore

// MARK: - TLS Output

/// Output from TLS handshake processing
public enum TLSOutput: Sendable {
    /// Handshake data to be sent at a specific encryption level
    case handshakeData(Data, level: EncryptionLevel)

    /// New keys are available for an encryption level
    case keysAvailable(KeysAvailableInfo)

    /// The handshake is complete
    case handshakeComplete(HandshakeCompleteInfo)

    /// More data is needed before further progress can be made
    case needMoreData

    /// An error occurred during TLS processing
    case error(TLSError)

    /// A TLS alert to be sent to the peer (RFC 8446 Section 6)
    /// For QUIC, this is converted to a CONNECTION_CLOSE frame
    case alert(TLSAlert)

    /// A NewSessionTicket was received (RFC 8446 Section 4.6.1)
    ///
    /// This is sent post-handshake by servers to enable session resumption.
    /// Clients should store this ticket for future connections.
    case newSessionTicket(NewSessionTicketInfo)
}

// MARK: - NewSessionTicket Info

/// Information about a received NewSessionTicket
public struct NewSessionTicketInfo: Sendable {
    /// The raw NewSessionTicket message
    public let ticket: NewSessionTicket

    /// The resumption master secret for deriving the PSK
    public let resumptionMasterSecret: SymmetricKey

    /// The cipher suite used in this connection
    public let cipherSuite: CipherSuite

    /// The negotiated ALPN protocol (if any)
    public let alpn: String?

    /// Creates new session ticket info
    public init(
        ticket: NewSessionTicket,
        resumptionMasterSecret: SymmetricKey,
        cipherSuite: CipherSuite,
        alpn: String? = nil
    ) {
        self.ticket = ticket
        self.resumptionMasterSecret = resumptionMasterSecret
        self.cipherSuite = cipherSuite
        self.alpn = alpn
    }
}

// MARK: - Keys Available Info

/// Information about newly available keys
public struct KeysAvailableInfo: Sendable {
    /// The encryption level for these keys
    public let level: EncryptionLevel

    /// Client traffic secret
    public let clientSecret: SymmetricKey?

    /// Server traffic secret
    public let serverSecret: SymmetricKey?

    /// The negotiated cipher suite for packet protection
    public let cipherSuite: QUICCipherSuite

    /// Creates keys available info
    public init(
        level: EncryptionLevel,
        clientSecret: SymmetricKey?,
        serverSecret: SymmetricKey?,
        cipherSuite: QUICCipherSuite = .aes128GcmSha256
    ) {
        self.level = level
        self.clientSecret = clientSecret
        self.serverSecret = serverSecret
        self.cipherSuite = cipherSuite
    }
}

// MARK: - Handshake Complete Info

/// Information about handshake completion
public struct HandshakeCompleteInfo: Sendable {
    /// The negotiated ALPN protocol
    public let alpn: String?

    /// Whether 0-RTT was accepted
    public let zeroRTTAccepted: Bool

    /// Session resumption ticket (if any)
    public let resumptionTicket: Data?

    /// Creates handshake complete info
    public init(
        alpn: String? = nil,
        zeroRTTAccepted: Bool = false,
        resumptionTicket: Data? = nil
    ) {
        self.alpn = alpn
        self.zeroRTTAccepted = zeroRTTAccepted
        self.resumptionTicket = resumptionTicket
    }
}

// MARK: - TLS Error

/// Errors that can occur during TLS processing
public enum TLSError: Error, Sendable {
    /// Handshake failed with an alert
    case handshakeFailed(alert: UInt8, description: String)

    /// Certificate verification failed
    case certificateVerificationFailed(String)

    /// No common cipher suite
    case noCipherSuiteMatch

    /// No common ALPN protocol
    case noALPNMatch

    /// Invalid transport parameters
    case invalidTransportParameters(String)

    /// Unexpected message
    case unexpectedMessage(String)

    /// Internal error
    case internalError(String)

    /// Convert this error to a TLS Alert
    public var toAlert: TLSAlert {
        switch self {
        case .handshakeFailed(let alert, _):
            if let desc = AlertDescription(rawValue: alert) {
                return TLSAlert(description: desc)
            }
            return TLSAlert(description: .handshakeFailure)
        case .certificateVerificationFailed:
            return TLSAlert(description: .badCertificate)
        case .noCipherSuiteMatch:
            return TLSAlert(description: .handshakeFailure)
        case .noALPNMatch:
            return TLSAlert(description: .noApplicationProtocol)
        case .invalidTransportParameters:
            return TLSAlert(description: .illegalParameter)
        case .unexpectedMessage:
            return TLSAlert(description: .unexpectedMessage)
        case .internalError:
            return TLSAlert(description: .internalError)
        }
    }
}
