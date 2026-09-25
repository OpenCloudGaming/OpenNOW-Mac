/// TLS 1.3 Pre-Shared Key Extension (RFC 8446 Section 4.2.11)
///
/// The "pre_shared_key" extension is used to negotiate the identity of the
/// pre-shared key to be used with a given handshake in association with
/// PSK key establishment.
///
/// ClientHello:
/// ```
/// struct {
///     opaque identity<1..2^16-1>;
///     uint32 obfuscated_ticket_age;
/// } PskIdentity;
///
/// opaque PskBinderEntry<32..255>;
///
/// struct {
///     PskIdentity identities<7..2^16-1>;
///     PskBinderEntry binders<33..2^16-1>;
/// } OfferedPsks;
///
/// struct {
///     select (Handshake.msg_type) {
///         case client_hello: OfferedPsks;
///         case server_hello: uint16 selected_identity;
///     };
/// } PreSharedKeyExtension;
/// ```

import Foundation
import Crypto

// MARK: - PSK Identity

/// A single PSK identity offered by the client
public struct PskIdentity: Sendable, Equatable {
    /// The PSK identity (ticket for resumption, or external PSK label)
    public let identity: Data

    /// Obfuscated ticket age in milliseconds
    /// For resumption: (time since ticket) + ticket_age_add
    /// For external PSK: 0
    public let obfuscatedTicketAge: UInt32

    public init(identity: Data, obfuscatedTicketAge: UInt32) {
        self.identity = identity
        self.obfuscatedTicketAge = obfuscatedTicketAge
    }

    /// Create from a session ticket
    public init(ticket: SessionTicketData, at now: Date = Date()) {
        self.identity = ticket.ticket
        self.obfuscatedTicketAge = ticket.obfuscatedAge(at: now)
    }

    // MARK: - Encoding/Decoding

    public func encode() -> Data {
        var writer = TLSWriter(capacity: identity.count + 6)
        writer.writeVector16(identity)
        writer.writeUInt32(obfuscatedTicketAge)
        return writer.finish()
    }

    public static func decode(from reader: inout TLSReader) throws -> PskIdentity {
        let identity = try reader.readVector16()
        let obfuscatedAge = try reader.readUInt32()
        return PskIdentity(identity: identity, obfuscatedTicketAge: obfuscatedAge)
    }
}

// MARK: - Offered PSKs (ClientHello)

/// PSKs offered in ClientHello pre_shared_key extension
public struct OfferedPsks: Sendable {
    /// List of PSK identities offered
    public let identities: [PskIdentity]

    /// Corresponding binders (HMAC over transcript)
    /// Must have same count as identities
    public var binders: [Data]

    public init(identities: [PskIdentity], binders: [Data] = []) {
        self.identities = identities
        self.binders = binders
    }

    // MARK: - Encoding

    /// Encode the offered PSKs
    public func encode() -> Data {
        var writer = TLSWriter(capacity: 256)

        // identities<7..2^16-1>
        var identitiesData = Data()
        for identity in identities {
            identitiesData.append(identity.encode())
        }
        writer.writeVector16(identitiesData)

        // binders<33..2^16-1>
        var bindersData = Data()
        for binder in binders {
            // Each binder is a PskBinderEntry<32..255>
            bindersData.append(UInt8(binder.count))
            bindersData.append(binder)
        }
        writer.writeVector16(bindersData)

        return writer.finish()
    }

    /// Encoded identities part (for binder computation)
    /// The binders will be computed separately
    public var encodedIdentities: Data {
        var writer = TLSWriter(capacity: 256)

        // identities<7..2^16-1>
        var identitiesData = Data()
        for identity in identities {
            identitiesData.append(identity.encode())
        }
        writer.writeVector16(identitiesData)

        return writer.finish()
    }

    /// Size of binders section for truncation
    public var bindersSize: Int {
        // 2 bytes for binders vector length
        var size = 2
        for binder in binders {
            // 1 byte for binder length + binder data
            size += 1 + binder.count
        }
        return size
    }

    // MARK: - Decoding

    public static func decode(from data: Data) throws -> OfferedPsks {
        var reader = TLSReader(data: data)

        // identities
        let identitiesData = try reader.readVector16()
        var identitiesReader = TLSReader(data: identitiesData)
        var identities: [PskIdentity] = []
        while identitiesReader.hasMore {
            identities.append(try PskIdentity.decode(from: &identitiesReader))
        }

        guard !identities.isEmpty else {
            throw TLSDecodeError.invalidFormat("PreSharedKey: no identities")
        }

        // binders
        let bindersData = try reader.readVector16()
        var bindersReader = TLSReader(data: bindersData)
        var binders: [Data] = []
        while bindersReader.hasMore {
            let binder = try bindersReader.readVector8()
            binders.append(binder)
        }

        guard binders.count == identities.count else {
            throw TLSDecodeError.invalidFormat(
                "PreSharedKey: identities count (\(identities.count)) != binders count (\(binders.count))"
            )
        }

        return OfferedPsks(identities: identities, binders: binders)
    }
}

// MARK: - Selected PSK (ServerHello)

/// PSK selected by server in ServerHello
public struct SelectedPsk: Sendable {
    /// Index of the selected PSK identity (0-based)
    public let selectedIdentity: UInt16

