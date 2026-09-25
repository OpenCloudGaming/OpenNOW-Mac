/// QUIC Initial Secrets Derivation (RFC 9001 Section 5.2)
///
/// Initial packets are encrypted using keys derived from the
/// Destination Connection ID and a version-specific salt.

import Foundation
import Crypto
import QUICCore

// MARK: - Initial Secrets

/// Derives initial secrets from a connection ID
public struct InitialSecrets: Sendable {
    /// Client initial secret
    public let clientSecret: SymmetricKey

    /// Server initial secret
    public let serverSecret: SymmetricKey

    /// Derives initial secrets for the given connection ID and version
    /// - Parameters:
    ///   - connectionID: The Destination Connection ID from the first Initial packet
    ///   - version: The QUIC version
    /// - Returns: The derived initial secrets
    public static func derive(
        connectionID: ConnectionID,
        version: QUICVersion
    ) throws -> InitialSecrets {
        guard let salt = version.initialSalt else {
            throw QUICError.unsupportedVersion(version.rawValue)
        }

        // Extract initial secret using HKDF
        // initial_secret = HKDF-Extract(initial_salt, cid)
        let initialSecret = deriveInitialSecret(connectionID: connectionID, salt: salt)

        // Derive client and server secrets
        // client_initial_secret = HKDF-Expand-Label(initial_secret, "client in", "", 32)
        // server_initial_secret = HKDF-Expand-Label(initial_secret, "server in", "", 32)
        let clientSecret = try hkdfExpandLabel(
            secret: initialSecret,
            label: "client in",
            context: Data(),
            length: 32
        )

        let serverSecret = try hkdfExpandLabel(
            secret: initialSecret,
            label: "server in",
            context: Data(),
            length: 32
        )

        return InitialSecrets(
            clientSecret: SymmetricKey(data: clientSecret),
            serverSecret: SymmetricKey(data: serverSecret)
        )
    }

    private static func deriveInitialSecret(connectionID: ConnectionID, salt: Data) -> SymmetricKey {
        // HKDF-Extract with salt and connection ID
        let prk = HKDF<SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: connectionID.bytes),
            salt: salt
        )
        // Convert HashedAuthenticationCode to SymmetricKey
        return SymmetricKey(data: prk)
    }
}

// MARK: - QUIC Cipher Suite

/// QUIC cipher suites for packet protection
public enum QUICCipherSuite: Sendable {
    /// AES-128-GCM with SHA-256 (TLS_AES_128_GCM_SHA256)
    case aes128GcmSha256

    /// ChaCha20-Poly1305 with SHA-256 (TLS_CHACHA20_POLY1305_SHA256)
    case chacha20Poly1305Sha256

    /// Key length in bytes
    public var keyLength: Int {
        switch self {
        case .aes128GcmSha256:
            return 16
        case .chacha20Poly1305Sha256:
            return 32
        }
    }

    /// IV length in bytes (always 12 for QUIC)
    public var ivLength: Int {
        return 12
    }

    /// Header protection key length in bytes
    public var hpKeyLength: Int {
        switch self {
        case .aes128GcmSha256:
            return 16
        case .chacha20Poly1305Sha256:
            return 32
        }
    }
}

// MARK: - Key Material

/// Cryptographic key material derived from a secret
public struct KeyMaterial: Sendable {
    /// The packet protection key
    public let key: SymmetricKey

    /// The packet protection IV
    public let iv: Data

    /// The header protection key
    public let hp: SymmetricKey

    /// The cipher suite used to derive this key material
    public let cipherSuite: QUICCipherSuite

    /// Derives key material from a secret using AES-128-GCM (default)
    /// - Parameter secret: The secret to derive from
    /// - Returns: The derived key material
    public static func derive(from secret: SymmetricKey) throws -> KeyMaterial {
        return try derive(from: secret, cipherSuite: .aes128GcmSha256)
    }

