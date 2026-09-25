/// QUIC AEAD (Authenticated Encryption with Associated Data)
///
/// QUIC uses AES-128-GCM or ChaCha20-Poly1305 for packet protection.
/// This implementation provides AES-128-GCM.

import Foundation
import Crypto
import QUICCore

// Platform-specific AES support for header protection
// - Apple platforms: CommonCrypto provides native AES-ECB
// - Linux/Other: _CryptoExtras provides AES-CBC (used with zero IV as ECB equivalent)
#if canImport(CommonCrypto)
import CommonCrypto
#elseif canImport(_CryptoExtras)
import _CryptoExtras
#else
#error("AES Header Protection requires CommonCrypto (Apple) or _CryptoExtras (Linux with swift-crypto)")
#endif

// MARK: - AES-128 Header Protection

/// AES-128 based header protection (RFC 9001 Section 5.4.3)
public struct AES128HeaderProtection: HeaderProtection, Sendable {
    private let key: SymmetricKey

    /// Creates AES-128 header protection with the given key
    /// - Parameter key: The header protection key (16 bytes)
    public init(key: SymmetricKey) {
        self.key = key
    }

    public func mask(sample: Data) throws -> Data {
        guard sample.count >= 16 else {
            throw CryptoError.insufficientSample(expected: 16, actual: sample.count)
        }
        return try aesECBEncrypt(key: key, block: sample.prefix(16))
    }
}

// MARK: - AES-128-GCM Opener

/// AES-128-GCM packet opener (decryption)
public struct AES128GCMOpener: PacketOpener, Sendable {
    private let key: SymmetricKey
    private let iv: Data
    private let headerProtection: AES128HeaderProtection

    /// AES-128-GCM requires 12-byte IV
    public static let ivLength = 12

    /// Creates an AES-128-GCM opener
    /// - Parameters:
    ///   - key: The packet protection key (16 bytes)
    ///   - iv: The packet protection IV (12 bytes)
    ///   - hp: The header protection key (16 bytes)
    /// - Throws: CryptoError.invalidIVLength if IV is not 12 bytes
    public init(key: SymmetricKey, iv: Data, hp: SymmetricKey) throws {
        guard iv.count == Self.ivLength else {
            throw CryptoError.invalidIVLength(expected: Self.ivLength, actual: iv.count)
        }
        self.key = key
        self.iv = iv
        self.headerProtection = AES128HeaderProtection(key: hp)
    }

    /// Creates an opener from key material
    /// - Throws: CryptoError.invalidIVLength if IV is not 12 bytes
    public init(keyMaterial: KeyMaterial) throws {
        try self.init(key: keyMaterial.key, iv: keyMaterial.iv, hp: keyMaterial.hp)
    }

    public func open(ciphertext: Data, packetNumber: UInt64, header: Data) throws -> Data {
        // Construct nonce: IV XOR packet number (inline, no heap allocation)
        let nonce = constructNonceInline(iv: iv, packetNumber: packetNumber)

        // Separate ciphertext and tag (last 16 bytes)
        guard ciphertext.count >= 16 else {
            throw QUICError.decryptionFailed
        }

        let encryptedData = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)

        // Decrypt using AES-GCM
        do {
            let sealedBox = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: encryptedData,
                tag: tag
            )

            let plaintext = try AES.GCM.open(sealedBox, using: key, authenticating: header)
            return plaintext
        } catch {
            // Convert CryptoKit errors to QUICError for consistent handling
            throw QUICError.decryptionFailed
        }
    }

    public func removeHeaderProtection(
        sample: Data,
        firstByte: UInt8,
        packetNumberBytes: Data
    ) throws -> (UInt8, Data) {
        // Generate mask using AES-ECB
        let mask = try headerProtection.mask(sample: sample)

        // For long header: mask lower 4 bits of first byte
        // For short header: mask lower 5 bits of first byte
        let isLongHeader = (firstByte & 0x80) != 0
        let firstByteMask: UInt8 = isLongHeader ? 0x0F : 0x1F

        let unprotectedFirstByte = firstByte ^ (mask[0] & firstByteMask)

        // Unmask packet number bytes
        // Use enumerated() to handle Data slices with non-zero startIndex
        var unprotectedPN = Data(capacity: packetNumberBytes.count)
        for (i, byte) in packetNumberBytes.enumerated() {
            unprotectedPN.append(byte ^ mask[i + 1])
        }

        return (unprotectedFirstByte, unprotectedPN)
    }
}

