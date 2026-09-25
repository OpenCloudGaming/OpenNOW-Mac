/// Stateless Reset Handling (RFC 9000 Section 10.3)
///
/// A stateless reset is a final action that an endpoint can take when it
/// has lost state and cannot process a packet. The reset is indicated by
/// a 16-byte token at the end of a UDP datagram.

import Foundation
import Synchronization
import Crypto
import QUICCore

// MARK: - Constants

/// Token length in bytes (RFC 9000 Section 10.3)
private let tokenLength = 16

// MARK: - Stateless Reset Token

/// A 16-byte stateless reset token
public struct StatelessResetToken: Sendable, Hashable {
    /// The raw token data (16 bytes)
    public let data: Data

    /// Creates a stateless reset token from raw data
    /// - Parameter data: 16 bytes of token data
    /// - Throws: If data is not exactly 16 bytes
    public init(data: Data) throws {
        guard data.count == 16 else {
            throw StatelessResetError.invalidTokenLength(data.count)
        }
        self.data = data
    }

    /// Generates a new random stateless reset token
    public static func generate() -> StatelessResetToken {
        // 16 bytes (128 bits) using Swift Crypto (cross-platform)
        let tokenData = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        // Force try is safe because we know the length is 16
        return try! StatelessResetToken(data: tokenData)
    }

    /// Generates a deterministic stateless reset token from a static key and connection ID
    /// This allows the token to be regenerated without state (RFC 9000 Section 10.3.2)
    /// - Parameters:
    ///   - staticKey: A secret key known only to this endpoint
    ///   - connectionID: The connection ID this token is for
    /// - Returns: A deterministic token
    public static func generate(staticKey: Data, connectionID: ConnectionID) -> StatelessResetToken {
        // Use HMAC-SHA256 truncated to 16 bytes
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: staticKey))
        hmac.update(data: connectionID.bytes)
        let fullDigest = Data(hmac.finalize())
        // Force try is safe because we take exactly 16 bytes
        return try! StatelessResetToken(data: fullDigest.prefix(16))
    }
}

// MARK: - Stateless Reset Packet

/// A stateless reset packet (RFC 9000 Section 10.3)
///
/// Format:
/// - Appear to be a short header packet (first bit is 0)
/// - Unpredictable bits followed by the 16-byte token
/// - Must be at least 21 bytes (to be distinguishable from valid short packets)
public struct StatelessResetPacket: Sendable {
    /// The stateless reset token (last 16 bytes)
    public let token: StatelessResetToken

    /// Random bytes preceding the token (at least 5 bytes)
    public let randomBytes: Data

    /// Minimum packet size (RFC 9000 says at least 21 bytes)
    public static let minimumSize = 21

    /// Maximum packet size (to avoid looking like an attack).
    ///
    /// Defaults to `ProtocolLimits.minimumMaximumDatagramSize` (1200).
    /// Stateless resets should not exceed the path MTU; this constant
    /// provides a safe upper bound for the common case.
    public static let maximumSize = ProtocolLimits.minimumMaximumDatagramSize

    /// Creates a stateless reset packet
    /// - Parameters:
    ///   - token: The stateless reset token
    ///   - minimumSize: Minimum total packet size (at least 21)
    public init(token: StatelessResetToken, minimumSize: Int = minimumSize) {
        self.token = token

        // Random bytes = total size - 16 (token) - 1 (fixed bits byte)
        let randomSize = max(minimumSize - 16 - 1, 4)
        // Generate random bytes using Swift Crypto (cross-platform)
        let random = SymmetricKey(size: SymmetricKeySize(bitCount: randomSize * 8))
            .withUnsafeBytes { Data($0) }
        self.randomBytes = random
    }

    /// Encodes the stateless reset packet
    public func encode() -> Data {
        var data = Data(capacity: 1 + randomBytes.count + 16)

        // First byte: looks like short header (fixed bit = 1, must not match valid packet)
        // RFC 9000: The first byte MUST have the Fixed Bit set (0x40)
        // But it should NOT be valid when decrypted, so we use random bits
        // with fixed bit set
        var firstByte: UInt8 = 0x40  // Fixed bit set
        firstByte |= UInt8.random(in: 0..<0x40)  // Random lower bits
        // Clear the long header bit to make it look like short header
        firstByte &= ~0x80
        data.append(firstByte)

        // Random bytes
        data.append(randomBytes)

        // Stateless reset token (last 16 bytes)
        data.append(token.data)

        return data
    }

    /// Attempts to parse a stateless reset packet from data
    /// - Parameter data: The received packet data
    /// - Returns: The token if this is a stateless reset, nil otherwise
    public static func extractToken(from data: Data) -> StatelessResetToken? {
        // Must be at least 21 bytes
        guard data.count >= minimumSize else {
            return nil
        }

        // Extract last 16 bytes as potential token
        let tokenData = data.suffix(16)
        return try? StatelessResetToken(data: Data(tokenData))
    }
}

// MARK: - Stateless Reset Manager

/// Manages stateless reset tokens for a connection
public final class StatelessResetManager: Sendable {

    private let state = Mutex<ResetState>(ResetState())

    private struct ResetState: Sendable {
        /// Tokens we've sent to peer (they can use these to reset us)
        var sentTokens: Set<Data> = []

        /// Tokens received from peer (we can detect their resets)
        var receivedTokens: Set<Data> = []

        /// Static key for generating deterministic tokens (optional)
        var staticKey: Data?
    }

    // MARK: - Initialization

    /// Creates a new stateless reset manager
    /// - Parameter staticKey: Optional static key for deterministic token generation
    public init(staticKey: Data? = nil) {
        if let key = staticKey {
            state.withLock { $0.staticKey = key }
        }
    }

