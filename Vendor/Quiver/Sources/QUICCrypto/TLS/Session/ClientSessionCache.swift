/// Client Session Cache (RFC 8446 Section 4.6.1)
///
/// Client-side storage for session tickets to enable session resumption
/// and 0-RTT early data.

import Foundation
import Crypto
import Synchronization

// MARK: - Client Session Cache

/// Client-side session cache for TLS 1.3 session resumption
///
/// Stores session tickets received from servers to enable:
/// - Session resumption without full handshake
/// - 0-RTT early data (if server supports it)
public final class ClientSessionCache: Sendable {

    private let state = Mutex<CacheState>(CacheState())
    private let maxSessionsPerServer: Int

    private struct CacheState: Sendable {
        /// Sessions indexed by server identity (hostname:port)
        var sessions: [String: [CachedSession]] = [:]
    }

    // MARK: - Cached Session

    /// A cached session for resumption
    public struct CachedSession: Sendable {
        /// The NewSessionTicket received from server
        public let ticket: NewSessionTicket

        /// The resumption master secret (derived at end of handshake)
        public let resumptionMasterSecret: SymmetricKey

        /// The cipher suite used in the original connection
        public let cipherSuite: CipherSuite

        /// The negotiated ALPN protocol (if any)
        public let alpn: String?

        /// When this session was created
        public let createdAt: Date

        /// Server identity (hostname:port)
        public let serverIdentity: String

        /// Creates a cached session
        public init(
            ticket: NewSessionTicket,
            resumptionMasterSecret: SymmetricKey,
            cipherSuite: CipherSuite,
            alpn: String?,
            createdAt: Date = Date(),
            serverIdentity: String
        ) {
            self.ticket = ticket
            self.resumptionMasterSecret = resumptionMasterSecret
            self.cipherSuite = cipherSuite
            self.alpn = alpn
            self.createdAt = createdAt
            self.serverIdentity = serverIdentity
        }

        /// Whether this session is still valid for use
        public var isValid: Bool {
            isValid(at: Date())
        }

        /// Whether this session is valid at the given time
        public func isValid(at date: Date) -> Bool {
            let elapsed = date.timeIntervalSince(createdAt)
            return elapsed >= 0 && elapsed < Double(ticket.ticketLifetime)
        }

        /// Maximum early data size allowed (0 if early data not supported)
        public var maxEarlyDataSize: UInt32 {
            for ext in ticket.extensions {
                if case .earlyData(let earlyData) = ext,
                   case .newSessionTicket(let maxSize) = earlyData {
                    return maxSize
                }
            }
            return 0
        }

        /// Whether this session supports 0-RTT early data
        public var supportsEarlyData: Bool {
            maxEarlyDataSize > 0
        }

        /// Computes the obfuscated ticket age for use in ClientHello
        public func obfuscatedTicketAge(at date: Date = Date()) -> UInt32 {
            let ageMs = UInt32(date.timeIntervalSince(createdAt) * 1000)
            return ageMs &+ ticket.ticketAgeAdd
        }

        /// Derives the PSK for this session
        public func derivePSK(keySchedule: TLSKeySchedule) -> SymmetricKey {
            keySchedule.deriveResumptionPSK(
                resumptionMasterSecret: resumptionMasterSecret,
                ticketNonce: ticket.ticketNonce
            )
        }

        /// Converts this cached session to SessionTicketData for use with TLS provider
        ///
        /// The SessionTicketData contains the pre-derived PSK that the ClientStateMachine
        /// needs for building the ClientHello with PSK extension and deriving 0-RTT keys.
        public var sessionTicketData: SessionTicketData {
            // Derive PSK from resumption master secret
            let keySchedule = TLSKeySchedule(cipherSuite: cipherSuite)
            let psk = keySchedule.deriveResumptionPSK(
                resumptionMasterSecret: resumptionMasterSecret,
                ticketNonce: ticket.ticketNonce
            )

            return SessionTicketData(
                ticket: ticket.ticket,
                resumptionPSK: psk.withUnsafeBytes { Data($0) },
                maxEarlyDataSize: maxEarlyDataSize,
                ticketAgeAdd: ticket.ticketAgeAdd,
                receiveTime: createdAt,
                lifetime: ticket.ticketLifetime,
                cipherSuite: cipherSuite,
                serverName: serverIdentity,
                alpn: alpn
            )
        }
    }

    // MARK: - Initialization

    /// Creates a new client session cache
    /// - Parameter maxSessionsPerServer: Maximum sessions to store per server identity
    public init(maxSessionsPerServer: Int = 4) {
        self.maxSessionsPerServer = maxSessionsPerServer
    }

    // MARK: - Session Storage

