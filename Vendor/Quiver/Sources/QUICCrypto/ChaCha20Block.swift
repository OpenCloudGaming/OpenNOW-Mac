/// ChaCha20 Block Function (RFC 8439 Section 2.3)
///
/// Implements the raw ChaCha20 block function with explicit counter support.
/// Required for QUIC header protection (RFC 9001 Section 5.4.4).
///
/// Swift Crypto's ChaChaPoly does not expose the raw block function with
/// explicit counter control, so we implement it here per RFC 8439.

import Foundation

// MARK: - ChaCha20 Error

/// Errors that can occur during ChaCha20 operations
public enum ChaCha20Error: Error, Sendable {
    /// Key has invalid length (expected 32 bytes)
    case invalidKeyLength(expected: Int, actual: Int)
    /// Nonce has invalid length (expected 12 bytes)
    case invalidNonceLength(expected: Int, actual: Int)
    /// Sample has invalid length (expected at least 16 bytes)
    case invalidSampleLength(expected: Int, actual: Int)
}

// MARK: - ChaCha20 Constants

/// ChaCha20 state constants ("expand 32-byte k")
private let chaCha20Constants: (UInt32, UInt32, UInt32, UInt32) = (
    0x61707865,  // "expa"
    0x3320646e,  // "nd 3"
    0x79622d32,  // "2-by"
    0x6b206574   // "te k"
)

// MARK: - Quarter Round

/// ChaCha20 Quarter Round (RFC 8439 Section 2.1)
///
/// The basic operation of ChaCha20. Operates on 4 words of the state.
/// Returns the modified values as a tuple to avoid Swift exclusivity issues.
@inline(__always)
private func quarterRound(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> (UInt32, UInt32, UInt32, UInt32) {
    var a = a, b = b, c = c, d = d
    a &+= b; d ^= a; d = (d << 16) | (d >> 16)
    c &+= d; b ^= c; b = (b << 12) | (b >> 20)
    a &+= b; d ^= a; d = (d << 8) | (d >> 24)
    c &+= d; b ^= c; b = (b << 7) | (b >> 25)
    return (a, b, c, d)
}

// MARK: - ChaCha20 Block Function

/// ChaCha20 Block Function (RFC 8439 Section 2.3)
///
/// Generates a 64-byte keystream block from the given key, counter, and nonce.
///
/// - Parameters:
///   - key: 32-byte key
///   - counter: 32-bit block counter
///   - nonce: 12-byte nonce
/// - Returns: 64-byte keystream block
/// - Throws: ChaCha20Error if key or nonce has invalid length
func chaCha20Block(key: Data, counter: UInt32, nonce: Data) throws -> Data {
    guard key.count == 32 else {
        throw ChaCha20Error.invalidKeyLength(expected: 32, actual: key.count)
    }
    guard nonce.count == 12 else {
        throw ChaCha20Error.invalidNonceLength(expected: 12, actual: nonce.count)
    }

    // Initialize state array (16 x 32-bit words)
    //
    // State layout (RFC 8439 Section 2.3):
    //   state[0..3]   = constants ("expand 32-byte k")
    //   state[4..11]  = key (8 words, little-endian)
    //   state[12]     = counter
    //   state[13..15] = nonce (3 words, little-endian)

    var state = [UInt32](repeating: 0, count: 16)

    // Constants
    state[0] = chaCha20Constants.0
    state[1] = chaCha20Constants.1
    state[2] = chaCha20Constants.2
    state[3] = chaCha20Constants.3

    // Key (8 words, little-endian) - using alignment-safe load
    key.withUnsafeBytes { keyBytes in
        for i in 0..<8 {
            state[4 + i] = keyBytes.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian
        }
    }

    // Counter
    state[12] = counter

    // Nonce (3 words, little-endian) - using alignment-safe load
    nonce.withUnsafeBytes { nonceBytes in
        for i in 0..<3 {
            state[13 + i] = nonceBytes.load(fromByteOffset: i * 4, as: UInt32.self).littleEndian
        }
    }

    // Working state (copy of initial state)
    var working = state

    // 20 rounds (10 double-rounds)
    // Each double-round consists of 4 column rounds + 4 diagonal rounds
    for _ in 0..<10 {
        // Column rounds
        (working[0], working[4], working[8],  working[12]) = quarterRound(working[0], working[4], working[8],  working[12])
        (working[1], working[5], working[9],  working[13]) = quarterRound(working[1], working[5], working[9],  working[13])
        (working[2], working[6], working[10], working[14]) = quarterRound(working[2], working[6], working[10], working[14])
        (working[3], working[7], working[11], working[15]) = quarterRound(working[3], working[7], working[11], working[15])

        // Diagonal rounds
        (working[0], working[5], working[10], working[15]) = quarterRound(working[0], working[5], working[10], working[15])
        (working[1], working[6], working[11], working[12]) = quarterRound(working[1], working[6], working[11], working[12])
        (working[2], working[7], working[8],  working[13]) = quarterRound(working[2], working[7], working[8],  working[13])
        (working[3], working[4], working[9],  working[14]) = quarterRound(working[3], working[4], working[9],  working[14])
    }

    // Add original state to working state
    for i in 0..<16 {
        working[i] &+= state[i]
    }

    // Serialize as little-endian bytes (64 bytes total)
    var output = Data(capacity: 64)
    for word in working {
        withUnsafeBytes(of: word.littleEndian) { output.append(contentsOf: $0) }
    }

    return output
}

// MARK: - Convenience Functions

/// Generates a ChaCha20 keystream mask for QUIC header protection
///
/// Per RFC 9001 Section 5.4.4:
/// - sample[0..3] is used as the counter (little-endian)
/// - sample[4..15] is used as the nonce
/// - The first 5 bytes of the keystream block form the mask
///
/// - Parameters:
///   - key: 32-byte header protection key
///   - sample: 16-byte sample from encrypted packet
/// - Returns: 5-byte mask for header protection
/// - Throws: ChaCha20Error if key or sample has invalid length
func chaCha20HeaderProtectionMask(key: Data, sample: Data) throws -> Data {
    guard key.count == 32 else {
        throw ChaCha20Error.invalidKeyLength(expected: 32, actual: key.count)
    }
    guard sample.count >= 16 else {
        throw ChaCha20Error.invalidSampleLength(expected: 16, actual: sample.count)
    }

    // Extract counter from sample[0..3] (little-endian) - alignment-safe
    let counter = sample.withUnsafeBytes { sampleBytes -> UInt32 in
        sampleBytes.load(as: UInt32.self).littleEndian
    }

    // Extract nonce from sample[4..15]
    let nonce = sample.subdata(in: 4..<16)

    // Generate keystream block
    let keystream = try chaCha20Block(key: key, counter: counter, nonce: nonce)

    // Return first 5 bytes as mask
    return keystream.prefix(5)
}
