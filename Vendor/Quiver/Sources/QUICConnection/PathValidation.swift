/// Path Validation for Connection Migration (RFC 9000 Section 9.3)
///
/// Path validation is used to verify reachability after a change in address.
/// An endpoint validates a path by sending a PATH_CHALLENGE frame and receiving
/// a PATH_RESPONSE frame containing the same data.

import Foundation
import Synchronization
import QUICCore
import Crypto
// MARK: - Path Validation State

/// State of a path validation attempt
public enum PathValidationState: Sendable {
    /// Validation not started
    case initial

    /// Challenge sent, waiting for response
    case pending(challengeData: Data, sentAt: ContinuousClock.Instant)

    /// Path validated successfully
    case validated(at: ContinuousClock.Instant)

    /// Validation failed (timeout or other error)
    case failed(reason: String)
}

/// Represents a network path (local + remote address pair)
public struct NetworkPath: Hashable, Sendable {
    public let localAddress: String
    public let remoteAddress: String

    public init(localAddress: String, remoteAddress: String) {
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
    }
}

// MARK: - Path Validation Manager

/// Manages path validation for connection migration
public final class PathValidationManager: Sendable {

    private let state = Mutex<ValidationState>(ValidationState())

    private struct ValidationState: Sendable {
        /// Pending path validations (path -> validation state)
        var pendingValidations: [NetworkPath: PathValidationState] = [:]

        /// Challenge data we've sent (for matching responses)
        var pendingChallenges: [Data: NetworkPath] = [:]

        /// Successfully validated paths
        var validatedPaths: Set<NetworkPath> = []

        /// Challenges received that need responses
        var pendingResponses: [Data] = []
    }

    /// Timeout for path validation (RFC 9000 recommends 3 * PTO)
    public let validationTimeout: Duration

    // MARK: - Initialization

    public init(validationTimeout: Duration = .seconds(3)) {
        self.validationTimeout = validationTimeout
    }

    // MARK: - Initiating Validation

    /// Starts path validation for a new path
    /// - Parameter path: The network path to validate
    /// - Returns: PATH_CHALLENGE frame data (8 bytes random)
    public func startValidation(for path: NetworkPath) -> Data {
        let challengeData = generateChallengeData()

        state.withLock { s in
            s.pendingValidations[path] = .pending(
                challengeData: challengeData,
                sentAt: .now
            )
            s.pendingChallenges[challengeData] = path
        }

        return challengeData
    }

    /// Generates a PATH_CHALLENGE frame for a path
    /// - Parameter path: The path to validate
    /// - Returns: The PATH_CHALLENGE frame
    public func createChallengeFrame(for path: NetworkPath) -> Frame {
        let data = startValidation(for: path)
        return .pathChallenge(data)
    }

    // MARK: - Processing Received Frames

    /// Processes a received PATH_CHALLENGE
    /// - Parameter data: The 8-byte challenge data
    /// - Returns: PATH_RESPONSE frame to send back
    public func handleChallenge(_ data: Data) -> Frame {
        // RFC 9000: MUST respond with PATH_RESPONSE containing identical data
        state.withLock { s in
            s.pendingResponses.append(data)
        }
        return .pathResponse(data)
    }

    /// Processes a received PATH_RESPONSE
    /// - Parameter data: The 8-byte response data
    /// - Returns: The validated path if this completes a validation, nil otherwise
    public func handleResponse(_ data: Data) -> NetworkPath? {
        return state.withLock { s in
            guard let path = s.pendingChallenges.removeValue(forKey: data) else {
                // Response doesn't match any pending challenge
                return nil
            }

            // Path validated successfully
            s.pendingValidations[path] = .validated(at: .now)
            s.validatedPaths.insert(path)

            return path
        }
    }

    // MARK: - Query State

    /// Checks if a path is validated
    public func isValidated(_ path: NetworkPath) -> Bool {
        state.withLock { s in
            s.validatedPaths.contains(path)
        }
    }

    /// Gets the validation state for a path
    public func validationState(for path: NetworkPath) -> PathValidationState? {
        state.withLock { s in
            s.pendingValidations[path]
        }
    }

    /// Gets all validated paths
    public var validatedPaths: Set<NetworkPath> {
        state.withLock { $0.validatedPaths }
    }

    /// Gets pending responses (challenges we received but haven't responded to)
    public func getPendingResponses() -> [Data] {
        state.withLock { s in
            let responses = s.pendingResponses
            s.pendingResponses.removeAll()
            return responses
        }
    }

    // MARK: - Timeout Handling