    /// Stores a session for later resumption
    /// - Parameters:
    ///   - session: The session to store
    ///   - serverIdentity: The server identity (e.g., "example.com:443")
    public func store(session: CachedSession, for serverIdentity: String) {
        state.withLock { s in
            var sessions = s.sessions[serverIdentity] ?? []

            // Remove expired sessions
            sessions.removeAll { !$0.isValid }

            // Add new session
            sessions.append(session)

            // Keep only the most recent sessions
            if sessions.count > maxSessionsPerServer {
                sessions.removeFirst(sessions.count - maxSessionsPerServer)
            }

            s.sessions[serverIdentity] = sessions
        }
    }

    /// Stores a session ticket from a NewSessionTicket message
    /// - Parameters:
    ///   - ticket: The NewSessionTicket from the server
    ///   - resumptionMasterSecret: The resumption master secret from the handshake
    ///   - cipherSuite: The cipher suite used
    ///   - alpn: The negotiated ALPN (if any)
    ///   - serverIdentity: The server identity
    public func storeTicket(
        _ ticket: NewSessionTicket,
        resumptionMasterSecret: SymmetricKey,
        cipherSuite: CipherSuite,
        alpn: String?,
        serverIdentity: String
    ) {
        let session = CachedSession(
            ticket: ticket,
            resumptionMasterSecret: resumptionMasterSecret,
            cipherSuite: cipherSuite,
            alpn: alpn,
            serverIdentity: serverIdentity
        )
        store(session: session, for: serverIdentity)
    }

    // MARK: - Session Retrieval

    /// Retrieves a session for the given server
    /// - Parameter serverIdentity: The server identity
    /// - Returns: The most recent valid session, or nil if none available
    public func retrieve(for serverIdentity: String) -> CachedSession? {
        state.withLock { s in
            guard var sessions = s.sessions[serverIdentity] else {
                return nil
            }

            // Remove expired sessions
            sessions.removeAll { !$0.isValid }
            s.sessions[serverIdentity] = sessions

            // Return most recent session
            return sessions.last
        }
    }

    /// Retrieves all valid sessions for a server
    /// - Parameter serverIdentity: The server identity
    /// - Returns: All valid sessions, sorted by creation time (newest last)
    public func retrieveAll(for serverIdentity: String) -> [CachedSession] {
        state.withLock { s in
            guard var sessions = s.sessions[serverIdentity] else {
                return []
            }

            // Remove expired sessions
            sessions.removeAll { !$0.isValid }
            s.sessions[serverIdentity] = sessions

            return sessions
        }
    }

    /// Retrieves a session that supports early data
    /// - Parameter serverIdentity: The server identity
    /// - Returns: A session supporting early data, or nil if none available
    public func retrieveForEarlyData(for serverIdentity: String) -> CachedSession? {
        state.withLock { s in
            guard var sessions = s.sessions[serverIdentity] else {
                return nil
            }

            // Remove expired sessions
            sessions.removeAll { !$0.isValid }
            s.sessions[serverIdentity] = sessions

            // Find a session that supports early data
            return sessions.last { $0.supportsEarlyData }
        }
    }

    // MARK: - Session Removal

    /// Removes all sessions for a server
    /// - Parameter serverIdentity: The server identity
    public func remove(for serverIdentity: String) {
        _ = state.withLock { s in
            s.sessions.removeValue(forKey: serverIdentity)
        }
    }

    /// Removes a specific session
    /// - Parameters:
    ///   - ticketData: The ticket data to remove
    ///   - serverIdentity: The server identity
    public func removeSession(withTicket ticketData: Data, for serverIdentity: String) {
        state.withLock { s in
            guard var sessions = s.sessions[serverIdentity] else {
                return
            }
            sessions.removeAll { $0.ticket.ticket == ticketData }
            s.sessions[serverIdentity] = sessions
        }
    }

    /// Removes all expired sessions
    public func purgeExpired() {
        state.withLock { s in
            for (server, sessions) in s.sessions {
                let valid = sessions.filter { $0.isValid }
                if valid.isEmpty {
                    s.sessions.removeValue(forKey: server)
                } else {
                    s.sessions[server] = valid
                }
            }
        }
    }

    /// Clears all cached sessions
    public func clear() {
        state.withLock { s in
            s.sessions.removeAll()
        }
    }

    // MARK: - Statistics

    /// Number of servers with cached sessions
    public var serverCount: Int {
        state.withLock { $0.sessions.count }
    }

    /// Total number of cached sessions
    public var sessionCount: Int {
        state.withLock { s in
            s.sessions.values.reduce(0) { $0 + $1.count }
        }
    }

    /// Whether a session exists for the given server
    public func hasSession(for serverIdentity: String) -> Bool {
        retrieve(for: serverIdentity) != nil
    }
}
