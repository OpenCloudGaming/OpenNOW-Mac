/// TLS 1.3 Early Data Extension (RFC 8446 Section 4.2.10)
///
/// The "early_data" extension indicates the client wishes to send 0-RTT data.
///
/// Context varies by message type:
/// - ClientHello: Empty (indicates client wants to send early data)
/// - EncryptedExtensions: Empty (server accepts early data)
/// - NewSessionTicket: Contains max_early_data_size
///
/// ```
/// struct {} Empty;
///
/// struct {
///     select (Handshake.msg_type) {
///         case new_session_ticket:   uint32 max_early_data_size;
///         case client_hello:         Empty;
///         case encrypted_extensions: Empty;
///     };
/// } EarlyDataIndication;
/// ```
///
/// For QUIC, early data is not sent as TLS application data, but as
/// 0-RTT QUIC packets. The max_early_data_size in NewSessionTicket
/// is set to 0xFFFFFFFF to indicate unlimited.

import Foundation

// MARK: - Early Data Extension

/// Early data extension for 0-RTT
public enum EarlyDataExtension: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .earlyData }

    /// ClientHello variant (empty - indicates desire to send early data)
    case clientHello

    /// EncryptedExtensions variant (empty - server accepts early data)
    case encryptedExtensions

    /// NewSessionTicket variant (contains max early data size)
    case newSessionTicket(maxEarlyDataSize: UInt32)

    // MARK: - QUIC Constants

    /// For QUIC, max_early_data_size is always 0xFFFFFFFF
    /// (early data size is controlled by QUIC transport parameters)
    public static let quicMaxEarlyDataSize: UInt32 = 0xFFFFFFFF

    // MARK: - Encoding

    public func encode() -> Data {
        switch self {
        case .clientHello, .encryptedExtensions:
            return Data()
        case .newSessionTicket(let maxSize):
            var writer = TLSWriter(capacity: 4)
            writer.writeUInt32(maxSize)
            return writer.finish()
        }
    }

    // MARK: - Decoding

    /// Decode ClientHello/EncryptedExtensions variant (empty)
    public static func decodeEmpty(from data: Data) throws -> EarlyDataExtension {
        guard data.isEmpty else {
            throw TLSDecodeError.invalidFormat("EarlyData: expected empty for ClientHello/EncryptedExtensions")
        }
        return .clientHello // or .encryptedExtensions - same encoding
    }

    /// Decode NewSessionTicket variant
    public static func decodeNewSessionTicket(from data: Data) throws -> EarlyDataExtension {
        guard data.count == 4 else {
            throw TLSDecodeError.invalidFormat("EarlyData in NewSessionTicket: expected 4 bytes")
        }

        var reader = TLSReader(data: data)
        let maxSize = try reader.readUInt32()
        return .newSessionTicket(maxEarlyDataSize: maxSize)
    }
}

// MARK: - End of Early Data Message

/// EndOfEarlyData message (RFC 8446 Section 4.5)
///
/// ```
/// struct {} EndOfEarlyData;
/// ```
///
/// Sent by the client after all 0-RTT application data to signal
/// the end of early data. This message is encrypted under the
/// handshake traffic key.
public struct EndOfEarlyData: Sendable {
    public init() {}

    public func encode() -> Data {
        Data()
    }

    public func encodeMessage() -> Data {
        HandshakeCodec.encode(type: .endOfEarlyData, content: Data())
    }

    public static func decode(from data: Data) throws -> EndOfEarlyData {
        guard data.isEmpty else {
            throw TLSDecodeError.invalidFormat("EndOfEarlyData must be empty")
        }
        return EndOfEarlyData()
    }
}

// MARK: - Early Data State

/// State tracking for 0-RTT early data
public struct EarlyDataState: Sendable {
    /// Whether early data is being attempted
    public var attemptingEarlyData: Bool = false

    /// Whether server accepted early data
    public var earlyDataAccepted: Bool = false

    /// Maximum early data size from ticket
    public var maxEarlyDataSize: UInt32 = 0

    /// Amount of early data sent
    public var earlyDataSent: UInt32 = 0

    /// Client early traffic secret (for 0-RTT encryption)
    public var clientEarlyTrafficSecret: Data?

    public init() {}

    /// Check if more early data can be sent
    public var canSendMoreEarlyData: Bool {
        guard attemptingEarlyData else { return false }
        guard maxEarlyDataSize > 0 else { return false }
        return earlyDataSent < maxEarlyDataSize
    }

    /// Record early data being sent
    public mutating func recordEarlyData(size: UInt32) {
        earlyDataSent = earlyDataSent.addingReportingOverflow(size).partialValue
    }
}