// MARK: - AES-128-GCM Sealer

/// AES-128-GCM packet sealer (encryption)
public struct AES128GCMSealer: PacketSealer, Sendable {
    private let key: SymmetricKey
    private let iv: Data
    private let headerProtection: AES128HeaderProtection

    /// AES-128-GCM requires 12-byte IV
    public static let ivLength = 12

    /// Creates an AES-128-GCM sealer
    /// - Parameters:
    ///   - key: The packet protection key (16 bytes)
    ///   - iv: The packet protection IV (12 bytes)
    ///   - hp: The header protection key (16 bytes)
    /// - Throws: CryptoError.invalidIVLength if IV is not 12 bytes
    public init(key: SymmetricKey, iv: Data, hp: SymmetricKey) throws {
        guard iv.count == Self.ivLength else {
            throw CryptoError.invalidIVLength(expected: Self.ivLength, actual: iv.count)
        }
        self.key = key
        self.iv = iv
        self.headerProtection = AES128HeaderProtection(key: hp)
    }

    /// Creates a sealer from key material
    /// - Throws: CryptoError.invalidIVLength if IV is not 12 bytes
    public init(keyMaterial: KeyMaterial) throws {
        try self.init(key: keyMaterial.key, iv: keyMaterial.iv, hp: keyMaterial.hp)
    }

    public func seal(plaintext: Data, packetNumber: UInt64, header: Data) throws -> Data {
        // Construct nonce: IV XOR packet number (inline, no heap allocation)
        let nonce = constructNonceInline(iv: iv, packetNumber: packetNumber)

        // Encrypt using AES-GCM
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: header
        )

        // Pre-allocate result: ciphertext + 16-byte tag
        var result = Data(capacity: sealedBox.ciphertext.count + sealedBox.tag.count)
        result.append(contentsOf: sealedBox.ciphertext)
        result.append(contentsOf: sealedBox.tag)
        return result
    }

    public func applyHeaderProtection(
        sample: Data,
        firstByte: UInt8,
        packetNumberBytes: Data
    ) throws -> (UInt8, Data) {
        // Generate mask using AES-ECB
        let mask = try headerProtection.mask(sample: sample)

        // For long header: mask lower 4 bits of first byte
        // For short header: mask lower 5 bits of first byte
        let isLongHeader = (firstByte & 0x80) != 0
        let firstByteMask: UInt8 = isLongHeader ? 0x0F : 0x1F

        let protectedFirstByte = firstByte ^ (mask[0] & firstByteMask)

        // Mask packet number bytes
        // Use enumerated() to handle Data slices with non-zero startIndex
        var protectedPN = Data(capacity: packetNumberBytes.count)
        for (i, byte) in packetNumberBytes.enumerated() {
            protectedPN.append(byte ^ mask[i + 1])
        }

        return (protectedFirstByte, protectedPN)
    }
}

// MARK: - Helper Functions

/// 12-byte inline nonce stored as a tuple — avoids heap allocation per packet.
private typealias Nonce12 = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

/// Constructs a nonce as a stack-allocated 12-byte tuple.
/// nonce = iv XOR (packet_number padded to 12 bytes, left-padded with zeros)
///
/// - Precondition: iv.count == 12 (validated at init time)
@inline(__always)
private func constructNonceTuple(iv: Data, packetNumber: UInt64) -> Nonce12 {
    // Read IV bytes directly (always 12 bytes, validated at init)
    return iv.withUnsafeBytes { buf in
        let p = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
        return (
            p[0],
            p[1],
            p[2],
            p[3],
            p[4]  ^ UInt8(truncatingIfNeeded: packetNumber >> 56),
            p[5]  ^ UInt8(truncatingIfNeeded: packetNumber >> 48),
            p[6]  ^ UInt8(truncatingIfNeeded: packetNumber >> 40),
            p[7]  ^ UInt8(truncatingIfNeeded: packetNumber >> 32),
            p[8]  ^ UInt8(truncatingIfNeeded: packetNumber >> 24),
            p[9]  ^ UInt8(truncatingIfNeeded: packetNumber >> 16),
            p[10] ^ UInt8(truncatingIfNeeded: packetNumber >> 8),
            p[11] ^ UInt8(truncatingIfNeeded: packetNumber)
        )
    }
}

