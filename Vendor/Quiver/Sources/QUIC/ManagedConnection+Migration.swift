/// ManagedConnection — TLS, Migration, Path Validation & CID Management
///
/// Extension covering connection migration (RFC 9000 Section 9),
/// path validation, TLS provider access, and connection ID management.

import Foundation
import Logging
import Synchronization
import QUICCore
import QUICCrypto
import QUICConnection
import QUICStream
import QUICRecovery

// MARK: - Connection IDs

extension ManagedConnection {
    /// The TLS provider used for this connection.
    ///
    /// Provides access to the underlying TLS 1.3 provider for custom
    /// authentication schemes (e.g., certificate-based peer identity extraction).
    public var underlyingTLSProvider: any TLS13Provider {
        tlsProvider
    }

    /// Whether 0-RTT early data was accepted by the server.
    ///
    /// Only meaningful after handshake completes. Before that, always `false`.
    /// The value is propagated from the TLS provider's `is0RTTAccepted` once
    /// the server's EncryptedExtensions has been processed.
    public var is0RTTAccepted: Bool {
        state.withLock { $0.is0RTTAccepted }
    }

    // MARK: - Handshake Completion

    /// Suspends the caller until the QUIC handshake completes.
    ///
    /// - If the handshake is already complete (`.established`), returns
    ///   immediately.
    /// - If the connection is already closed/closing, throws
    ///   ``ManagedConnectionError/connectionClosed``.
    /// - Otherwise, the caller is suspended until one of the above
    ///   conditions is reached.
    ///
    /// This replaces the previous poll-based `while !isEstablished` loop
    /// in `QUICEndpoint.dial()` with an efficient continuation-based wait.
    ///
    /// ## Thread-Safety
    /// Multiple concurrent callers are supported; all are resumed together
    /// when the handshake completes.
    public func waitForHandshake() async throws {
        // We need a stable identity so the cancellation handler can
        // locate and remove the exact continuation that was parked.
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                state.withLock { s in
                    // Re-check cancellation under the lock so we never
                    // park a continuation that is already doomed.
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    switch s.handshakeState {
                    case .established:
                        // Already done — resume immediately
                        continuation.resume()
                    case .closed, .closing:
                        // Connection already torn down
                        continuation.resume(throwing: ManagedConnectionError.connectionClosed)
                    default:
                        // Handshake still in progress — park the continuation
                        s.handshakeCompletionContinuations.append((id: id, continuation: continuation))
                    }
                }
            }
        } onCancel: {
            // Task was cancelled (e.g. dial() timeout).
            // Remove our continuation from the list and resume it with
            // CancellationError so the structured-concurrency task group
            // can finish instead of hanging forever.
            let removed: CheckedContinuation<Void, any Error>? = state.withLock { s in
                if let idx = s.handshakeCompletionContinuations.firstIndex(where: { $0.id == id }) {
                    let entry = s.handshakeCompletionContinuations.remove(at: idx)
                    return entry.continuation
                }
                return nil
            }
            removed?.resume(throwing: CancellationError())
        }
    }

    /// Source connection ID
    public var sourceConnectionID: ConnectionID {
        state.withLock { $0.sourceConnectionID }
    }

    /// Destination connection ID
    public var destinationConnectionID: ConnectionID {
        state.withLock { $0.destinationConnectionID }
    }

    /// Current handshake state
    public var handshakeState: HandshakeState {
        state.withLock { $0.handshakeState }
    }

    /// Connection role
    public var role: ConnectionRole {
        state.withLock { $0.role }
    }

    // Note: Connection ID tracking is now managed by ConnectionRouter.
    // Use router.registeredConnectionIDs(for:) to query CIDs for a connection.

    // MARK: - Amplification Limit

    /// Whether the connection is blocked by the anti-amplification limit
    ///
    /// When blocked, the server must wait for more data from the client
    /// before it can send additional packets.
    public var isAmplificationBlocked: Bool {
        amplificationLimiter.isBlocked
    }

    /// Whether the client's address has been validated
    ///
    /// Address validation lifts the anti-amplification limit.
    public var isAddressValidated: Bool {
        amplificationLimiter.isAddressValidated
    }

    // MARK: - Version Negotiation

    /// Whether we have received and successfully processed any valid packet
    ///
    /// RFC 9000 Section 6.2: A client MUST discard any Version Negotiation packet
    /// if it has received and successfully processed any other packet.
    public var hasReceivedValidPacket: Bool {
        get async { state.withLock { $0.hasReceivedValidPacket } }
    }

    /// Retry the connection with a different QUIC version
    ///
    /// Called when a Version Negotiation packet is received offering a version we support.
    /// This resets the connection state and restarts the handshake with the new version.
    ///
    /// - Parameter version: The new version to use
    public func retryWithVersion(_ version: QUICVersion) async throws {
        // This is a complex operation that requires:
        // 1. Resetting TLS state
        // 2. Regenerating Initial keys with the new version
        // 3. Rebuilding and resending ClientHello
        // For now, throw an error indicating manual reconnection is needed
        throw QUICVersionError.versionNegotiationReceived(
            offeredVersions: [version]
        )
    }

    // MARK: - Connection Migration (RFC 9000 Section 9)

    /// The current remote address (may differ from initial address after migration)
    public var currentRemoteAddress: SocketAddress {
        state.withLock { $0.currentRemoteAddress ?? remoteAddress }
    }

    /// Whether the current path has been validated
    public var isPathValidated: Bool {
        state.withLock { $0.pathValidated }
    }

    /// Handles a packet received from a different address (potential migration)
    ///
    /// RFC 9000 Section 9.3: When receiving a packet from a new peer address,
    /// the endpoint MUST perform path validation if it has not previously done so.
    ///
    /// - Parameters:
    ///   - packet: The received packet data
    ///   - newAddress: The new remote address from which the packet was received
    /// - Returns: Packets to send in response (may include PATH_CHALLENGE)
    /// - Throws: `MigrationError` if migration is not allowed
    public func handleAddressChange(
        packet: Data,
        newAddress: SocketAddress
    ) async throws -> [Data] {
        // Check if migration is allowed
        let (allowMigration, currentAddress) = state.withLock { s in
            (
                !s.peerDisableActiveMigration,
                s.currentRemoteAddress ?? remoteAddress
            )
        }

        // If address hasn't changed, process normally
        if newAddress == currentAddress {
            return try await processIncomingPacket(packet)
        }

        // Check if peer allows migration
        guard allowMigration else {
            throw MigrationError.migrationDisabled
        }

        // Update address and mark path as not validated
        state.withLock { s in
            s.currentRemoteAddress = newAddress
            s.pathValidated = false
        }

        // For servers: reset anti-amplification limit for new path (RFC 9000 Section 9.3)
        // Note: Address validation needs to be completed via PATH_CHALLENGE/RESPONSE
        // The amplification limiter will be reset once path validation completes

        // Record bytes received for anti-amplification
        amplificationLimiter.recordBytesReceived(UInt64(packet.count))

        // Process the packet
        var responses = try await processIncomingPacket(packet)

        // Initiate path validation by sending PATH_CHALLENGE
        let path = NetworkPath(
            localAddress: localAddress?.description ?? "",
            remoteAddress: newAddress.description
        )
        let challengeData = pathValidationManager.startValidation(for: path)

        // Queue PATH_CHALLENGE to be sent with next packet
        state.withLock { s in
            s.pendingPathChallenges.append(challengeData)
        }

        // Generate a packet with PATH_CHALLENGE if we can
        if let challengePacket = try createPathChallengePacket(challengeData: challengeData) {
            responses.append(challengePacket)
        }

        return responses
    }

    /// Handles a PATH_CHALLENGE frame
    ///
    /// RFC 9000 Section 9.3.2: An endpoint MUST respond immediately to a
    /// PATH_CHALLENGE frame with a PATH_RESPONSE frame containing the same data.
    ///
    /// - Parameter data: The 8-byte challenge data
    /// - Returns: PATH_RESPONSE packet to send
    public func handlePathChallenge(_ data: Data) throws -> Data? {
        // Generate PATH_RESPONSE
        _ = pathValidationManager.handleChallenge(data)

        // Queue response to be sent
        state.withLock { s in
            s.pendingPathResponses.append(data)
        }

        // Create packet with PATH_RESPONSE
        return try createPathResponsePacket(data: data)
    }

    /// Handles a PATH_RESPONSE frame
    ///
    /// RFC 9000 Section 9.3.3: Receipt of a PATH_RESPONSE frame indicates
    /// that the path is valid.
    ///
    /// - Parameter data: The 8-byte response data
    /// - Returns: Whether this completes path validation
    public func handlePathResponse(_ data: Data) -> Bool {
        if let _ = pathValidationManager.handleResponse(data) {
            // Path validated successfully
            state.withLock { s in
                s.pathValidated = true
            }
            return true
        }
        return false
    }

    /// Sets whether peer allows active migration (from transport parameters)
    ///
    /// Called when processing peer's transport parameters.
    public func setPeerDisableActiveMigration(_ disabled: Bool) {
        state.withLock { s in
            s.peerDisableActiveMigration = disabled
        }
    }

    /// Gets pending PATH_CHALLENGE frames to include in next packet
    public func getPendingPathChallenges() -> [Data] {
        state.withLock { s in
            let challenges = s.pendingPathChallenges
            s.pendingPathChallenges.removeAll(keepingCapacity: true)
            return challenges
        }
    }

    /// Gets pending PATH_RESPONSE frames to include in next packet
    public func getPendingPathResponses() -> [Data] {
        state.withLock { s in
            let responses = s.pendingPathResponses
            s.pendingPathResponses.removeAll(keepingCapacity: true)
            return responses
        }
    }

    // MARK: - Migration Private Helpers

    /// Creates a packet containing a PATH_CHALLENGE frame
    ///
    /// - Note: This queues the frame to be sent with the next outbound packet.
    ///   The actual packet creation happens via the normal packet sending mechanism.
    private func createPathChallengePacket(challengeData: Data) throws -> Data? {
        // PATH_CHALLENGE will be included in the next 1-RTT packet
        // Queue the frame via the handler
        handler.queueFrame(.pathChallenge(challengeData), level: .application)

        // Return nil - the frame will be sent with normal packet flow
        // This avoids duplicating packet creation logic
        return nil
    }

    /// Creates a packet containing a PATH_RESPONSE frame
    ///
    /// - Note: This queues the frame to be sent with the next outbound packet.
    private func createPathResponsePacket(data: Data) throws -> Data? {
        // PATH_RESPONSE must be sent immediately (RFC 9000 Section 8.2.2)
        // Queue the frame via the handler
        handler.queueFrame(.pathResponse(data), level: .application)

        // Return nil - the frame will be sent with normal packet flow
        return nil
    }
}