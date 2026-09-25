/// ECN (Explicit Congestion Notification) Support (RFC 9000 Section 13.4)
///
/// ECN allows routers to signal congestion without dropping packets.
/// QUIC endpoints track ECN counts and report them in ACK frames.

import Foundation
import Synchronization
import QUICCore

// MARK: - ECN Codepoint

/// ECN codepoint values (RFC 3168)
public enum ECNCodepoint: UInt8, Sendable {
    /// Not-ECT: No ECN-capable transport
    case notECT = 0x00

    /// ECT(0): ECN-Capable Transport
    case ect0 = 0x02

    /// ECT(1): ECN-Capable Transport (alternate)
    case ect1 = 0x01

    /// CE: Congestion Experienced
    case ce = 0x03

    /// Whether this codepoint indicates congestion
    public var isCongestionExperienced: Bool {
        self == .ce
    }

    /// Whether this is an ECN-capable codepoint
    public var isECNCapable: Bool {
        self == .ect0 || self == .ect1 || self == .ce
    }
}

// MARK: - ECN Counts

/// ECN counts tracked per packet number space (mutable tracking state).
///
/// This type is distinct from `QUICCore.ECNCounts` which represents the
/// immutable wire format used in ACK frames. `ECNCountState` is the
/// mutable bookkeeping type used by `ECNManager` to track counts over time.
public struct ECNCountState: Sendable, Equatable {
    /// Count of packets marked ECT(0)
    public var ect0Count: UInt64 = 0

    /// Count of packets marked ECT(1)
    public var ect1Count: UInt64 = 0

    /// Count of packets marked CE (Congestion Experienced)
    public var ceCount: UInt64 = 0

    public init(ect0: UInt64 = 0, ect1: UInt64 = 0, ce: UInt64 = 0) {
        self.ect0Count = ect0
        self.ect1Count = ect1
        self.ceCount = ce
    }

    /// Total ECN-capable packets
    public var totalECN: UInt64 {
        ect0Count + ect1Count + ceCount
    }

    /// Records a received packet's ECN codepoint
    public mutating func record(_ codepoint: ECNCodepoint) {
        switch codepoint {
        case .notECT:
            break  // Not ECN-capable
        case .ect0:
            ect0Count += 1
        case .ect1:
            ect1Count += 1
        case .ce:
            ceCount += 1
        }
    }
}

// MARK: - ECN Validation State

/// Tracks ECN validation state for a path
///
/// RFC 9000 Section 13.4.2: ECN validation ensures the path
/// supports ECN correctly before relying on ECN feedback.
public enum ECNValidationState: Sendable {
    /// ECN validation not started
    case unknown

    /// Testing ECN capability
    case testing

    /// ECN is known to work on this path
    case capable

    /// ECN failed validation on this path
    case failed
}

// MARK: - ECN Manager

/// Manages ECN state for a connection
///
/// Tracks ECN counts, validates ECN support on paths,
/// and detects congestion signals.
public final class ECNManager: Sendable {
    private let state: Mutex<ECNState>

    private struct ECNState: Sendable {
        /// ECN counts received from peer (per packet number space)
        var peerCounts: [EncryptionLevel: ECNCountState] = [:]

        /// ECN counts for packets we've received
        var localCounts: [EncryptionLevel: ECNCountState] = [:]

        /// Validation state
        var validationState: ECNValidationState = .unknown

        /// Number of ECT packets sent during validation
        var testingPacketsSent: UInt64 = 0

        /// Number of ECT packets acknowledged during validation
        var testingPacketsAcked: UInt64 = 0

        /// Whether to mark outgoing packets with ECT
        var markOutgoing: Bool = false

        /// The codepoint to use for outgoing packets
        var outgoingCodepoint: ECNCodepoint = .ect0
    }

    public init() {
        self.state = Mutex(ECNState())
    }

    // MARK: - Outgoing Packets

    /// Gets the ECN codepoint to use for an outgoing packet
    ///
    /// - Returns: The codepoint to mark on the packet, or notECT if ECN is disabled
    public func outgoingCodepoint() -> ECNCodepoint {
        state.withLock { s in
            guard s.markOutgoing else { return .notECT }
            return s.outgoingCodepoint
        }
    }

    /// Enables ECN marking on outgoing packets
    ///
    /// Call this to start ECN validation on a new path.
    public func enableECN() {
        state.withLock { s in
            s.markOutgoing = true
            s.validationState = .testing
            s.testingPacketsSent = 0
            s.testingPacketsAcked = 0
        }
    }

    /// Disables ECN marking on outgoing packets
    public func disableECN() {
        state.withLock { s in
            s.markOutgoing = false
            s.validationState = .failed
        }
    }

    // MARK: - Incoming Packets

    /// Records ECN codepoint from a received packet
    ///
    /// - Parameters:
    ///   - codepoint: The ECN codepoint from the IP header
    ///   - level: The encryption level of the packet
    public func recordIncoming(_ codepoint: ECNCodepoint, level: EncryptionLevel) {
        state.withLock { s in
            s.localCounts[level, default: ECNCountState()].record(codepoint)
        }
    }

    /// Gets ECN counts for reporting in ACK frames
    ///
    /// - Parameter level: The encryption level
    /// - Returns: ECN counts to include in ACK frame, or nil if no ECN packets received
    public func countsForACK(level: EncryptionLevel) -> ECNCountState? {
        state.withLock { s in
            guard let counts = s.localCounts[level], counts.totalECN > 0 else {
                return nil
            }
            return counts
        }
    }

    // MARK: - Processing ACK Feedback

    /// Processes ECN counts from an ACK frame
    ///
    /// RFC 9000 Section 13.4.2.1: Endpoints validate ECN feedback
    /// to ensure the path correctly echoes ECN marks.
    ///
    /// - Parameters:
    ///   - counts: ECN counts from the ACK frame
    ///   - level: The encryption level
    /// - Returns: Number of newly detected CE marks (congestion signals)
    public func processACKFeedback(_ counts: ECNCountState, level: EncryptionLevel) -> UInt64 {
        state.withLock { s in
            let previousCounts = s.peerCounts[level] ?? ECNCountState()

            // Validate ECN counts (must not decrease)
            guard counts.ect0Count >= previousCounts.ect0Count,
                  counts.ect1Count >= previousCounts.ect1Count,
                  counts.ceCount >= previousCounts.ceCount else {
                // Invalid feedback - ECN counts decreased
                s.validationState = .failed
                s.markOutgoing = false
                return 0
            }

            // Calculate newly reported CE marks
            let newCEMarks = counts.ceCount - previousCounts.ceCount

            // Update stored counts
            s.peerCounts[level] = counts

            // Update validation state if testing
            if s.validationState == .testing {
                let totalAcked = counts.ect0Count + counts.ect1Count + counts.ceCount
                s.testingPacketsAcked = totalAcked

                // Validation succeeds after receiving some ECN feedback
                if totalAcked >= 10 {
                    s.validationState = .capable
                }
            }

            return newCEMarks
        }
    }

    // MARK: - State Queries

    /// Current ECN validation state
    public var validationState: ECNValidationState {
        state.withLock { $0.validationState }
    }

    /// Whether ECN is currently enabled
    public var isEnabled: Bool {
        state.withLock { $0.markOutgoing }
    }

    /// Whether ECN validation has succeeded
    public var isValidated: Bool {
        state.withLock { $0.validationState == .capable }
    }
}
