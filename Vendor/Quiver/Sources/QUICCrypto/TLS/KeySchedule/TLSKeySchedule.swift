/// TLS 1.3 Key Schedule (RFC 8446 Section 7.1)
///
/// The TLS 1.3 key schedule derives secrets from the handshake:
/// ```
///             0
///             |
///             v
///   PSK ->  HKDF-Extract = Early Secret
///             |
///             +-----> Derive-Secret(., "ext binder" | "res binder", "")
///             |                     = binder_key
///             |
///             +-----> Derive-Secret(., "c e traffic", ClientHello)
///             |                     = client_early_traffic_secret
///             |
///             +-----> Derive-Secret(., "e exp master", ClientHello)
///             |                     = early_exporter_master_secret
///             |
///             v
///       Derive-Secret(., "derived", "")
///             |
///             v
///  (EC)DHE -> HKDF-Extract = Handshake Secret
///             |
///             +-----> Derive-Secret(., "c hs traffic", CH...SH)
///             |                     = client_handshake_traffic_secret
///             |
///             +-----> Derive-Secret(., "s hs traffic", CH...SH)
///             |                     = server_handshake_traffic_secret
///             |
///             v
///       Derive-Secret(., "derived", "")
///             |
///             v
///     0 -> HKDF-Extract = Master Secret
///             |
///             +-----> Derive-Secret(., "c ap traffic", CH...SF)
///             |                     = client_application_traffic_secret_0
///             |
///             +-----> Derive-Secret(., "s ap traffic", CH...SF)
///             |                     = server_application_traffic_secret_0
///             |
///             +-----> Derive-Secret(., "exp master", CH...SF)
///             |                     = exporter_master_secret
///             |
///             +-----> Derive-Secret(., "res master", CH...CF)
///                                   = resumption_master_secret
/// ```

import Foundation
import Crypto

// MARK: - Pre-computed HkdfLabel Cache

/// Pre-computed HKDF label structures for TLS 1.3 key derivation
///
/// Similar to QUIC labels, TLS uses fixed labels with empty context in many cases.
/// Pre-computing the full HkdfLabel structure avoids runtime allocation.
private enum TLSHKDFLabels {
    // Label bytes (used for slow path with non-empty context)
    static let derived = Data("tls13 derived".utf8)
    static let finished = Data("tls13 finished".utf8)
    static let trafficUpd = Data("tls13 traffic upd".utf8)
    static let key = Data("tls13 key".utf8)
    static let iv = Data("tls13 iv".utf8)

    // Pre-computed complete HkdfLabel structures for empty context

    // "derived" with length 32 (SHA-256)
    static let hkdfLabelDerived32: Data = buildLabel(derived, length: 32)
    // "derived" with length 48 (SHA-384)
    static let hkdfLabelDerived48: Data = buildLabel(derived, length: 48)

    // "finished" with length 32 (SHA-256)
    static let hkdfLabelFinished32: Data = buildLabel(finished, length: 32)
    // "finished" with length 48 (SHA-384)
    static let hkdfLabelFinished48: Data = buildLabel(finished, length: 48)

    // "traffic upd" with length 32 (SHA-256)
    static let hkdfLabelTrafficUpd32: Data = buildLabel(trafficUpd, length: 32)
    // "traffic upd" with length 48 (SHA-384)
    static let hkdfLabelTrafficUpd48: Data = buildLabel(trafficUpd, length: 48)

    // "key" with length 16 (AES-128-GCM)
    static let hkdfLabelKey16: Data = buildLabel(key, length: 16)
    // "key" with length 32 (AES-256-GCM / ChaCha20)
    static let hkdfLabelKey32: Data = buildLabel(key, length: 32)

    // "iv" with length 12
    static let hkdfLabelIV12: Data = buildLabel(iv, length: 12)

    private static func buildLabel(_ labelBytes: Data, length: Int) -> Data {
        var data = Data(capacity: 4 + labelBytes.count)
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(UInt8(labelBytes.count))
        data.append(labelBytes)
        data.append(0x00)  // context length = 0
        return data
    }