/// Constructs a nonce and returns it as an AES.GCM.Nonce directly — zero-copy path for AES-GCM.
///
/// - Precondition: iv.count == 12 (validated at init time)
@inline(__always)
private func constructNonceInline(iv: Data, packetNumber: UInt64) -> AES.GCM.Nonce {
    var nonceBytes = constructNonceTuple(iv: iv, packetNumber: packetNumber)
    return withUnsafeBytes(of: &nonceBytes) { buf in
        // AES.GCM.Nonce(data:) accepts any ContiguousBytes; UnsafeRawBufferPointer qualifies.
        try! AES.GCM.Nonce(data: buf)
    }
}

// MARK: - ChaCha20 Header Protection

/// ChaCha20-based header protection (RFC 9001 Section 5.4.4)
public struct ChaCha20HeaderProtection: HeaderProtection, Sendable {
    private let key: SymmetricKey

    /// Creates ChaCha20 header protection with the given key
    /// - Parameter key: The header protection key (32 bytes)
    public init(key: SymmetricKey) {
        precondition(key.bitCount == 256, "ChaCha20 header protection requires 32-byte key")
        self.key = key
    }

    public func mask(sample: Data) throws -> Data {
        guard sample.count >= 16 else {
            throw CryptoError.insufficientSample(expected: 16, actual: sample.count)
        }

        // For ChaCha20 header protection:
        // - Counter is the first 4 bytes of sample (little-endian)
        // - Nonce is the remaining 12 bytes
        let counter = sample.prefix(4)
        let nonce = sample.dropFirst(4).prefix(12)

        // Generate ChaCha20 keystream and use first 5 bytes as mask
        return try chaCha20KeystreamMask(key: key, counter: counter, nonce: Data(nonce))
    }
}

// MARK: - ChaCha20-Poly1305 Opener

/// ChaCha20-Poly1305 packet opener (decryption)
public struct ChaCha20Poly1305Opener: PacketOpener, Sendable {
    private let key: SymmetricKey
    private let iv: Data
    private let headerProtection: ChaCha20HeaderProtection

    /// ChaCha20-Poly1305 requires 12-byte IV
    public static let ivLength = 12

    /// Key size for ChaCha20-Poly1305 (32 bytes)
    public static let keySize = 32

    /// Creates a ChaCha20-Poly1305 opener
    /// - Parameters:
    ///   - key: The packet protection key (32 bytes)
    ///   - iv: The packet protection IV (12 bytes)
    ///   - hp: The header protection key (32 bytes)
    /// - Throws: CryptoError.invalidIVLength if IV is not 12 bytes
    public init(key: SymmetricKey, iv: Data, hp: SymmetricKey) throws {
        guard iv.count == Self.ivLength else {
            throw CryptoError.invalidIVLength(expected: Self.ivLength, actual: iv.count)
        }
        self.key = key
        self.iv = iv
        self.headerProtection = ChaCha20HeaderProtection(key: hp)
    }

    /// Creates an opener from key material
    /// - Throws: CryptoError.invalidIVLength if IV is not 12 bytes
    public init(keyMaterial: KeyMaterial) throws {
        try self.init(key: keyMaterial.key, iv: keyMaterial.iv, hp: keyMaterial.hp)
    }

    public func open(ciphertext: Data, packetNumber: UInt64, header: Data) throws -> Data {
        // Construct nonce: IV XOR packet number (inline, no heap allocation)
        let nonceBytes = constructNonceTuple(iv: iv, packetNumber: packetNumber)

        // Separate ciphertext and tag (last 16 bytes)
        guard ciphertext.count >= 16 else {
            throw QUICError.decryptionFailed
        }

        let encryptedData = ciphertext.prefix(ciphertext.count - 16)
        let tag = ciphertext.suffix(16)

        // Decrypt using ChaCha20-Poly1305
        do {
            let sealedBox = try withUnsafeBytes(of: nonceBytes) { buf in
                try ChaChaPoly.SealedBox(
                    nonce: ChaChaPoly.Nonce(data: buf),
                    ciphertext: encryptedData,
                    tag: tag
                )
            }

            let plaintext = try ChaChaPoly.open(sealedBox, using: key, authenticating: header)
            return plaintext
        } catch {
            // Convert CryptoKit errors to QUICError for consistent handling
            throw QUICError.decryptionFailed
        }
    }

