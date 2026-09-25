/// TLS 1.3 Transcript Hash (RFC 8446 Section 4.4.1)
///
/// The transcript hash maintains a running hash of all handshake messages.
/// It is used in key derivation and message verification.
///
/// For TLS 1.3, this is:
/// ```
/// Transcript-Hash(M1, M2, ... Mn) = Hash(M1 || M2 || ... || Mn)
/// ```

import Foundation
import Crypto

// MARK: - Transcript Hash

/// Maintains a running hash of handshake messages
/// Supports both SHA-256 and SHA-384 based on cipher suite
public struct TranscriptHash: Sendable {
    /// Hash function variant
    private enum Hasher: Sendable {
        case sha256(SHA256)
        case sha384(SHA384)
    }

    /// The hash function context
    private var hasher: Hasher

    /// Accumulated messages (for debugging/verification)
    private var messageCount: Int

    /// Hash output length in bytes
    public let hashLength: Int

    // MARK: - Initialization

    /// Initialize with default SHA-256
    public init() {
        self.hasher = .sha256(SHA256())
        self.messageCount = 0
        self.hashLength = 32
    }

    /// Initialize with specific cipher suite
    public init(cipherSuite: CipherSuite) {
        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            self.hasher = .sha384(SHA384())
            self.hashLength = 48
        default:
            self.hasher = .sha256(SHA256())
            self.hashLength = 32
        }
        self.messageCount = 0
    }

    /// Internal init for copy operations
    private init(hasher: Hasher, messageCount: Int, hashLength: Int) {
        self.hasher = hasher
        self.messageCount = messageCount
        self.hashLength = hashLength
    }

    // MARK: - Update

    /// Update the transcript with a handshake message
    /// - Parameter message: The complete handshake message (including 4-byte header)
    public mutating func update(with message: Data) {
        switch hasher {
        case .sha256(var h):
            h.update(data: message)
            hasher = .sha256(h)
        case .sha384(var h):
            h.update(data: message)
            hasher = .sha384(h)
        }
        messageCount += 1
    }

    /// Update the transcript with raw data
    /// - Parameter data: Raw data to hash
    public mutating func updateRaw(with data: Data) {
        switch hasher {
        case .sha256(var h):
            h.update(data: data)
            hasher = .sha256(h)
        case .sha384(var h):
            h.update(data: data)
            hasher = .sha384(h)
        }
    }

    // MARK: - Hash Value

    /// Get the current transcript hash value
    /// - Returns: The hash (32 bytes for SHA-256, 48 bytes for SHA-384)
    public func currentHash() -> Data {
        switch hasher {
        case .sha256(let h):
            let copy = h
            return Data(copy.finalize())
        case .sha384(let h):
            let copy = h
            return Data(copy.finalize())
        }
    }

    /// Number of messages hashed
    public var count: Int { messageCount }

    // MARK: - Special Operations

    /// Create a transcript hash from a message hash (for HelloRetryRequest)
    /// Per RFC 8446 Section 4.4.1:
    /// ```
    /// Transcript-Hash(ClientHello1, HelloRetryRequest, ... Mn) =
    ///     Hash(message_hash ||     /* Handshake type */
    ///          00 00 Hash.length ||  /* Uint24 length */
    ///          Hash(ClientHello1) || /* Hash */
    ///          HelloRetryRequest || ... || Mn)
    /// ```
    public static func fromMessageHash(
        clientHello1Hash: Data,
        cipherSuite: CipherSuite = .tls_aes_128_gcm_sha256
    ) -> TranscriptHash {
        var transcript = TranscriptHash(cipherSuite: cipherSuite)

        // Construct synthetic message_hash message
        var syntheticMessage = Data(capacity: 4 + clientHello1Hash.count)
        syntheticMessage.append(HandshakeType.messageHash.rawValue)  // Type
        syntheticMessage.append(0x00)  // Length high byte
        syntheticMessage.append(0x00)  // Length mid byte
        syntheticMessage.append(UInt8(clientHello1Hash.count))  // Length low byte
        syntheticMessage.append(clientHello1Hash)

        transcript.update(with: syntheticMessage)
        return transcript
    }

    /// Create a copy of the transcript hash
    public func copy() -> TranscriptHash {
        TranscriptHash(hasher: hasher, messageCount: messageCount, hashLength: hashLength)
    }
}

// MARK: - Transcript Hash with SHA-384

/// Transcript hash using SHA-384 (for TLS_AES_256_GCM_SHA384)
public struct TranscriptHashSHA384: Sendable {
    private var hasher: SHA384
    private var messageCount: Int

    public init() {
        self.hasher = SHA384()
        self.messageCount = 0
    }

    public mutating func update(with message: Data) {
        hasher.update(data: message)
        messageCount += 1
    }

    public mutating func updateRaw(with data: Data) {
        hasher.update(data: data)
    }

    public func currentHash() -> Data {
        let copy = hasher
        return Data(copy.finalize())
    }

    public static var hashLength: Int { 48 }

    public var count: Int { messageCount }

    public func copy() -> TranscriptHashSHA384 {
        var newTranscript = TranscriptHashSHA384()
        newTranscript.hasher = self.hasher
        newTranscript.messageCount = self.messageCount
        return newTranscript
    }
}