    /// Returns pre-computed HkdfLabel for empty context labels
    @inline(__always)
    static func precomputed(label: String, length: Int) -> Data? {
        switch (label, length) {
        case ("derived", 32): return hkdfLabelDerived32
        case ("derived", 48): return hkdfLabelDerived48
        case ("finished", 32): return hkdfLabelFinished32
        case ("finished", 48): return hkdfLabelFinished48
        case ("traffic upd", 32): return hkdfLabelTrafficUpd32
        case ("traffic upd", 48): return hkdfLabelTrafficUpd48
        case ("key", 16): return hkdfLabelKey16
        case ("key", 32): return hkdfLabelKey32
        case ("iv", 12): return hkdfLabelIV12
        default: return nil
        }
    }
}

// MARK: - TLS Key Schedule

/// Manages TLS 1.3 key derivation
public struct TLSKeySchedule: Sendable {

    /// Current state in the key schedule
    private var state: KeyScheduleState

    /// The negotiated cipher suite
    public let cipherSuite: CipherSuite

    /// Hash length (32 for SHA-256, 48 for SHA-384)
    public let hashLength: Int

    private enum KeyScheduleState: Sendable {
        case initial
        case earlySecret(SymmetricKey)
        case handshakeSecret(SymmetricKey)
        case masterSecret(SymmetricKey)
    }

    // MARK: - Initialization

    /// Creates a new key schedule
    /// - Parameter cipherSuite: The negotiated cipher suite
    public init(cipherSuite: CipherSuite = .tls_aes_128_gcm_sha256) {
        self.state = .initial
        self.cipherSuite = cipherSuite
        self.hashLength = cipherSuite.hashLength
    }

    // MARK: - Early Secret

    /// Derive early secret from PSK (or use 0 for non-PSK mode)
    /// - Parameter psk: Pre-shared key, or nil for non-PSK mode
    public mutating func deriveEarlySecret(psk: SymmetricKey? = nil) {
        let ikm = psk ?? SymmetricKey(data: Data(repeating: 0, count: hashLength))
        let salt = Data(repeating: 0, count: hashLength)

        let earlySecret = hkdfExtract(salt: salt, ikm: ikm)
        state = .earlySecret(earlySecret)
    }

    // MARK: - Handshake Secret

    /// Derive handshake secrets from (EC)DHE shared secret
    /// - Parameters:
    ///   - sharedSecret: The (EC)DHE shared secret
    ///   - transcriptHash: Hash of ClientHello...ServerHello
    /// - Returns: (client_handshake_traffic_secret, server_handshake_traffic_secret)
    public mutating func deriveHandshakeSecrets(
        sharedSecret: SharedSecret,
        transcriptHash: Data
    ) throws -> (client: SymmetricKey, server: SymmetricKey) {
        // Ensure we have early secret
        switch state {
        case .initial:
            deriveEarlySecret(psk: nil)
        case .earlySecret:
            break
        default:
            throw TLSKeyScheduleError.invalidState("Already past early secret")
        }

        guard case .earlySecret(let earlySecret) = state else {
            throw TLSKeyScheduleError.invalidState("Expected early secret state")
        }

        // Derive-Secret(early_secret, "derived", "")
        // RFC 8446: Transcript-Hash("") is the hash of empty string, not zeros
        let derivedSecret = deriveSecret(
            secret: earlySecret,
            label: "derived",
            transcriptHash: emptyTranscriptHash()
        )

        // HKDF-Extract(derived_secret, shared_secret)
        let handshakeSecret = hkdfExtract(
            salt: derivedSecret,
            ikm: SymmetricKey(data: sharedSecret.rawRepresentation)
        )

        state = .handshakeSecret(handshakeSecret)

        // Derive client and server handshake traffic secrets
        let clientSecret = deriveSecret(
            secret: handshakeSecret,
            label: "c hs traffic",
            transcriptHash: transcriptHash
        )

        let serverSecret = deriveSecret(
            secret: handshakeSecret,
            label: "s hs traffic",
            transcriptHash: transcriptHash
        )

        return (
            client: SymmetricKey(data: clientSecret),
            server: SymmetricKey(data: serverSecret)
        )
    }

    // MARK: - Application Secret