    public func removeHeaderProtection(
        sample: Data,
        firstByte: UInt8,
        packetNumberBytes: Data
    ) throws -> (UInt8, Data) {
        // Generate mask using ChaCha20
        let mask = try headerProtection.mask(sample: sample)

        // For long header: mask lower 4 bits of first byte
        // For short header: mask lower 5 bits of first byte
        let isLongHeader = (firstByte & 0x80) != 0
        let firstByteMask: UInt8 = isLongHeader ? 0x0F : 0x1F

        let unprotectedFirstByte = firstByte ^ (mask[0] & firstByteMask)

        // Unmask packet number bytes
        // Use enumerated() to handle Data slices with non-zero startIndex
        var unprotectedPN = Data(capacity: packetNumberBytes.count)
        for (i, byte) in packetNumberBytes.enumerated() {
            unprotectedPN.append(byte ^ mask[i + 1])
        }

        return (unprotectedFirstByte, unprotectedPN)
    }
}

// MARK: - ChaCha20-Poly1305 Sealer

/// ChaCha20-Poly1305 packet sealer (encryption)
public struct ChaCha20Poly1305Sealer: PacketSealer, Sendable {
    private let key: SymmetricKey
    private let iv: Data
    private let headerProtection: ChaCha20HeaderProtection

    /// ChaCha20-Poly1305 requires 12-byte IV
    public static let ivLength = 12

    /// Key size for ChaCha20-Poly1305 (32 bytes)
    public static let keySize = 32

    /// Creates a ChaCha20-Poly1305 sealer
    /// - Parameters:
    ///   - key: The packet protection key (32 bytes)
    ///   - iv: The packet protection IV (12 bytes)
    ///   - hp: The header protection key (32 bytes)
    /// - Throws: CryptoError.invalidIVLength if IV is not 12 bytes
    public init(key: SymmetricKey, iv: Data, hp: SymmetricKey) throws {
        guard iv.count == Self.ivLength else {
            throw CryptoError.invalidIVLength(expected: Self.ivLength, actual: iv.count)
        }
        self.key = key
        self.iv = iv
        self.headerProtection = ChaCha20HeaderProtection(key: hp)
    }

    /// Creates a sealer from key material
    /// - Throws: CryptoError.invalidIVLength if IV is not 12 bytes
    public init(keyMaterial: KeyMaterial) throws {
        try self.init(key: keyMaterial.key, iv: keyMaterial.iv, hp: keyMaterial.hp)
    }

    public func seal(plaintext: Data, packetNumber: UInt64, header: Data) throws -> Data {
        // Construct nonce: IV XOR packet number (inline, no heap allocation)
        let nonceBytes = constructNonceTuple(iv: iv, packetNumber: packetNumber)

        // Encrypt using ChaCha20-Poly1305
        let sealedBox = try withUnsafeBytes(of: nonceBytes) { buf in
            try ChaChaPoly.seal(
                plaintext,
                using: key,
                nonce: ChaChaPoly.Nonce(data: buf),
                authenticating: header
            )
        }

        // Pre-allocate result: ciphertext + 16-byte tag
        var result = Data(capacity: sealedBox.ciphertext.count + sealedBox.tag.count)
        result.append(contentsOf: sealedBox.ciphertext)
        result.append(contentsOf: sealedBox.tag)
        return result
    }

    public func applyHeaderProtection(
        sample: Data,
        firstByte: UInt8,
        packetNumberBytes: Data
    ) throws -> (UInt8, Data) {
        // Generate mask using ChaCha20
        let mask = try headerProtection.mask(sample: sample)

        // For long header: mask lower 4 bits of first byte
        // For short header: mask lower 5 bits of first byte
        let isLongHeader = (firstByte & 0x80) != 0
        let firstByteMask: UInt8 = isLongHeader ? 0x0F : 0x1F

        let protectedFirstByte = firstByte ^ (mask[0] & firstByteMask)

        // Mask packet number bytes
        // Use enumerated() to handle Data slices with non-zero startIndex
        var protectedPN = Data(capacity: packetNumberBytes.count)
        for (i, byte) in packetNumberBytes.enumerated() {
            protectedPN.append(byte ^ mask[i + 1])
        }

        return (protectedFirstByte, protectedPN)
    }
}

// MARK: - Helper Functions