    /// Checks for timed-out validations and marks them as failed
    /// - Returns: Paths that failed due to timeout
    public func checkTimeouts() -> [NetworkPath] {
        let now = ContinuousClock.now
        var failedPaths: [NetworkPath] = []

        state.withLock { s in
            for (path, validationState) in s.pendingValidations {
                if case .pending(let data, let sentAt) = validationState {
                    if now - sentAt > validationTimeout {
                        s.pendingValidations[path] = .failed(reason: "timeout")
                        s.pendingChallenges.removeValue(forKey: data)
                        failedPaths.append(path)
                    }
                }
            }
        }

        return failedPaths
    }

    /// Retries validation for a path that timed out
    /// - Parameter path: The path to retry
    /// - Returns: New challenge data, or nil if path wasn't in failed state
    public func retryValidation(for path: NetworkPath) -> Data? {
        return state.withLock { s in
            guard let currentState = s.pendingValidations[path],
                  case .failed = currentState else {
                return nil
            }

            let challengeData = generateChallengeData()
            s.pendingValidations[path] = .pending(
                challengeData: challengeData,
                sentAt: .now
            )
            s.pendingChallenges[challengeData] = path

            return challengeData
        }
    }

    // MARK: - Private Helpers

    /// Generates random 8-byte challenge data
    private func generateChallengeData() -> Data {
        // 8 bytes (64 bits) using Swift Crypto (cross-platform)
        SymmetricKey(size: SymmetricKeySize(bitCount: 64)).withUnsafeBytes { Data($0) }
    }
}

// MARK: - Connection ID Manager

/// Manages connection ID lifecycle for connection migration
public final class ConnectionIDManager: Sendable {

    private let state = Mutex<CIDState>(CIDState())

    private struct CIDState: Sendable {
        /// Our issued connection IDs (sequence number -> CID info)
        var issuedCIDs: [UInt64: IssuedConnectionID] = [:]

        /// Next sequence number for issuing new CIDs
        var nextSequenceNumber: UInt64 = 0

        /// Peer's connection IDs we can use
        var peerCIDs: [UInt64: PeerConnectionID] = [:]

        /// Current active peer CID (for sending)
        var activePeerCID: ConnectionID?

        /// Retired sequence numbers
        var retiredSequences: Set<UInt64> = []
    }

    /// Info about a CID we issued
    public struct IssuedConnectionID: Sendable {
        public let connectionID: ConnectionID
        public let sequenceNumber: UInt64
        public let statelessResetToken: Data
        public let issuedAt: ContinuousClock.Instant
        public var isRetired: Bool
    }

    /// Info about a peer's CID
    public struct PeerConnectionID: Sendable {
        public let connectionID: ConnectionID
        public let sequenceNumber: UInt64
        public let statelessResetToken: Data
        public let receivedAt: ContinuousClock.Instant
    }

    /// Maximum number of active CIDs (from transport parameters)
    public let activeConnectionIDLimit: UInt64

    // MARK: - Initialization

    public init(activeConnectionIDLimit: UInt64 = 2) {
        self.activeConnectionIDLimit = activeConnectionIDLimit
    }

    // MARK: - Issuing Connection IDs

    /// Issues a new connection ID
    /// - Parameter length: Length of the CID (0-20 bytes, default 8)
    /// - Returns: NEW_CONNECTION_ID frame to send
    /// - Throws: If the length is invalid or frame creation fails
    public func issueNewConnectionID(length: Int = 8) throws -> NewConnectionIDFrame {
        return try state.withLock { s in
            guard let cid = ConnectionID.random(length: length) else {
                throw ConnectionIDError.invalidLength(length)
            }
            let token = generateStatelessResetToken()
            let seq = s.nextSequenceNumber
            s.nextSequenceNumber += 1

            let issued = IssuedConnectionID(
                connectionID: cid,
                sequenceNumber: seq,
                statelessResetToken: token,
                issuedAt: .now,
                isRetired: false
            )
            s.issuedCIDs[seq] = issued

            return try NewConnectionIDFrame(
                sequenceNumber: seq,
                retirePriorTo: 0,
                connectionID: cid,
                statelessResetToken: token
            )
        }
    }

    /// Errors related to connection ID operations
    public enum ConnectionIDError: Error, Sendable {
        /// Invalid connection ID length
        case invalidLength(Int)
        /// Duplicate sequence number with different CID or token (RFC 9000 §5.1.1)
        case duplicateSequenceNumber(sequenceNumber: UInt64)
        /// Exceeded active_connection_id_limit
        case exceededConnectionIDLimit(limit: UInt64, current: Int)
    }