    public init(selectedIdentity: UInt16) {
        self.selectedIdentity = selectedIdentity
    }

    public func encode() -> Data {
        var writer = TLSWriter(capacity: 2)
        writer.writeUInt16(selectedIdentity)
        return writer.finish()
    }

    public static func decode(from data: Data) throws -> SelectedPsk {
        var reader = TLSReader(data: data)
        let selectedIdentity = try reader.readUInt16()
        return SelectedPsk(selectedIdentity: selectedIdentity)
    }
}

// MARK: - PreSharedKey Extension

/// Pre-shared key extension (for both ClientHello and ServerHello)
public enum PreSharedKeyExtension: Sendable, TLSExtensionValue {
    public static var extensionType: TLSExtensionType { .preSharedKey }

    /// ClientHello variant with offered PSKs
    case clientHello(OfferedPsks)

    /// ServerHello variant with selected PSK index
    case serverHello(SelectedPsk)

    // MARK: - Encoding

    public func encode() -> Data {
        switch self {
        case .clientHello(let offered):
            return offered.encode()
        case .serverHello(let selected):
            return selected.encode()
        }
    }

    // MARK: - Decoding

    /// Decode ClientHello variant
    public static func decodeClientHello(from data: Data) throws -> PreSharedKeyExtension {
        return .clientHello(try OfferedPsks.decode(from: data))
    }

    /// Decode ServerHello variant
    public static func decodeServerHello(from data: Data) throws -> PreSharedKeyExtension {
        return .serverHello(try SelectedPsk.decode(from: data))
    }
}

// MARK: - PSK Binder Computation

/// Helper for computing PSK binders
public struct PSKBinderHelper: Sendable {
    /// The cipher suite (determines hash function)
    public let cipherSuite: CipherSuite

    public init(cipherSuite: CipherSuite = .tls_aes_128_gcm_sha256) {
        self.cipherSuite = cipherSuite
    }

    /// Derive the binder key from early secret
    /// - Parameters:
    ///   - earlySecret: The early secret derived from PSK
    ///   - isResumption: true for resumption PSK, false for external PSK
    /// - Returns: The binder key
    public func binderKey(
        from earlySecret: Data,
        isResumption: Bool
    ) -> Data {
        let label = isResumption ? "res binder" : "ext binder"
        let emptyHash = emptyTranscriptHash()

        return deriveSecret(
            secret: earlySecret,
            label: label,
            transcriptHash: emptyHash
        )
    }

    /// Compute the binder value
    /// - Parameters:
    ///   - key: The binder key
    ///   - transcriptHash: Hash of ClientHello up to (but not including) binders
    /// - Returns: The binder value
    public func binder(
        forKey key: Data,
        transcriptHash: Data
    ) -> Data {
        // finished_key = HKDF-Expand-Label(binder_key, "finished", "", Hash.length)
        let finishedKey = hkdfExpandLabel(
            secret: key,
            label: "finished",
            context: Data(),
            length: hashLength
        )

        // binder = HMAC(finished_key, Transcript-Hash(Truncate(ClientHello)))
        return hmac(key: finishedKey, data: transcriptHash)
    }

    /// Verify a binder
    public func isValidBinder(
        forKey key: Data,
        transcriptHash: Data,
        expected: Data
    ) -> Bool {
        let computed = binder(forKey: key, transcriptHash: transcriptHash)
        return constantTimeCompare(computed, expected)
    }

    // MARK: - Private Helpers

    private var hashLength: Int {
        cipherSuite.hashLength
    }

    private func emptyTranscriptHash() -> Data {
        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            return Data(Crypto.SHA384.hash(data: Data()))
        default:
            return Data(Crypto.SHA256.hash(data: Data()))
        }
    }

    private func deriveSecret(secret: Data, label: String, transcriptHash: Data) -> Data {
        hkdfExpandLabel(secret: secret, label: label, context: transcriptHash, length: hashLength)
    }

    private func hkdfExpandLabel(secret: Data, label: String, context: Data, length: Int) -> Data {
        let fullLabel = "tls13 " + label
        let labelBytes = Data(fullLabel.utf8)

        var hkdfLabel = Data()
        hkdfLabel.append(UInt8(length >> 8))
        hkdfLabel.append(UInt8(length & 0xFF))
        hkdfLabel.append(UInt8(labelBytes.count))
        hkdfLabel.append(labelBytes)
        hkdfLabel.append(UInt8(context.count))
        hkdfLabel.append(context)

        let key = SymmetricKey(data: secret)

        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            let output = HKDF<SHA384>.expand(
                pseudoRandomKey: key,
                info: hkdfLabel,
                outputByteCount: length
            )
            return output.withUnsafeBytes { Data($0) }
        default:
            let output = HKDF<SHA256>.expand(
                pseudoRandomKey: key,
                info: hkdfLabel,
                outputByteCount: length
            )
            return output.withUnsafeBytes { Data($0) }
        }
    }

    private func hmac(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)

        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            let mac = HMAC<SHA384>.authenticationCode(for: data, using: symmetricKey)
            return Data(mac)
        default:
            let mac = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
            return Data(mac)
        }
    }

    private func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return result == 0
    }
}
