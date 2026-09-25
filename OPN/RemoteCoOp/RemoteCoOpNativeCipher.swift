import CryptoKit
import Foundation

/// Authenticated encryption for the native Remote Co-Op UDP datagrams. Every datagram is sealed
/// with ChaCha20-Poly1305 under a per-peer key and a sliding replay window; the token never travels.
final class OPNRemoteCoOpNativeCipher: @unchecked Sendable {
    /// First byte of every sealed datagram. The receiver opens first, then demultiplexes the plaintext.
    static let sealedMagic: UInt8 = 0x4E
    /// Bytes a sealed datagram costs over its plaintext: magic, sequence, tag.
    static let overheadBytes = 1 + 8 + 16
    /// How far behind the highest accepted sequence a datagram may still arrive.
    static let replayWindow: UInt64 = 1024

    enum Role {
        case host
        case guest
    }

    private static let hostToGuestInfo = Data("OpenNOW.RemoteCoOp.Native.HostToGuest".utf8)
    private static let guestToHostInfo = Data("OpenNOW.RemoteCoOp.Native.GuestToHost".utf8)
    private static let tagLength = 16

    private let sealKey: SymmetricKey
    private let openKey: SymmetricKey
    private let lock = NSLock()
    private var sealSequence: UInt64 = 0
    private var highestReceivedSequence: UInt64 = 0
    private var recentlyReceivedSequences: Set<UInt64> = []

    init(token: String, role: Role) {
        let inputKey = SymmetricKey(data: Data(token.utf8))
        let isHost = role == .host
        sealKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKey,
                                         info: isHost ? Self.hostToGuestInfo : Self.guestToHostInfo,
                                         outputByteCount: 32)
        openKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKey,
                                         info: isHost ? Self.guestToHostInfo : Self.hostToGuestInfo,
                                         outputByteCount: 32)
    }

    /// Seals one plaintext datagram, or nil when no nonce could be produced.
    func seal(_ plaintext: Data) -> Data? {
        lock.lock()
        sealSequence &+= 1
        let sequence = sealSequence
        lock.unlock()
        guard let nonce = Self.nonce(for: sequence),
              let sealed = try? ChaChaPoly.seal(plaintext, using: sealKey, nonce: nonce) else { return nil }
        var datagram = Data(capacity: Self.overheadBytes + plaintext.count)
        datagram.append(Self.sealedMagic)
        Self.appendUInt64(sequence, to: &datagram)
        datagram.append(sealed.ciphertext)
        datagram.append(sealed.tag)
        return datagram
    }

    /// Opens and authenticates one sealed datagram, returning the plaintext or nil.
    func open(_ datagram: Data) -> Data? {
        let bytes = [UInt8](datagram)
        guard bytes.count >= Self.overheadBytes, bytes[0] == Self.sealedMagic else { return nil }
        let sequence = Self.readUInt64(bytes, at: 1)
        guard let nonce = Self.nonce(for: sequence) else { return nil }
        let ciphertextEnd = bytes.count - Self.tagLength
        let ciphertext = Data(bytes[9..<ciphertextEnd])
        let tag = Data(bytes[ciphertextEnd...])
        guard let sealed = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag),
              let plaintext = try? ChaChaPoly.open(sealed, using: openKey) else { return nil }
        guard accept(sequence: sequence) else { return nil }
        return plaintext
    }

    /// Records an authenticated sequence. Replays and anything older than the window are refused.
    private func accept(sequence: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if recentlyReceivedSequences.contains(sequence) { return false }
        if sequence + Self.replayWindow < highestReceivedSequence { return false }
        if sequence > highestReceivedSequence {
            let floor = sequence > Self.replayWindow ? sequence - Self.replayWindow : 0
            recentlyReceivedSequences = recentlyReceivedSequences.filter { $0 > floor }
            highestReceivedSequence = sequence
        }
        recentlyReceivedSequences.insert(sequence)
        return true
    }

    private static func nonce(for sequence: UInt64) -> ChaChaPoly.Nonce? {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 {
            bytes[index] = UInt8(truncatingIfNeeded: sequence >> UInt64(56 - index * 8))
        }
        return try? ChaChaPoly.Nonce(data: Data(bytes))
    }

    private static func appendUInt64(_ value: UInt64, to bytes: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value = (value << 8) | UInt64(bytes[offset + index]) }
        return value
    }
}