    /// Derives key material from a secret using the specified cipher suite
    /// - Parameters:
    ///   - secret: The secret to derive from
    ///   - cipherSuite: The cipher suite to use
    /// - Returns: The derived key material
    ///
    /// RFC 9001 Section 5.1 specifies QUIC packet protection keys:
    /// - quic key = HKDF-Expand-Label(Secret, "quic key", "", key_len)
    /// - quic iv = HKDF-Expand-Label(Secret, "quic iv", "", 12)
    /// - quic hp = HKDF-Expand-Label(Secret, "quic hp", "", key_len)
    ///
    /// The HkdfLabel uses "tls13 " prefix per RFC 8446, so final labels are:
    /// "tls13 quic key", "tls13 quic iv", "tls13 quic hp"
    public static func derive(
        from secret: SymmetricKey,
        cipherSuite: QUICCipherSuite
    ) throws -> KeyMaterial {
        // Key lengths depend on cipher suite
        let keyLength = cipherSuite.keyLength
        let ivLength = cipherSuite.ivLength
        let hpLength = cipherSuite.hpKeyLength

        // Labels per RFC 9001 Section 5.1 - "tls13 " prefix is added by hkdfExpandLabel
        let key = try hkdfExpandLabel(
            secret: secret,
            label: "quic key",
            context: Data(),
            length: keyLength
        )

        let iv = try hkdfExpandLabel(
            secret: secret,
            label: "quic iv",
            context: Data(),
            length: ivLength
        )

        let hp = try hkdfExpandLabel(
            secret: secret,
            label: "quic hp",
            context: Data(),
            length: hpLength
        )

        return KeyMaterial(
            key: SymmetricKey(data: key),
            iv: iv,
            hp: SymmetricKey(data: hp),
            cipherSuite: cipherSuite
        )
    }

    /// Creates opener and sealer for this key material
    /// - Returns: Tuple of (opener, sealer)
    public func createCrypto() throws -> (opener: any PacketOpener, sealer: any PacketSealer) {
        switch cipherSuite {
        case .aes128GcmSha256:
            let opener = try AES128GCMOpener(keyMaterial: self)
            let sealer = try AES128GCMSealer(keyMaterial: self)
            return (opener, sealer)
        case .chacha20Poly1305Sha256:
            let opener = try ChaCha20Poly1305Opener(keyMaterial: self)
            let sealer = try ChaCha20Poly1305Sealer(keyMaterial: self)
            return (opener, sealer)
        }
    }
}

// MARK: - HKDF-Expand-Label

/// HKDF-Expand-Label as defined in TLS 1.3 (RFC 8446 Section 7.1)
///
/// HKDF-Expand-Label(Secret, Label, Context, Length) =
///     HKDF-Expand(Secret, HkdfLabel, Length)
///
/// Where HkdfLabel is:
///     struct {
///         uint16 length = Length;
///         opaque label<7..255> = prefix + Label;
///         opaque context<0..255> = Context;
///     } HkdfLabel;
///
/// For TLS 1.3, prefix is "tls13 " (RFC 8446 Section 7.1)
/// For QUIC packet keys, prefix is "quic " (RFC 9001 Section 5.1 - but labels are passed complete)
/// Pre-computed HKDF label structures for QUIC key derivation
///
/// QUIC uses fixed labels with empty context, so we can pre-compute the entire
/// HkdfLabel structure (length + label + context) to avoid runtime allocation.
///
/// HkdfLabel format (RFC 8446 Section 7.1):
/// - uint16 length
/// - opaque label<7..255> = len(1) + "tls13 " + label
/// - opaque context<0..255> = len(1) + context (empty for QUIC)
private enum HKDFLabels {
    // "tls13 " prefix + label (used for slow path)
    static let clientIn = Data("tls13 client in".utf8)
    static let serverIn = Data("tls13 server in".utf8)
    static let quicKey = Data("tls13 quic key".utf8)
    static let quicIV = Data("tls13 quic iv".utf8)
    static let quicHP = Data("tls13 quic hp".utf8)
    static let quicKU = Data("tls13 quic ku".utf8)

    // Pre-computed complete HkdfLabel structures for QUIC key derivation
    // Format: [length_hi, length_lo, label_len, label_bytes..., context_len(0)]

    /// "client in" with output length 32 (initial secret derivation)
    static let hkdfLabelClientIn32: Data = {
        var data = Data(capacity: 20)
        data.append(0x00); data.append(0x20)  // length = 32
        data.append(UInt8(clientIn.count))    // label length = 15
        data.append(clientIn)
        data.append(0x00)                     // context length = 0
        return data
    }()

    /// "server in" with output length 32 (initial secret derivation)
    static let hkdfLabelServerIn32: Data = {
        var data = Data(capacity: 20)
        data.append(0x00); data.append(0x20)  // length = 32
        data.append(UInt8(serverIn.count))    // label length = 15
        data.append(serverIn)
        data.append(0x00)                     // context length = 0
        return data
    }()

