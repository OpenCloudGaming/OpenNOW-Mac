/// QUICConnectionHandler — Connection Migration
///
/// Extension containing connection migration-related functionality:
/// - Path validation (initiate, check, query)
/// - Connection ID lifecycle management
/// - Stateless reset handling

import Foundation
import QUICCore
import QUICCrypto

// MARK: - Connection Migration API

extension QUICConnectionHandler {

    /// Initiates path validation for a new network path
    /// - Parameter path: The network path to validate
    /// - Returns: PATH_CHALLENGE frame to send
    package func initiatePathValidation(for path: NetworkPath) -> Frame {
        pathValidationManager.createChallengeFrame(for: path)
    }

    /// Checks if a network path is validated
    /// - Parameter path: The path to check
    /// - Returns: True if the path has been validated
    package func isPathValidated(_ path: NetworkPath) -> Bool {
        pathValidationManager.isValidated(path)
    }

    /// Gets all validated network paths
    package var validatedPaths: Set<NetworkPath> {
        pathValidationManager.validatedPaths
    }

    /// Checks for path validation timeouts
    /// - Returns: Paths that failed validation due to timeout
    package func checkPathValidationTimeouts() -> [NetworkPath] {
        pathValidationManager.checkTimeouts()
    }

    // MARK: - Connection ID Management

    /// Issues a new connection ID to the peer
    /// - Parameter length: Length of the connection ID (default 8)
    /// - Returns: NEW_CONNECTION_ID frame to send
    /// - Throws: If the length is invalid or frame creation fails
    package func issueNewConnectionID(length: Int = 8) throws -> NewConnectionIDFrame {
        try connectionIDManager.issueNewConnectionID(length: length)
    }

    /// Gets the current active peer connection ID for sending
    package var activePeerConnectionID: ConnectionID? {
        connectionIDManager.activePeerConnectionID
    }

    /// Switches to a different peer connection ID
    /// - Parameter sequenceNumber: The sequence number of the CID to use
    /// - Returns: True if switch was successful
    package func switchToConnectionID(sequenceNumber: UInt64) -> Bool {
        connectionIDManager.switchToConnectionID(sequenceNumber: sequenceNumber)
    }

    /// Gets all available peer connection IDs
    package var availablePeerCIDs: [ConnectionIDManager.PeerConnectionID] {
        connectionIDManager.availablePeerCIDs
    }

    /// Retires a peer connection ID
    /// - Parameter sequenceNumber: The sequence number to retire
    /// - Returns: RETIRE_CONNECTION_ID frame to send, or nil if not found
    package func retirePeerConnectionID(sequenceNumber: UInt64) -> Frame? {
        connectionIDManager.retirePeerConnectionID(sequenceNumber: sequenceNumber)
    }

    // MARK: - Stateless Reset

    /// Checks if a packet is a stateless reset
    /// - Parameter data: The received packet data
    /// - Returns: True if this is a stateless reset packet
    package func isStatelessReset(_ data: Data) -> Bool {
        statelessResetManager.isStatelessReset(data)
    }

    /// Creates a stateless reset packet
    /// - Parameter connectionID: The connection ID being reset
    /// - Returns: The encoded stateless reset packet, or nil if no token exists
    package func createStatelessReset(for connectionID: ConnectionID) -> Data? {
        statelessResetManager.createStatelessReset(for: connectionID)
    }
}