    // MARK: - Token Management

    /// Generates a new stateless reset token for a connection ID we're issuing
    /// - Parameter connectionID: The connection ID this token is for
    /// - Returns: A new stateless reset token
    public func generateToken(for connectionID: ConnectionID) -> StatelessResetToken {
        let token = state.withLock { s -> StatelessResetToken in
            if let key = s.staticKey {
                return StatelessResetToken.generate(staticKey: key, connectionID: connectionID)
            } else {
                return StatelessResetToken.generate()
            }
        }

        _ = state.withLock { s in
            s.sentTokens.insert(token.data)
        }

        return token
    }

    /// Registers a token we've sent to the peer
    /// - Parameter token: The token data
    public func registerSentToken(_ token: Data) {
        _ = state.withLock { s in
            s.sentTokens.insert(token)
        }
    }

    /// Registers a token received from the peer (from transport parameters or NEW_CONNECTION_ID)
    /// - Parameter token: The token data
    public func registerReceivedToken(_ token: Data) {
        _ = state.withLock { s in
            s.receivedTokens.insert(token)
        }
    }

    /// Removes a token (e.g., when a connection ID is retired)
    /// - Parameter token: The token to remove
    public func removeReceivedToken(_ token: Data) {
        _ = state.withLock { s in
            s.receivedTokens.remove(token)
        }
    }

    // MARK: - Detection

    /// Checks if a received packet is a stateless reset
    /// - Parameter data: The received packet data
    /// - Returns: true if this is a stateless reset packet
    ///
    /// Note: Uses constant-time comparison to prevent timing attacks
    public func isStatelessReset(_ data: Data) -> Bool {
        // Must be at least the minimum size
        guard data.count >= StatelessResetPacket.minimumSize else {
            return false
        }

        // Must look like a short header (first bit = 0)
        guard let firstByte = data.first, (firstByte & 0x80) == 0 else {
            return false
        }

        // Extract last 16 bytes and check against received tokens
        // Uses constant-time comparison for security
        let tokenData = Data(data.suffix(tokenLength))
        return state.withLock { s in
            constantTimeContains(tokenData, in: s.receivedTokens)
        }
    }

    /// Extracts the token from a stateless reset packet
    /// - Parameter data: The packet data
    /// - Returns: The token if found and recognized, nil otherwise
    ///
    /// Note: Uses constant-time comparison to prevent timing attacks
    public func extractRecognizedToken(from data: Data) -> StatelessResetToken? {
        guard let token = StatelessResetPacket.extractToken(from: data) else {
            return nil
        }

        return state.withLock { s in
            constantTimeContains(token.data, in: s.receivedTokens) ? token : nil
        }
    }

    // MARK: - Sending Resets

    /// Creates a stateless reset packet for a connection ID
    /// - Parameters:
    ///   - connectionID: The connection ID being reset
    ///   - minimumSize: Minimum packet size (should be larger than the triggering packet)
    /// - Returns: The encoded stateless reset packet, or nil if no token exists
    public func createStatelessReset(
        for connectionID: ConnectionID,
        minimumSize: Int = StatelessResetPacket.minimumSize
    ) -> Data? {
        let token = state.withLock { s -> StatelessResetToken? in
            // Generate or retrieve token for this CID
            if let key = s.staticKey {
                return StatelessResetToken.generate(staticKey: key, connectionID: connectionID)
            }
            return nil
        }

        guard let token = token else {
            return nil
        }

        let packet = StatelessResetPacket(
            token: token,
            minimumSize: min(minimumSize, StatelessResetPacket.maximumSize)
        )
        return packet.encode()
    }

    /// Gets all tokens we've sent to the peer
    public var sentTokens: Set<Data> {
        state.withLock { $0.sentTokens }
    }

    /// Gets all tokens we've received from the peer
    public var receivedTokens: Set<Data> {
        state.withLock { $0.receivedTokens }
    }
}

// MARK: - Errors

/// Errors related to stateless reset handling
public enum StatelessResetError: Error, Sendable {
    /// Token length is not 16 bytes
    case invalidTokenLength(Int)
    /// No token available for the connection ID
    case noTokenAvailable
    /// Packet too short to be a stateless reset
    case packetTooShort
}

// MARK: - Security Helpers

/// Performs constant-time comparison of two Data values
/// This prevents timing attacks by ensuring comparison time is independent of data
/// - Parameters:
///   - a: First data to compare
///   - b: Second data to compare
/// - Returns: true if the data values are equal
@inline(never)
private func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var result: UInt8 = 0
    for (x, y) in zip(a, b) {
        result |= x ^ y
    }
    return result == 0
}

/// Checks if a token matches any token in a set using constant-time comparison
/// - Parameters:
///   - token: The token to search for
///   - tokens: The set of tokens to search in
/// - Returns: true if the token is found
private func constantTimeContains(_ token: Data, in tokens: Set<Data>) -> Bool {
    var result: UInt8 = 0
    for existingToken in tokens {
        // Use bitwise OR accumulator to prevent compiler optimization
        result |= constantTimeCompareUInt8(token, existingToken)
    }
    return result != 0
}

/// Constant-time comparison returning a UInt8 (1 = equal, 0 = not equal)
/// to avoid Bool-based short-circuit optimizations
@inline(never)
private func constantTimeCompareUInt8(_ a: Data, _ b: Data) -> UInt8 {
    guard a.count == b.count else { return 0 }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) {
        diff |= x ^ y
    }
    return diff == 0 ? 1 : 0
}
