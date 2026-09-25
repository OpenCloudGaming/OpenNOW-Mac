/// TLS 1.3 Session Ticket Store (RFC 8446 Section 4.6.1)
///
/// Server-side storage for session tickets to enable session resumption.
/// Stores encrypted session state that can be used to derive PSKs.

import Foundation
import Crypto
import Synchronization

// MARK: - Session Ticket Store

/// Server-side session ticket storage and validation
public final class SessionTicketStore: Sendable {

    private let state = Mutex<StoreState>(StoreState())
    private let ticketKey: SymmetricKey
    private let maxTickets: Int

    private struct StoreState: Sendable {
        var sessions: [Data: StoredSession] = [:]
    }

    /// Stored session information
    public struct StoredSession: Sendable {
        public let resumptionMasterSecret: SymmetricKey
        public let cipherSuite: CipherSuite
        public let createdAt: Date
        public let lifetime: UInt32
        public let ticketAgeAdd: UInt32
        public let alpn: String?
        public let maxEarlyDataSize: UInt32
        /// The ticket nonce used for PSK derivation (RFC 8446 Section 4.6.1)
        public let ticketNonce: Data

        public init(
            resumptionMasterSecret: SymmetricKey,
            cipherSuite: CipherSuite,
            createdAt: Date = Date(),
            lifetime: UInt32 = 86400, // 24 hours default
            ticketAgeAdd: UInt32,
            alpn: String? = nil,
            maxEarlyDataSize: UInt32 = 0,
            ticketNonce: Data = Data()
        ) {
            self.resumptionMasterSecret = resumptionMasterSecret
            self.cipherSuite = cipherSuite
            self.createdAt = createdAt
            self.lifetime = lifetime
            self.ticketAgeAdd = ticketAgeAdd
            self.alpn = alpn
            self.maxEarlyDataSize = maxEarlyDataSize
            self.ticketNonce = ticketNonce
        }

        /// Check if session is still valid
        public func isValid(at date: Date = Date()) -> Bool {
            let elapsed = date.timeIntervalSince(createdAt)
            return elapsed >= 0 && elapsed < Double(lifetime)
        }

        /// Derive the resumption PSK for this session
        public func derivePSK(ticketNonce: Data, keySchedule: TLSKeySchedule) -> SymmetricKey {
            keySchedule.deriveResumptionPSK(
                resumptionMasterSecret: resumptionMasterSecret,
                ticketNonce: ticketNonce
            )
        }

        /// Validate ticket age
        /// - Parameters:
        ///   - obfuscatedAge: The obfuscated ticket age from client
        ///   - now: Current time
        ///   - tolerance: Allowed clock skew in milliseconds (default 10 seconds)
        /// - Returns: true if age is valid
        public func isValidAge(obfuscatedAge: UInt32, at now: Date = Date(), tolerance: UInt32 = 10000) -> Bool {
            let actualAgeMs = UInt32(now.timeIntervalSince(createdAt) * 1000)
            let claimedAgeMs = obfuscatedAge &- ticketAgeAdd

            // Allow for some clock skew
            let diff = claimedAgeMs > actualAgeMs
                ? claimedAgeMs - actualAgeMs
                : actualAgeMs - claimedAgeMs

            return diff <= tolerance
        }
    }

    // MARK: - Initialization

    /// Create a new session ticket store
    /// - Parameters:
    ///   - ticketKey: Key for encrypting/decrypting ticket data (32 bytes recommended)
    ///   - maxTickets: Maximum number of tickets to store (LRU eviction)
    public init(ticketKey: SymmetricKey? = nil, maxTickets: Int = 10000) {
        self.ticketKey = ticketKey ?? SymmetricKey(size: .bits256)
        self.maxTickets = maxTickets
    }

    // MARK: - Ticket Generation

    /// Generate a new session ticket
    /// - Parameters:
    ///   - session: Session information to store
    ///   - nonce: Unique nonce for PSK derivation
    /// - Returns: NewSessionTicket message
    public func generateTicket(
        for session: StoredSession,
        nonce ticketNonce: Data? = nil
    ) -> NewSessionTicket {
        // Generate random ticket ID
        let ticketId = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

        // Generate nonce if not provided
        let nonce = ticketNonce ?? generateNonce()

        // Create session with nonce included for later PSK derivation
        let sessionWithNonce = StoredSession(
            resumptionMasterSecret: session.resumptionMasterSecret,
            cipherSuite: session.cipherSuite,
            createdAt: session.createdAt,
            lifetime: session.lifetime,
            ticketAgeAdd: session.ticketAgeAdd,
            alpn: session.alpn,
            maxEarlyDataSize: session.maxEarlyDataSize,
            ticketNonce: nonce
        )

        // Store session with nonce
        state.withLock { state in
            // Evict old sessions if necessary
            if state.sessions.count >= maxTickets {
                evictOldSessions(&state)
            }
            state.sessions[ticketId] = sessionWithNonce
        }

        // Build extensions
        var extensions: [TLSExtension] = []
        if session.maxEarlyDataSize > 0 {
            extensions.append(.earlyData(.newSessionTicket(maxEarlyDataSize: session.maxEarlyDataSize)))
        }

        return NewSessionTicket(
            ticketLifetime: session.lifetime,
            ticketAgeAdd: session.ticketAgeAdd,
            ticketNonce: nonce,
            ticket: ticketId,
            extensions: extensions
        )
    }

