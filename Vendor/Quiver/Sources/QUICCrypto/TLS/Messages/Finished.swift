/// TLS 1.3 Finished Message (RFC 8446 Section 4.4.4)
///
/// ```
/// struct {
///     opaque verify_data[Hash.length];
/// } Finished;
/// ```
///
/// The verify_data is computed as:
/// ```
/// verify_data = HMAC(finished_key, Transcript-Hash(Handshake Context, Certificate*, CertificateVerify*))
/// finished_key = HKDF-Expand-Label(BaseKey, "finished", "", Hash.length)
/// ```

import Foundation

// MARK: - Finished Message

/// TLS 1.3 Finished message
public struct Finished: Sendable {

    /// The verify data (HMAC of transcript)
    public let verifyData: Data

    // MARK: - Initialization

    public init(verifyData: Data) {
        self.verifyData = verifyData
    }

    // MARK: - Encoding

    /// Encodes the Finished content (without handshake header)
    public func encode() -> Data {
        // Finished message is just the verify_data with no length prefix
        verifyData
    }

    /// Encodes as a complete handshake message (with header)
    public func encodeAsHandshake() -> Data {
        HandshakeCodec.encode(type: .finished, content: encode())
    }

    // MARK: - Decoding

    /// Decodes Finished from content data (without handshake header)
    /// - Parameters:
    ///   - data: The content data
    ///   - hashLength: Expected hash length (32 for SHA-256, 48 for SHA-384)
    public static func decode(from data: Data, hashLength: Int = TLSConstants.verifyDataLength) throws -> Finished {
        guard data.count == hashLength else {
            throw TLSDecodeError.invalidFormat("Invalid verify data length: expected \(hashLength), got \(data.count)")
        }
        return Finished(verifyData: data)
    }

    // MARK: - Verification

    /// Verify the finished message against expected verify data
    public func verify(expected: Data) -> Bool {
        guard verifyData.count == expected.count else {
            return false
        }
        // Constant-time comparison
        var result: UInt8 = 0
        for i in 0..<verifyData.count {
            result |= verifyData[verifyData.startIndex + i] ^ expected[expected.startIndex + i]
        }
        return result == 0
    }
}

// MARK: - Key Update Message

/// TLS 1.3 KeyUpdate message (RFC 8446 Section 4.6.3)
///
/// ```
/// struct {
///     KeyUpdateRequest request_update;
/// } KeyUpdate;
///
/// enum {
///     update_not_requested(0),
///     update_requested(1),
///     (255)
/// } KeyUpdateRequest;
/// ```
public struct KeyUpdate: Sendable {

    /// Whether a key update is requested from the peer
    public enum RequestUpdate: UInt8, Sendable {
        case updateNotRequested = 0
        case updateRequested = 1
    }

    /// The request update value
    public let requestUpdate: RequestUpdate

    // MARK: - Initialization

    public init(requestUpdate: RequestUpdate) {
        self.requestUpdate = requestUpdate
    }

    // MARK: - Encoding

    /// Encodes the KeyUpdate content (without handshake header)
    public func encode() -> Data {
        Data([requestUpdate.rawValue])
    }

    /// Encodes as a complete handshake message (with header)
    public func encodeAsHandshake() -> Data {
        HandshakeCodec.encode(type: .keyUpdate, content: encode())
    }

    // MARK: - Decoding

    /// Decodes KeyUpdate from content data (without handshake header)
    public static func decode(from data: Data) throws -> KeyUpdate {
        guard data.count == 1 else {
            throw TLSDecodeError.invalidFormat("Invalid KeyUpdate length: \(data.count)")
        }
        guard let requestUpdate = RequestUpdate(rawValue: data[data.startIndex]) else {
            throw TLSDecodeError.invalidFormat("Invalid KeyUpdateRequest: \(data[data.startIndex])")
        }
        return KeyUpdate(requestUpdate: requestUpdate)
    }
}
