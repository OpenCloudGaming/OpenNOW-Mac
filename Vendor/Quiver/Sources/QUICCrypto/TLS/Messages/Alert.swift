/// TLS 1.3 Alert Protocol (RFC 8446 Section 6)
///
/// ```
/// enum { warning(1), fatal(2), (255) } AlertLevel;
///
/// enum {
///     close_notify(0),
///     unexpected_message(10),
///     bad_record_mac(20),
///     ...
///     (255)
/// } AlertDescription;
///
/// struct {
///     AlertLevel level;
///     AlertDescription description;
/// } Alert;
/// ```

import Foundation

// MARK: - Alert Level

/// TLS Alert Level (RFC 8446 Section 6)
public enum AlertLevel: UInt8, Sendable {
    /// Warning - connection may continue
    case warning = 1
    /// Fatal - connection must be terminated immediately
    case fatal = 2
}

// MARK: - Alert Description

/// TLS Alert Description codes (RFC 8446 Section 6.2)
public enum AlertDescription: UInt8, Sendable {
    // Closure alerts
    /// Graceful connection closure
    case closeNotify = 0

    // Error alerts
    /// Inappropriate message received
    case unexpectedMessage = 10
    /// Record MAC verification failed
    case badRecordMac = 20
    /// Record length exceeded
    case recordOverflow = 22
    /// Handshake negotiation failed
    case handshakeFailure = 40
    /// Certificate was invalid
    case badCertificate = 42
    /// Certificate type not supported
    case unsupportedCertificate = 43
    /// Certificate was revoked
    case certificateRevoked = 44
    /// Certificate has expired
    case certificateExpired = 45
    /// Unknown certificate error
    case certificateUnknown = 46
    /// Illegal parameter in handshake
    case illegalParameter = 47
    /// Unknown certificate authority
    case unknownCA = 48
    /// Access denied
    case accessDenied = 49
    /// Message could not be decoded
    case decodeError = 50
    /// Decryption failed
    case decryptError = 51
    /// Protocol version not supported
    case protocolVersion = 70
    /// Security requirements not met
    case insufficientSecurity = 71
    /// Internal error
    case internalError = 80
    /// Inappropriate fallback detected
    case inappropriateFallback = 86
    /// User canceled connection
    case userCanceled = 90
    /// Required extension missing
    case missingExtension = 109
    /// Unsupported extension received
    case unsupportedExtension = 110
    /// Server name not recognized
    case unrecognizedName = 112
    /// Bad certificate status response (OCSP)
    case badCertificateStatusResponse = 113
    /// Unknown PSK identity
    case unknownPSKIdentity = 115
    /// Certificate required but not provided
    case certificateRequired = 116
    /// No common ALPN protocol
    case noApplicationProtocol = 120

    /// Human-readable description
    public var description: String {
        switch self {
        case .closeNotify: return "close_notify"
        case .unexpectedMessage: return "unexpected_message"
        case .badRecordMac: return "bad_record_mac"
        case .recordOverflow: return "record_overflow"
        case .handshakeFailure: return "handshake_failure"
        case .badCertificate: return "bad_certificate"
        case .unsupportedCertificate: return "unsupported_certificate"
        case .certificateRevoked: return "certificate_revoked"
        case .certificateExpired: return "certificate_expired"
        case .certificateUnknown: return "certificate_unknown"
        case .illegalParameter: return "illegal_parameter"
        case .unknownCA: return "unknown_ca"
        case .accessDenied: return "access_denied"
        case .decodeError: return "decode_error"
        case .decryptError: return "decrypt_error"
        case .protocolVersion: return "protocol_version"
        case .insufficientSecurity: return "insufficient_security"
        case .internalError: return "internal_error"
        case .inappropriateFallback: return "inappropriate_fallback"
        case .userCanceled: return "user_canceled"
        case .missingExtension: return "missing_extension"
        case .unsupportedExtension: return "unsupported_extension"
        case .unrecognizedName: return "unrecognized_name"
        case .badCertificateStatusResponse: return "bad_certificate_status_response"
        case .unknownPSKIdentity: return "unknown_psk_identity"
        case .certificateRequired: return "certificate_required"
        case .noApplicationProtocol: return "no_application_protocol"
        }
    }

    /// Whether this alert is always fatal in TLS 1.3
    /// Per RFC 8446 Section 6: "All alerts listed below are fatal in TLS 1.3"
    /// except for close_notify and user_canceled
    public var isFatal: Bool {
        switch self {
        case .closeNotify, .userCanceled:
            return false
        default:
            return true
        }
    }
}