    /// Derive application (1-RTT) secrets
    /// - Parameter transcriptHash: Hash of ClientHello...server Finished
    /// - Returns: (client_application_traffic_secret_0, server_application_traffic_secret_0)
    public mutating func deriveApplicationSecrets(
        transcriptHash: Data
    ) throws -> (client: SymmetricKey, server: SymmetricKey) {
        guard case .handshakeSecret(let handshakeSecret) = state else {
            throw TLSKeyScheduleError.invalidState("Expected handshake secret state")
        }

        // Derive-Secret(handshake_secret, "derived", "")
        // RFC 8446: Transcript-Hash("") is the hash of empty string, not zeros
        let derivedSecret = deriveSecret(
            secret: handshakeSecret,
            label: "derived",
            transcriptHash: emptyTranscriptHash()
        )

        // HKDF-Extract(derived_secret, 0)
        let masterSecret = hkdfExtract(
            salt: derivedSecret,
            ikm: SymmetricKey(data: Data(repeating: 0, count: hashLength))
        )

        state = .masterSecret(masterSecret)

        // Derive client and server application traffic secrets
        let clientSecret = deriveSecret(
            secret: masterSecret,
            label: "c ap traffic",
            transcriptHash: transcriptHash
        )

        let serverSecret = deriveSecret(
            secret: masterSecret,
            label: "s ap traffic",
            transcriptHash: transcriptHash
        )

        return (
            client: SymmetricKey(data: clientSecret),
            server: SymmetricKey(data: serverSecret)
        )
    }

    // MARK: - Key Update

    /// Next application traffic secret (for key update)
    /// - Parameter currentSecret: The current application traffic secret
    /// - Returns: The next application traffic secret
    public func nextApplicationSecret(
        from currentSecret: SymmetricKey
    ) -> SymmetricKey {
        // application_traffic_secret_N+1 =
        //     HKDF-Expand-Label(application_traffic_secret_N, "traffic upd", "", Hash.length)
        let nextSecretData = hkdfExpandLabel(
            secret: currentSecret,
            label: "traffic upd",
            context: Data(),
            length: hashLength
        )
        return SymmetricKey(data: nextSecretData)
    }

    // MARK: - Finished Key

    /// The finished key derived from a base key
    /// - Parameter baseKey: The handshake traffic secret
    /// - Returns: The finished key
    public func finishedKey(from baseKey: SymmetricKey) -> SymmetricKey {
        // finished_key = HKDF-Expand-Label(BaseKey, "finished", "", Hash.length)
        let finishedKeyData = hkdfExpandLabel(
            secret: baseKey,
            label: "finished",
            context: Data(),
            length: hashLength
        )
        return SymmetricKey(data: finishedKeyData)
    }