    /// Gets all active (non-retired) issued CIDs
    public var activeIssuedCIDs: [IssuedConnectionID] {
        state.withLock { s in
            s.issuedCIDs.values.filter { !$0.isRetired }
        }
    }

    // MARK: - Processing Peer CIDs

    /// Processes a NEW_CONNECTION_ID frame from peer
    /// - Parameter frame: The received frame
    /// - Throws: ConnectionIDError if validation fails
    public func handleNewConnectionID(_ frame: NewConnectionIDFrame) throws {
        try state.withLock { s in
            // RFC 9000 §5.1.1: Check for duplicate sequence number
            // If same sequence but different CID or token, it's a PROTOCOL_VIOLATION
            if let existing = s.peerCIDs[frame.sequenceNumber] {
                // If CID and token match exactly, just ignore the duplicate
                if existing.connectionID == frame.connectionID &&
                   existing.statelessResetToken == frame.statelessResetToken {
                    return  // Ignore exact duplicate
                }
                // Different CID or token with same sequence = PROTOCOL_VIOLATION
                throw ConnectionIDError.duplicateSequenceNumber(
                    sequenceNumber: frame.sequenceNumber
                )
            }

            // Retire CIDs as requested by retire_prior_to
            for seq in 0..<frame.retirePriorTo {
                s.peerCIDs.removeValue(forKey: seq)
                s.retiredSequences.insert(seq)
            }

            // RFC 9000 §5.1.1: Enforce active_connection_id_limit
            // Count active (non-retired) CIDs
            let activeCIDCount = s.peerCIDs.count
            if activeCIDCount >= Int(activeConnectionIDLimit) {
                // We're at or over the limit - peer is violating our limit
                throw ConnectionIDError.exceededConnectionIDLimit(
                    limit: activeConnectionIDLimit,
                    current: activeCIDCount + 1  // +1 for the new CID they're trying to add
                )
            }

            // Store new CID
            let peerCID = PeerConnectionID(
                connectionID: frame.connectionID,
                sequenceNumber: frame.sequenceNumber,
                statelessResetToken: frame.statelessResetToken,
                receivedAt: .now
            )
            s.peerCIDs[frame.sequenceNumber] = peerCID

            // Update active CID if needed
            if s.activePeerCID == nil {
                s.activePeerCID = frame.connectionID
            }
        }
    }

    /// Processes a RETIRE_CONNECTION_ID frame from peer
    /// - Parameter sequenceNumber: The sequence number to retire
    /// - Returns: The retired CID info, or nil if not found
    public func handleRetireConnectionID(_ sequenceNumber: UInt64) -> IssuedConnectionID? {
        return state.withLock { s in
            guard var cid = s.issuedCIDs[sequenceNumber] else {
                return nil
            }
            cid.isRetired = true
            s.issuedCIDs[sequenceNumber] = cid
            return cid
        }
    }

    // MARK: - Using Peer CIDs

    /// Gets the current active peer CID for sending
    public var activePeerConnectionID: ConnectionID? {
        state.withLock { $0.activePeerCID }
    }

    /// Switches to a different peer CID (for connection migration)
    /// - Parameter sequenceNumber: The sequence number of the CID to use
    /// - Returns: true if switch was successful
    public func switchToConnectionID(sequenceNumber: UInt64) -> Bool {
        return state.withLock { s in
            guard let peerCID = s.peerCIDs[sequenceNumber] else {
                return false
            }
            s.activePeerCID = peerCID.connectionID
            return true
        }
    }

    /// Gets all available peer CIDs
    public var availablePeerCIDs: [PeerConnectionID] {
        state.withLock { Array($0.peerCIDs.values) }
    }

    // MARK: - Retirement

    /// Retires a peer CID (we should send RETIRE_CONNECTION_ID)
    /// - Parameter sequenceNumber: The sequence number to retire
    /// - Returns: RETIRE_CONNECTION_ID frame, or nil if not found
    public func retirePeerConnectionID(sequenceNumber: UInt64) -> Frame? {
        return state.withLock { s in
            guard s.peerCIDs.removeValue(forKey: sequenceNumber) != nil else {
                return nil
            }
            s.retiredSequences.insert(sequenceNumber)
            return .retireConnectionID(sequenceNumber)
        }
    }

    // MARK: - Private Helpers

    /// Generates a random 16-byte stateless reset token
    private func generateStatelessResetToken() -> Data {
        // 16 bytes (128 bits) using Swift Crypto (cross-platform)
        SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
    }
}