// MARK: - Alert Message

/// TLS Alert message (RFC 8446 Section 6)
///
/// In TLS 1.3, most alerts are fatal. The only non-fatal alerts are:
/// - close_notify (graceful closure)
/// - user_canceled
///
/// For QUIC (RFC 9001), alerts are converted to CONNECTION_CLOSE frames
/// with error codes in the crypto error space (0x100 + alert code).
public struct TLSAlert: Sendable, Equatable {
    /// Alert level
    public let level: AlertLevel

    /// Alert description
    public let alertDescription: AlertDescription

    // MARK: - Initialization

    /// Creates an alert with explicit level
    public init(level: AlertLevel, description: AlertDescription) {
        self.level = level
        self.alertDescription = description
    }

    /// Creates an alert with appropriate level for the description
    /// (fatal for most alerts, warning for close_notify and user_canceled)
    public init(description: AlertDescription) {
        self.level = description.isFatal ? .fatal : .warning
        self.alertDescription = description
    }

    // MARK: - Common Alerts

    /// Graceful connection closure
    public static let closeNotify = TLSAlert(description: .closeNotify)

    /// Unexpected message received
    public static let unexpectedMessage = TLSAlert(description: .unexpectedMessage)

    /// Decode error
    public static let decodeError = TLSAlert(description: .decodeError)

    /// Handshake failure
    public static let handshakeFailure = TLSAlert(description: .handshakeFailure)

    /// Internal error
    public static let internalError = TLSAlert(description: .internalError)

    /// Protocol version not supported
    public static let protocolVersion = TLSAlert(description: .protocolVersion)

    /// No common ALPN
    public static let noApplicationProtocol = TLSAlert(description: .noApplicationProtocol)

    /// Missing required extension
    public static let missingExtension = TLSAlert(description: .missingExtension)

    /// Bad certificate
    public static let badCertificate = TLSAlert(description: .badCertificate)

    /// Certificate verification failed
    public static let certificateUnknown = TLSAlert(description: .certificateUnknown)

    /// Illegal parameter
    public static let illegalParameter = TLSAlert(description: .illegalParameter)

    /// Decrypt error
    public static let decryptError = TLSAlert(description: .decryptError)

    // MARK: - Encoding

    /// Encode the alert as 2 bytes
    public func encode() -> Data {
        Data([level.rawValue, alertDescription.rawValue])
    }

    /// Encode as a complete handshake message (rarely used - alerts have their own content type)
    public func encodeAsRecord() -> Data {
        // TLS record: content_type(21=alert) + version + length + alert
        var data = Data(capacity: 7)
        data.append(21)  // ContentType.alert
        data.append(0x03)  // Version high byte (TLS 1.2 for compatibility)
        data.append(0x03)  // Version low byte
        data.append(0x00)  // Length high byte
        data.append(0x02)  // Length low byte (2 bytes)
        data.append(contentsOf: encode())
        return data
    }

    // MARK: - Decoding

    /// Decode an alert from data
    public static func decode(from data: Data) throws -> TLSAlert {
        guard data.count >= 2 else {
            throw TLSDecodeError.invalidFormat("Alert too short")
        }

        guard let level = AlertLevel(rawValue: data[0]) else {
            throw TLSDecodeError.invalidFormat("Unknown alert level: \(data[0])")
        }

        guard let description = AlertDescription(rawValue: data[1]) else {
            // Unknown alert description - treat as unknown
            throw TLSDecodeError.invalidFormat("Unknown alert description: \(data[1])")
        }

        return TLSAlert(level: level, description: description)
    }

    // MARK: - QUIC Error Code

    /// Convert to QUIC crypto error code (RFC 9001 Section 4.8)
    /// QUIC crypto errors are 0x100 + TLS alert code
    public var quicErrorCode: UInt64 {
        0x100 + UInt64(alertDescription.rawValue)
    }

    /// Create from QUIC crypto error code
    public static func fromQUICErrorCode(_ code: UInt64) -> TLSAlert? {
        guard code >= 0x100 && code <= 0x1FF else { return nil }
        let alertCode = UInt8(code - 0x100)
        guard let description = AlertDescription(rawValue: alertCode) else { return nil }
        return TLSAlert(description: description)
    }
}

// MARK: - CustomStringConvertible

extension TLSAlert: CustomStringConvertible {
    public var description: String {
        let levelStr = level == .fatal ? "fatal" : "warning"
        return "TLSAlert(\(levelStr): \(alertDescription.description))"
    }
}