    /// "quic key" with output length 16 (AES-128-GCM key)
    static let hkdfLabelQuicKey16: Data = {
        var data = Data(capacity: 19)
        data.append(0x00); data.append(0x10)  // length = 16
        data.append(UInt8(quicKey.count))     // label length = 14
        data.append(quicKey)
        data.append(0x00)                     // context length = 0
        return data
    }()

    /// "quic iv" with output length 12
    static let hkdfLabelQuicIV12: Data = {
        var data = Data(capacity: 18)
        data.append(0x00); data.append(0x0C)  // length = 12
        data.append(UInt8(quicIV.count))      // label length = 13
        data.append(quicIV)
        data.append(0x00)                     // context length = 0
        return data
    }()

    /// "quic hp" with output length 16 (header protection key)
    static let hkdfLabelQuicHP16: Data = {
        var data = Data(capacity: 18)
        data.append(0x00); data.append(0x10)  // length = 16
        data.append(UInt8(quicHP.count))      // label length = 13
        data.append(quicHP)
        data.append(0x00)                     // context length = 0
        return data
    }()

    /// "quic ku" with output length 32 (key update secret)
    static let hkdfLabelQuicKU32: Data = {
        var data = Data(capacity: 18)
        data.append(0x00); data.append(0x20)  // length = 32
        data.append(UInt8(quicKU.count))      // label length = 13
        data.append(quicKU)
        data.append(0x00)                     // context length = 0
        return data
    }()

    /// Returns pre-computed HkdfLabel if available, otherwise nil
    @inline(__always)
    static func precomputedHkdfLabel(label: String, length: Int, context: Data) -> Data? {
        // Only use pre-computed labels for empty context
        guard context.isEmpty else { return nil }

        switch (label, length) {
        case ("client in", 32): return hkdfLabelClientIn32
        case ("server in", 32): return hkdfLabelServerIn32
        case ("quic key", 16): return hkdfLabelQuicKey16
        case ("quic iv", 12): return hkdfLabelQuicIV12
        case ("quic hp", 16): return hkdfLabelQuicHP16
        case ("quic ku", 32): return hkdfLabelQuicKU32
        default: return nil
        }
    }

    /// Returns cached label bytes if available, otherwise computes them
    @inline(__always)
    static func labelBytes(for label: String, prefix: String) -> Data {
        // Fast path for common labels
        if prefix == "tls13 " {
            switch label {
            case "client in": return clientIn
            case "server in": return serverIn
            case "quic key": return quicKey
            case "quic iv": return quicIV
            case "quic hp": return quicHP
            default: break
            }
        }
        // Slow path for uncommon labels
        return Data((prefix + label).utf8)
    }
}

func hkdfExpandLabel(
    secret: SymmetricKey,
    label: String,
    context: Data,
    length: Int,
    labelPrefix: String = "tls13 "
) throws -> Data {
    // Fast path: use pre-computed HkdfLabel for common QUIC operations
    if labelPrefix == "tls13 ",
       let precomputed = HKDFLabels.precomputedHkdfLabel(label: label, length: length, context: context) {
        let output = HKDF<SHA256>.expand(
            pseudoRandomKey: secret,
            info: precomputed,
            outputByteCount: length
        )
        return output.withUnsafeBytes { Data($0) }
    }

    // Slow path: construct HkdfLabel dynamically
    let labelBytes = HKDFLabels.labelBytes(for: label, prefix: labelPrefix)

    // Pre-allocate hkdfLabel with exact capacity: 2 + 1 + labelBytes.count + 1 + context.count
    var hkdfLabel = Data(capacity: 4 + labelBytes.count + context.count)

    // uint16 length
    hkdfLabel.append(UInt8(length >> 8))
    hkdfLabel.append(UInt8(length & 0xFF))

    // opaque label<7..255>
    hkdfLabel.append(UInt8(labelBytes.count))
    hkdfLabel.append(labelBytes)

    // opaque context<0..255>
    hkdfLabel.append(UInt8(context.count))
    hkdfLabel.append(context)

    // HKDF-Expand
    let output = HKDF<SHA256>.expand(
        pseudoRandomKey: secret,
        info: hkdfLabel,
        outputByteCount: length
    )

    return output.withUnsafeBytes { Data($0) }
}
