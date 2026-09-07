import Foundation

/// Which of the three transports a signaling connection rides.
public enum OPNRemoteCoOpTransportKind: String, Codable, Equatable, Sendable {
    case embedded
    case native
    case hosted
}

/// An opaque handle identifying a signaling connection across all three transports. The connection
/// identifier is a string because the hosted transport uses Ably's `connectionId`, while the
/// socket transports use a `UUID`.
public struct OPNRemoteCoOpConnectionHandle: Equatable, Hashable, Sendable {
    public let transport: OPNRemoteCoOpTransportKind
    public let connectionID: String

    public init(transport: OPNRemoteCoOpTransportKind, connectionID: String) {
        self.transport = transport
        self.connectionID = connectionID
    }

    public init(transport: OPNRemoteCoOpTransportKind, connectionID: UUID) {
        self.transport = transport
        self.connectionID = connectionID.uuidString
    }
}

/// A thread-safe registry of which signaling connection owns each participant, and the reconnect
/// token each accepted participant must present to reclaim an already-bound identity.
///
/// The three transports all consult this registry through the synchronous
/// `OPNRemoteCoOpGuestMessageGate`, so mutations and lookups must complete without `await`.
/// A single `NSLock` protects all state.
public final class OPNRemoteCoOpParticipantOwnership: @unchecked Sendable {
    public enum ClaimResult: Equatable {
        /// This connection now owns the participant; the message should be delivered.
        case claimed
        /// This connection already owns the participant; the message should be delivered.
        case deliver
        /// The participant is owned by another live connection. The claimant should be dropped.
        case alreadyBound
        /// This connection already owns a different participant and is trying to claim another.
        case alreadyOwnsOtherParticipant
    }

    private let lock = NSLock()
    private var participantToConnection: [UUID: OPNRemoteCoOpConnectionHandle] = [:]
    private var connectionToParticipant: [OPNRemoteCoOpConnectionHandle: UUID] = [:]
    private var reconnectTokens: [UUID: String] = [:]

    public init() {}

    /// Attempt to bind `participantID` to `handle`. Thread-safe.
    @discardableResult
    public func claim(participantID: UUID, for handle: OPNRemoteCoOpConnectionHandle) -> ClaimResult {
        lock.lock()
        defer { lock.unlock() }
        if let owned = connectionToParticipant[handle] {
            if owned == participantID { return .deliver }
            return .alreadyOwnsOtherParticipant
        }
        if let owner = participantToConnection[participantID], owner != handle {
            return .alreadyBound
        }
        participantToConnection[participantID] = handle
        connectionToParticipant[handle] = participantID
        return .claimed
    }

    /// Remove any binding held by `handle`. Thread-safe.
    public func release(_ handle: OPNRemoteCoOpConnectionHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard let participantID = connectionToParticipant.removeValue(forKey: handle) else { return }
        if participantToConnection[participantID] == handle {
            participantToConnection[participantID] = nil
        }
    }

    /// The participant owned by `handle`, if any. Thread-safe.
    public func participantOwnedBy(_ handle: OPNRemoteCoOpConnectionHandle) -> UUID? {
        lock.withLock { connectionToParticipant[handle] }
    }

    /// The connection that owns `participantID`, if any. Thread-safe.
    public func owner(of participantID: UUID) -> OPNRemoteCoOpConnectionHandle? {
        lock.withLock { participantToConnection[participantID] }
    }

    /// Store the reconnect token for a participant. Thread-safe.
    public func setReconnectToken(_ token: String, for participantID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        reconnectTokens[participantID] = token
    }

    /// Remove the reconnect token for a participant. Thread-safe.
    public func removeReconnectToken(for participantID: UUID) {
        lock.lock()
        defer { lock.unlock() }
            reconnectTokens[participantID] = nil
    }

    /// The reconnect token for a participant, if any. Thread-safe.
    public func reconnectToken(for participantID: UUID) -> String? {
        lock.withLock { reconnectTokens[participantID]?.nilIfEmpty }
    }

    /// Drop every binding and token. Thread-safe.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        participantToConnection.removeAll()
        connectionToParticipant.removeAll()
        reconnectTokens.removeAll()
    }

    /// Called when a participant is removed so the registry no longer considers it bound. Thread-safe.
    public func removeParticipant(_ participantID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        reconnectTokens[participantID] = nil
        guard let handle = participantToConnection.removeValue(forKey: participantID) else { return }
        if connectionToParticipant[handle] == participantID {
            connectionToParticipant[handle] = nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