    /// The finished verify_data
    /// - Parameters:
    ///   - key: The finished key
    ///   - transcriptHash: The transcript hash up to the Finished message
    /// - Returns: The verify_data for the Finished message
    public func finishedVerifyData(
        forKey key: SymmetricKey,
        transcriptHash: Data
    ) -> Data {
        // verify_data = HMAC(finished_key, Transcript-Hash)
        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            let hmac = HMAC<SHA384>.authenticationCode(
                for: transcriptHash,
                using: key
            )
            return Data(hmac)
        default:
            let hmac = HMAC<SHA256>.authenticationCode(
                for: transcriptHash,
                using: key
            )
            return Data(hmac)
        }
    }

    // MARK: - Exporter Master Secret

    /// Derive the exporter master secret
    /// - Parameter transcriptHash: Hash of ClientHello...server Finished
    /// - Returns: The exporter master secret
    public func deriveExporterMasterSecret(transcriptHash: Data) throws -> SymmetricKey {
        guard case .masterSecret(let masterSecret) = state else {
            throw TLSKeyScheduleError.invalidState("Expected master secret state")
        }

        let exporterSecret = deriveSecret(
            secret: masterSecret,
            label: "exp master",
            transcriptHash: transcriptHash
        )

        return SymmetricKey(data: exporterSecret)
    }

    // MARK: - Resumption Master Secret

    /// Derive the resumption master secret
    /// - Parameter transcriptHash: Hash of ClientHello...client Finished
    /// - Returns: The resumption master secret (for deriving PSKs)
    public func deriveResumptionMasterSecret(transcriptHash: Data) throws -> SymmetricKey {
        guard case .masterSecret(let masterSecret) = state else {
            throw TLSKeyScheduleError.invalidState("Expected master secret state")
        }

        let resumptionSecret = deriveSecret(
            secret: masterSecret,
            label: "res master",
            transcriptHash: transcriptHash
        )

        return SymmetricKey(data: resumptionSecret)
    }

    /// Derive a resumption PSK from the resumption master secret and ticket nonce
    /// - Parameters:
    ///   - resumptionMasterSecret: The resumption master secret
    ///   - ticketNonce: The ticket nonce from NewSessionTicket
    /// - Returns: The PSK for use in future connections
    public func deriveResumptionPSK(
        resumptionMasterSecret: SymmetricKey,
        ticketNonce: Data
    ) -> SymmetricKey {
        // PSK = HKDF-Expand-Label(resumption_master_secret, "resumption", ticket_nonce, Hash.length)
        let pskData = hkdfExpandLabel(
            secret: resumptionMasterSecret,
            label: "resumption",
            context: ticketNonce,
            length: hashLength
        )
        return SymmetricKey(data: pskData)
    }

    // MARK: - PSK/Early Secrets

    /// Derive the binder key from the early secret
    /// - Parameters:
    ///   - isResumption: true for resumption PSK (res binder), false for external PSK (ext binder)
    /// - Returns: The binder key for computing PSK binders
    public func deriveBinderKey(isResumption: Bool) throws -> SymmetricKey {
        guard case .earlySecret(let earlySecret) = state else {
            throw TLSKeyScheduleError.invalidState("Expected early secret state")
        }

        let label = isResumption ? "res binder" : "ext binder"
        let emptyHash = emptyTranscriptHash()

        let binderKeyData = deriveSecret(
            secret: earlySecret,
            label: label,
            transcriptHash: emptyHash
        )

        return SymmetricKey(data: binderKeyData)
    }

    /// Derive the client early traffic secret (for 0-RTT)
    /// - Parameter transcriptHash: Hash of ClientHello
    /// - Returns: The client early traffic secret
    public func deriveClientEarlyTrafficSecret(transcriptHash: Data) throws -> SymmetricKey {
        guard case .earlySecret(let earlySecret) = state else {
            throw TLSKeyScheduleError.invalidState("Expected early secret state")
        }

        let clientEarlySecretData = deriveSecret(
            secret: earlySecret,
            label: "c e traffic",
            transcriptHash: transcriptHash
        )

        return SymmetricKey(data: clientEarlySecretData)
    }

    /// Derive the early exporter master secret
    /// - Parameter transcriptHash: Hash of ClientHello
    /// - Returns: The early exporter master secret
    public func deriveEarlyExporterMasterSecret(transcriptHash: Data) throws -> SymmetricKey {
        guard case .earlySecret(let earlySecret) = state else {
            throw TLSKeyScheduleError.invalidState("Expected early secret state")
        }

        let earlyExporterSecretData = deriveSecret(
            secret: earlySecret,
            label: "e exp master",
            transcriptHash: transcriptHash
        )

        return SymmetricKey(data: earlyExporterSecretData)
    }

    /// The current early secret (for PSK-related computations)
    public func currentEarlySecret() throws -> SymmetricKey {
        guard case .earlySecret(let earlySecret) = state else {
            throw TLSKeyScheduleError.invalidState("Expected early secret state")
        }
        return earlySecret
    }

    /// Get the empty transcript hash for this cipher suite
    private func emptyTranscriptHash() -> Data {
        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            return Data(SHA384.hash(data: Data()))
        default:
            return Data(SHA256.hash(data: Data()))
        }
    }

    // MARK: - Private Helpers

    /// HKDF-Extract
    private func hkdfExtract(salt: Data, ikm: SymmetricKey) -> SymmetricKey {
        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            let prk = HKDF<SHA384>.extract(
                inputKeyMaterial: ikm,
                salt: salt
            )
            return SymmetricKey(data: prk)
        default:
            let prk = HKDF<SHA256>.extract(
                inputKeyMaterial: ikm,
                salt: salt
            )
            return SymmetricKey(data: prk)
        }
    }

    /// Derive-Secret
    private func deriveSecret(
        secret: SymmetricKey,
        label: String,
        transcriptHash: Data
    ) -> Data {
        hkdfExpandLabel(
            secret: secret,
            label: label,
            context: transcriptHash,
            length: hashLength
        )
    }

    /// HKDF-Expand-Label
    private func hkdfExpandLabel(
        secret: SymmetricKey,
        label: String,
        context: Data,
        length: Int
    ) -> Data {
        // Fast path: use pre-computed HkdfLabel for empty context
        if context.isEmpty, let precomputed = TLSHKDFLabels.precomputed(label: label, length: length) {
            switch cipherSuite {
            case .tls_aes_256_gcm_sha384:
                let output = HKDF<SHA384>.expand(
                    pseudoRandomKey: secret,
                    info: precomputed,
                    outputByteCount: length
                )
                return output.withUnsafeBytes { Data($0) }
            default:
                let output = HKDF<SHA256>.expand(
                    pseudoRandomKey: secret,
                    info: precomputed,
                    outputByteCount: length
                )
                return output.withUnsafeBytes { Data($0) }
            }
        }

        // Slow path: construct HkdfLabel dynamically
        let fullLabel = "tls13 " + label
        let labelBytes = Data(fullLabel.utf8)

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

        // HKDF-Expand based on cipher suite
        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            let output = HKDF<SHA384>.expand(
                pseudoRandomKey: secret,
                info: hkdfLabel,
                outputByteCount: length
            )
            return output.withUnsafeBytes { Data($0) }
        default:
            let output = HKDF<SHA256>.expand(
                pseudoRandomKey: secret,
                info: hkdfLabel,
                outputByteCount: length
            )
            return output.withUnsafeBytes { Data($0) }
        }
    }
}

