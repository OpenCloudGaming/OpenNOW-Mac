/// Managed Connection State Types
///
/// State types, enums, and error definitions used by ManagedConnection.
/// Extracted from ManagedConnection.swift for file size reduction.

import Foundation
import QUICCore
import QUICConnection

// MARK: - Handshake State

/// Connection handshake state
public enum HandshakeState: Sendable, Equatable {
    /// Connection not yet started
    case idle

    /// Client: Initial packet sent, waiting for server response
    /// Server: Not applicable
    case connecting

    /// Server: Initial received, handshake in progress
    /// Client: Handshake packets being exchanged
    case handshakeInProgress

    /// Handshake complete, connection established
    case established

    /// Connection is closing
    case closing

    /// Connection is closed
    case closed
}

// MARK: - Migration Errors

/// Connection migration errors
public enum MigrationError: Error, Sendable {
    /// Migration is disabled by peer (disable_active_migration transport parameter)
    case migrationDisabled

    /// Path validation failed
    case pathValidationFailed(reason: String)

    /// No active connection ID available for migration
    case noActiveConnectionID
}

// MARK: - Internal State

struct ManagedConnectionState: Sendable {
    var role: ConnectionRole
    var handshakeState: HandshakeState = .idle
    var sourceConnectionID: ConnectionID
    var destinationConnectionID: ConnectionID
    var negotiatedALPN: String? = nil
    /// Whether 0-RTT was attempted in this connection
    var is0RTTAttempted: Bool = false
    /// Whether 0-RTT was accepted by server (set after receiving EncryptedExtensions)
    var is0RTTAccepted: Bool = false
    /// Whether we have received and successfully processed any valid packet
    /// RFC 9000 Section 6.2: Used to discard late Version Negotiation packets
    var hasReceivedValidPacket: Bool = false

    // MARK: - Handshake Completion Signaling

    /// Continuations waiting for handshake completion.
    ///
    /// `waitForHandshake()` appends an `(id, continuation)` pair here when
    /// the handshake is still in progress.  The `id` allows the
    /// cancellation handler to locate and remove a specific entry.
    ///
    /// Once the handshake completes (server: `processTLSOutputs`, client:
    /// `completeHandshake`), or the connection is closed/shut down, all
    /// pending continuations are resumed.
    var handshakeCompletionContinuations: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    // MARK: - Retry State (RFC 9000 Section 8.1)

    /// Whether we have already processed a Retry packet
    /// RFC 9000: A client MUST accept and process at most one Retry packet
    var hasProcessedRetry: Bool = false

    /// Retry token received from server (to include in subsequent Initial packets)
    var retryToken: Data? = nil

    // MARK: - Connection Migration State

    /// Current remote address (may change during connection migration)
    var currentRemoteAddress: SocketAddress?

    /// Whether the current path has been validated (RFC 9000 Section 9.3)
    var pathValidated: Bool = true

    /// Whether peer allows active migration (from transport parameters)
    var peerDisableActiveMigration: Bool = false

    /// Pending PATH_CHALLENGE frames to send
    var pendingPathChallenges: [Data] = []

    /// Pending PATH_RESPONSE frames to send
    var pendingPathResponses: [Data] = []

    /// Pre-built PMTUD probe packets awaiting transmission.
    ///
    /// These are fully encrypted packets built by `sendPMTUProbe()` with
    /// padding to the probe target size.  They bypass the normal frame
    /// queue because their size exceeds `maxDatagramSize`.
    /// `generateOutboundPackets()` drains this queue first.
    var probePacketQueue: [Data] = []

    // MARK: - Send Signal State

    /// Continuation for send signal stream
    var sendSignalContinuation: AsyncStream<Void>.Continuation?

    /// Send signal stream (lazily initialized)
    var sendSignalStream: AsyncStream<Void>?

    /// Whether send signal has been shutdown
    var isSendSignalShutdown: Bool = false
}

// MARK: - Errors

/// Errors from ManagedConnection
public enum ManagedConnectionError: Error, Sendable {
    /// Connection is closed
    case connectionClosed

    /// Handshake not complete
    case handshakeNotComplete

    /// Stream not found
    case streamNotFound(UInt64)

    /// Invalid state
    case invalidState(String)
}