/// Generates ChaCha20 keystream mask for header protection (RFC 9001 Section 5.4.4)
///
/// This function implements proper ChaCha20 header protection using the raw
/// ChaCha20 block function with the counter from the sample.
///
/// - Parameters:
///   - key: The ChaCha20 key (32 bytes)
///   - counter: The 4-byte counter (from sample[0..3])
///   - nonce: The 12-byte nonce (from sample[4..15])
/// - Returns: First 5 bytes of the keystream as mask
private func chaCha20KeystreamMask(key: SymmetricKey, counter: Data, nonce: Data) throws -> Data {
    guard counter.count == 4 else {
        throw CryptoError.insufficientSample(expected: 4, actual: counter.count)
    }
    guard nonce.count == 12 else {
        throw CryptoError.insufficientSample(expected: 12, actual: nonce.count)
    }

    // Convert key to Data
    let keyData = key.withUnsafeBytes { Data($0) }

    // Convert counter to little-endian UInt32 (RFC 8439)
    // Safe for unaligned access and works on both little/big-endian platforms
    let counterValue: UInt32 = counter.withUnsafeBytes { bytes in
        let b0 = UInt32(bytes[0])
        let b1 = UInt32(bytes[1]) << 8
        let b2 = UInt32(bytes[2]) << 16
        let b3 = UInt32(bytes[3]) << 24
        return b0 | b1 | b2 | b3
    }

    // Generate keystream using RFC 8439 ChaCha20 block function
    let keystream = try chaCha20Block(key: keyData, counter: counterValue, nonce: nonce)

    // Return first 5 bytes as mask
    return keystream.prefix(5)
}

/// Performs single-block AES-ECB encryption for header protection (RFC 9001 Section 5.4.3)
///
/// QUIC Header Protection requires AES-ECB encryption of a single 16-byte block.
/// On Apple platforms, CommonCrypto is used for optimal performance.
/// On other platforms (Linux), _CryptoExtras AES._CBC with zero IV is used,
/// which is mathematically equivalent to ECB for the first block:
///
///     CBC: C = AES(key, P ⊕ IV)
///     When IV = 0: C = AES(key, P ⊕ 0) = AES(key, P) = ECB
///
/// - Parameters:
///   - key: The AES key (16 bytes for AES-128)
///   - block: The 16-byte block to encrypt
/// - Returns: First 5 bytes of the encrypted block (the mask)
/// - Throws: CryptoError if encryption fails
private func aesECBEncrypt(key: SymmetricKey, block: Data) throws -> Data {
    #if canImport(CommonCrypto)
    // Apple platforms: Use CommonCrypto for optimal performance
    var output = Data(count: 16)
    var outputLength: size_t = 0

    let status = key.withUnsafeBytes { keyBytes in
        block.withUnsafeBytes { blockBytes in
            output.withUnsafeMutableBytes { outputBytes in
                CCCrypt(
                    CCOperation(kCCEncrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode),
                    keyBytes.baseAddress, keyBytes.count,
                    nil,  // No IV for ECB
                    blockBytes.baseAddress, 16,
                    outputBytes.baseAddress, 16,
                    &outputLength
                )
            }
        }
    }

    guard status == kCCSuccess else {
        throw CryptoError.headerProtectionFailed
    }

    return Data(output.prefix(5))
    #else
    // ==========================================================================
    // Linux/Other Platforms: AES-ECB via CBC(IV=0) Workaround
    // ==========================================================================
    //
    // QUIC Header Protection (RFC 9001 Section 5.4.3) requires AES-ECB to
    // encrypt a single 16-byte block and use the first 5 bytes as the mask.
    //
    // Problem: swift-crypto does not expose AES-ECB directly.
    //
    // Solution: Use AES-CBC with a zero IV, which is mathematically equivalent
    // to AES-ECB for the first block:
    //
    //   CBC encryption: C = AES(key, plaintext ⊕ IV)
    //   When IV = 0:    C = AES(key, plaintext ⊕ 0) = AES(key, plaintext)
    //
    // This is identical to ECB for a single block.
    //
    // Output handling:
    //   - CBC produces: encrypted block (16 bytes) + PKCS#7 padding (16 bytes)
    //   - We only need the first 5 bytes, so the padding is simply ignored
    //
    // Performance note:
    //   The extra padding block causes ~20% overhead vs native ECB, but header
    //   protection is <1% of total packet processing time.
    //
    // Future migration:
    //   If swift-crypto exposes AES-ECB publicly, migrate to that API.
    //   _CryptoExtras is widely used and stable despite the underscore prefix.
    //
    // ==========================================================================
    do {
        let zeroIV = try AES._CBC.IV(ivBytes: Data(count: 16))
        let ciphertext = try AES._CBC.encrypt(block, using: key, iv: zeroIV)
        return Data(ciphertext.prefix(5))
    } catch {
        throw CryptoError.headerProtectionFailed
    }
    #endif
}