// MARK: - Errors

/// Errors from TLS key schedule operations
public enum TLSKeyScheduleError: Error, Sendable {
    case invalidState(String)
    case keyDerivationFailed(String)
}

// MARK: - Traffic Keys

/// Traffic keys derived from a traffic secret
public struct TrafficKeys: Sendable {
    /// The encryption key
    public let key: SymmetricKey

    /// The IV
    public let iv: Data

    /// Derives traffic keys from a traffic secret
    /// - Parameters:
    ///   - secret: The traffic secret
    ///   - cipherSuite: The negotiated cipher suite (for hash function selection)
    ///   - keyLength: Key length in bytes (16 for AES-128, 32 for AES-256)
    ///   - ivLength: IV length in bytes (always 12 for TLS 1.3)
    public init(
        secret: SymmetricKey,
        cipherSuite: CipherSuite = .tls_aes_128_gcm_sha256,
        keyLength: Int = 16,
        ivLength: Int = 12
    ) {
        // key = HKDF-Expand-Label(Secret, "key", "", key_length)
        // iv = HKDF-Expand-Label(Secret, "iv", "", iv_length)

        let keyData = Self.hkdfExpandLabel(
            secret: secret,
            label: "key",
            length: keyLength,
            cipherSuite: cipherSuite
        )
        let ivData = Self.hkdfExpandLabel(
            secret: secret,
            label: "iv",
            length: ivLength,
            cipherSuite: cipherSuite
        )

        self.key = SymmetricKey(data: keyData)
        self.iv = ivData
    }

    private static func hkdfExpandLabel(
        secret: SymmetricKey,
        label: String,
        length: Int,
        cipherSuite: CipherSuite
    ) -> Data {
        // Fast path: use pre-computed HkdfLabel for "key" and "iv"
        if let precomputed = TLSHKDFLabels.precomputed(label: label, length: length) {
            switch cipherSuite {
            case .tls_aes_256_gcm_sha384:
                let output = HKDF<SHA384>.expand(
                    pseudoRandomKey: secret,
                    info: precomputed,
                    outputByteCount: length
                )
                return output.withUnsafeBytes { Data($0) }
            default:
                let output = HKDF<SHA256>.expand(
                    pseudoRandomKey: secret,
                    info: precomputed,
                    outputByteCount: length
                )
                return output.withUnsafeBytes { Data($0) }
            }
        }

        // Slow path: construct HkdfLabel dynamically
        let fullLabel = "tls13 " + label
        let labelBytes = Data(fullLabel.utf8)

        var hkdfLabel = Data(capacity: 4 + labelBytes.count)
        hkdfLabel.append(UInt8(length >> 8))
        hkdfLabel.append(UInt8(length & 0xFF))
        hkdfLabel.append(UInt8(labelBytes.count))
        hkdfLabel.append(labelBytes)
        hkdfLabel.append(0x00)  // Empty context

        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            let output = HKDF<SHA384>.expand(
                pseudoRandomKey: secret,
                info: hkdfLabel,
                outputByteCount: length
            )
            return output.withUnsafeBytes { Data($0) }
        default:
            let output = HKDF<SHA256>.expand(
                pseudoRandomKey: secret,
                info: hkdfLabel,
                outputByteCount: length
            )
            return output.withUnsafeBytes { Data($0) }
        }
    }
}