    /// Generate a random nonce for ticket
    private func generateNonce() -> Data {
        // 8 bytes (64 bits) using Swift Crypto (cross-platform)
        return SymmetricKey(size: SymmetricKeySize(bitCount: 64)).withUnsafeBytes { Data($0) }
    }

    /// Evict oldest sessions
    private func evictOldSessions(_ state: inout StoreState) {
        let now = Date()

        // First remove expired sessions
        state.sessions = state.sessions.filter { _, session in
            session.isValid(at: now)
        }

        // If still over limit, remove oldest
        if state.sessions.count >= maxTickets {
            let sorted = state.sessions.sorted { $0.value.createdAt < $1.value.createdAt }
            let toRemove = sorted.prefix(state.sessions.count - maxTickets + 1)
            for (key, _) in toRemove {
                state.sessions.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Ticket Validation

    /// Lookup a session by ticket ID
    /// - Parameter ticketId: The ticket identity from ClientHello
    /// - Returns: StoredSession if found and valid
    public func lookupSession(ticketId: Data) -> StoredSession? {
        state.withLock { state in
            guard let session = state.sessions[ticketId] else {
                return nil
            }

            // Check if still valid
            guard session.isValid() else {
                state.sessions.removeValue(forKey: ticketId)
                return nil
            }

            return session
        }
    }

    /// Validate a PSK binder
    /// - Parameters:
    ///   - session: The stored session
    ///   - ticketNonce: Original ticket nonce (from NewSessionTicket)
    ///   - truncatedTranscript: ClientHello up to binders
    ///   - binder: The binder to validate
    ///   - cipherSuite: Cipher suite for binder computation
    /// - Returns: true if binder is valid
    public func validateBinder(
        session: StoredSession,
        ticketNonce: Data,
        truncatedTranscript: Data,
        binder: Data,
        cipherSuite: CipherSuite = .tls_aes_128_gcm_sha256
    ) -> Bool {
        // Derive PSK from session
        var keySchedule = TLSKeySchedule(cipherSuite: cipherSuite)
        let psk = session.derivePSK(ticketNonce: ticketNonce, keySchedule: keySchedule)

        // Initialize key schedule with PSK
        keySchedule.deriveEarlySecret(psk: psk)

        // Derive binder key
        guard let binderKey = try? keySchedule.deriveBinderKey(isResumption: true) else {
            return false
        }

        // Compute expected binder
        let helper = PSKBinderHelper(cipherSuite: cipherSuite)
        let binderKeyData = binderKey.withUnsafeBytes { Data($0) }
        let transcriptHash = computeTranscriptHash(truncatedTranscript, cipherSuite: cipherSuite)

        return helper.isValidBinder(
            forKey: binderKeyData,
            transcriptHash: transcriptHash,
            expected: binder
        )
    }

    /// Compute transcript hash
    private func computeTranscriptHash(_ data: Data, cipherSuite: CipherSuite) -> Data {
        switch cipherSuite {
        case .tls_aes_256_gcm_sha384:
            return Data(SHA384.hash(data: data))
        default:
            return Data(SHA256.hash(data: data))
        }
    }

    // MARK: - Cleanup

    /// Remove all expired sessions
    public func purgeExpired() {
        state.withLock { state in
            let now = Date()
            state.sessions = state.sessions.filter { _, session in
                session.isValid(at: now)
            }
        }
    }

    /// Remove a specific session
    public func removeSession(ticketId: Data) {
        _ = state.withLock { state in
            state.sessions.removeValue(forKey: ticketId)
        }
    }

    /// Clear all sessions
    public func clear() {
        state.withLock { state in
            state.sessions.removeAll()
        }
    }

    /// Number of stored sessions
    public var count: Int {
        state.withLock { $0.sessions.count }
    }
}

// MARK: - PSK Validation Result

/// Result of PSK validation in ClientHello
public enum PSKValidationResult: Sendable {
    /// PSK was validated successfully
    case valid(index: UInt16, session: SessionTicketStore.StoredSession, psk: SymmetricKey)

    /// No PSK offered
    case noPskOffered

    /// PSK offered but invalid (binder mismatch, expired, etc.)
    case invalid(reason: String)
}
