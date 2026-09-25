/// Datagram Packetization Layer PMTU Discovery (DPLPMTUD)
///
/// Implements RFC 8899 / RFC 9000 §14.3 for discovering the maximum
/// transmission unit (MTU) of the network path.
///
/// ## State Machine (RFC 8899 §5.2)
///
/// ```
/// ┌─────────┐
/// │ Disabled│──── enable() ────►┌──────┐
/// └─────────┘                   │ Base │
///                               └──┬───┘
///                     probe ack    │  probe sent
///                   ┌──────────────┤
///                   ▼              ▼
///              ┌─────────┐   ┌───────────┐
///              │SearchDone│◄──│ Searching │◄── probe timeout
///              └─────────┘   └───────────┘     (shrink range)
///                   │              │
///                   │         black hole
///                   │              │
///                   ▼              ▼
///              ┌─────────┐   ┌───────┐
///              │  (stay)  │   │ Error │── raise_timer ──► Base
///              └─────────┘   └───────┘
/// ```
///
/// ## Probing Mechanism
///
/// DPLPMTUD sends PATH_CHALLENGE frames padded to the probe size.
/// If the probe is acknowledged (PATH_RESPONSE received), the path
/// supports at least that size.  If not acknowledged within the
/// probe timeout (PTO-based), the probe size is too large.
///
/// A binary search narrows the range `[searchLow, searchHigh]` until
/// `searchHigh - searchLow <= searchGranularity`.
///
/// ## Integration Points
///
/// - **PathValidationManager**: DPLPMTUD probe frames are generated
///   via `createProbeFrame(size:)` and tracked separately from
///   migration PATH_CHALLENGEs.
/// - **PacketProcessor**: Probe packets must be padded to exactly the
///   probe size.  The caller uses `probeSize` when building the packet.
/// - **CongestionController**: After MTU changes, the congestion
///   window should be recalculated with the new `maxDatagramSize`.
/// - **PlatformSocket**: DF bit (`IP_DONTFRAG` / `IP_PMTUDISC_DO`)
///   must be set on the socket for probing to work.  Without DF,
///   routers may silently fragment and probes always "succeed".

import Foundation
import Synchronization
import QUICCore
import Crypto

// MARK: - DPLPMTUD State

/// DPLPMTUD state machine phases (RFC 8899 §5.2).
public enum PMTUState: Sendable, Equatable, CustomStringConvertible {
    /// PMTUD is disabled; use base MTU.
    case disabled

    /// Using the base (minimum) MTU. Ready to start searching.
    case base

    /// Actively probing with binary search.
    case searching

    /// Search converged; using the discovered MTU.
    case searchComplete

    /// Black hole detected; fell back to base MTU.
    /// Will re-enter `base` after `raiseTimer` expires.
    case error

    public var description: String {
        switch self {
        case .disabled:      return "disabled"
        case .base:          return "base"
        case .searching:     return "searching"
        case .searchComplete: return "searchComplete"
        case .error:         return "error"
        }
    }
}

// MARK: - Probe Tracking

/// Metadata for an in-flight PMTUD probe.
public struct PMTUProbe: Sendable {
    /// Size of the probe packet (bytes).
    public let size: Int

    /// The 8-byte challenge data used to identify the probe.
    public let challengeData: Data

    /// When the probe was sent.
    public let sentAt: ContinuousClock.Instant

    /// Number of times this probe size has been attempted.
    public let attempt: Int
}

// MARK: - Configuration

/// Tuning knobs for DPLPMTUD.
public struct PMTUConfiguration: Sendable {
    /// Base PLPMTU — the minimum MTU that all paths must support.
    /// RFC 9000 §14: 1200 for QUIC over IPv4/IPv6.
    public var basePLPMTU: Int

    /// Maximum PLPMTU to probe for.
    /// Typically the local interface MTU or a conservative ceiling (e.g. 1452).
    public var maxPLPMTU: Int

    /// Search stops when `searchHigh - searchLow <= granularity`.
    /// RFC 8899 recommends a small value; 20 bytes is practical.
    public var searchGranularity: Int

    /// Number of probe attempts before declaring the size too large.
    /// RFC 8899 §5.1.2 recommends `MAX_PROBES = 3`.
    public var maxProbes: Int

    /// Timeout for a single probe, typically `3 * PTO`.
    /// If not provided, a default of 3 seconds is used.
    public var probeTimeout: Duration

    /// Duration to wait in the `error` state before re-entering `base`.
    /// RFC 8899 §5.2 RAISE_TIMER: typically 600 seconds.
    public var raiseTimer: Duration

    /// Duration between periodic re-probes in `searchComplete` state
    /// to detect path MTU increases. RFC 8899 §5.2 PMTU_RAISE_TIMER.
    /// Set to `nil` to disable periodic re-probing.
    public var reprobeInterval: Duration?

    public init(
        basePLPMTU: Int = ProtocolLimits.minimumMaximumDatagramSize,
        maxPLPMTU: Int = 1452,
        searchGranularity: Int = 20,
        maxProbes: Int = 3,
        probeTimeout: Duration = .seconds(3),
        raiseTimer: Duration = .seconds(600),
        reprobeInterval: Duration? = .seconds(600)
    ) {
        precondition(basePLPMTU >= ProtocolLimits.minimumMaximumDatagramSize,
                     "basePLPMTU must be >= \(ProtocolLimits.minimumMaximumDatagramSize)")
        precondition(maxPLPMTU >= basePLPMTU,
                     "maxPLPMTU must be >= basePLPMTU")
        precondition(searchGranularity > 0,
                     "searchGranularity must be > 0")
        precondition(maxProbes >= 1,
                     "maxProbes must be >= 1")

        self.basePLPMTU = basePLPMTU
        self.maxPLPMTU = maxPLPMTU
        self.searchGranularity = searchGranularity
        self.maxProbes = maxProbes
        self.probeTimeout = probeTimeout
        self.raiseTimer = raiseTimer
        self.reprobeInterval = reprobeInterval
    }
}

// MARK: - DPLPMTUD Manager

/// Manages DPLPMTUD probing for a single QUIC connection.
///
/// Thread-safe via `Mutex`. All state transitions and probe tracking
/// are serialized.
///
/// ## Usage
///
/// ```swift
/// let pmtud = PMTUDiscoveryManager(configuration: PMTUConfiguration(
///     basePLPMTU: 1200,
///     maxPLPMTU: 1452
/// ))
///
/// // Enable after confirming DF bit is set on the socket
/// pmtud.enable()
///
/// // Periodically check if a probe should be sent
/// if let probeFrame = pmtud.generateProbe() {
///     // Send probeFrame.frame padded to probeFrame.packetSize
/// }
///
/// // When PATH_RESPONSE is received
/// if let newMTU = pmtud.probeAcknowledged(challengeData: responseData) {
///     // Update maxDatagramSize to newMTU
/// }
///
/// // On timer tick
/// pmtud.onTimerFired()
/// ```
public final class PMTUDiscoveryManager: Sendable {

    /// Current configuration.
    public let configuration: PMTUConfiguration

    // MARK: - Internal State

    private let _state: Mutex<InternalState>

    struct InternalState: Sendable {
        /// Current DPLPMTUD phase.
        var phase: PMTUState = .disabled

        /// The currently confirmed PLPMTU (largest size known to work).
        var currentPLPMTU: Int

        /// Lower bound of the binary search range (inclusive).
        /// Always a size known to work.
        var searchLow: Int

        /// Upper bound of the binary search range (inclusive).
        /// A size not yet confirmed.
        var searchHigh: Int

        /// The in-flight probe, if any.
        var activeProbe: PMTUProbe?

        /// How many consecutive failures at the current probe size.
        var probeAttempts: Int = 0

        /// When the error-state raise timer started.
        var errorEnteredAt: ContinuousClock.Instant?

        /// When the last successful search completed (for reprobe scheduling).
        var searchCompletedAt: ContinuousClock.Instant?

        /// History of confirmed MTU values (for diagnostics).
        var mtuHistory: [(size: Int, at: ContinuousClock.Instant)] = []
    }

    // MARK: - Initialization

    /// Creates a new DPLPMTUD manager.
    ///
    /// Starts in `disabled` state. Call `enable()` after confirming
    /// the socket has DF set (`PlatformSocketConstants.isDFSupported`).
    ///
    /// - Parameter configuration: Tuning parameters for probing.
    public init(configuration: PMTUConfiguration = PMTUConfiguration()) {
        self.configuration = configuration
        self._state = Mutex(InternalState(
            currentPLPMTU: configuration.basePLPMTU,
            searchLow: configuration.basePLPMTU,
            searchHigh: configuration.maxPLPMTU
        ))
    }

    // MARK: - State Queries

    /// Current DPLPMTUD state.
    public var state: PMTUState {
        _state.withLock { $0.phase }
    }

    /// The currently confirmed path MTU.
    ///
    /// This is the largest packet size known to be deliverable on the path.
    /// In `disabled` or `error` states, returns `basePLPMTU`.
    public var currentPLPMTU: Int {
        _state.withLock { $0.currentPLPMTU }
    }

    /// Whether a probe is currently in flight.
    public var isProbing: Bool {
        _state.withLock { $0.activeProbe != nil }
    }

    /// The confirmed MTU history for diagnostics.
    public var mtuHistory: [(size: Int, at: ContinuousClock.Instant)] {
        _state.withLock { $0.mtuHistory }
    }

    // MARK: - State Transitions

    /// Enables DPLPMTUD and transitions to `base` state.
    ///
    /// Call this after confirming the socket has the DF bit set.
    /// If already enabled, this is a no-op.
    public func enable() {
        _state.withLock { s in
            guard s.phase == .disabled else { return }
            s.phase = .base
            s.currentPLPMTU = configuration.basePLPMTU
            s.searchLow = configuration.basePLPMTU
            s.searchHigh = configuration.maxPLPMTU
            s.activeProbe = nil
            s.probeAttempts = 0
        }
    }

    /// Disables DPLPMTUD and reverts to base MTU.
    public func disable() {
        _state.withLock { s in
            s.phase = .disabled
            s.currentPLPMTU = configuration.basePLPMTU
            s.activeProbe = nil
            s.probeAttempts = 0
        }
    }

    /// Resets the search to `base` state (e.g. after path change).
    ///
    /// Called when connection migration occurs or when the path changes.
    /// The current MTU reverts to base until a new search confirms a
    /// larger value.
    public func resetForPathChange() {
        _state.withLock { s in
            guard s.phase != .disabled else { return }
            s.phase = .base
            s.currentPLPMTU = configuration.basePLPMTU
            s.searchLow = configuration.basePLPMTU
            s.searchHigh = configuration.maxPLPMTU
            s.activeProbe = nil
            s.probeAttempts = 0
        }
    }

    // MARK: - Probe Generation

    /// Result of `generateProbe()`.
    public struct ProbeRequest: Sendable {
        /// PATH_CHALLENGE frame to include in the probe packet.
        public let frame: Frame

        /// The total packet size the probe must be padded to.
        /// The caller should pad (PADDING frames) to reach this size.
        public let packetSize: Int

        /// The challenge data (for tracking).
        public let challengeData: Data
    }

    /// Generates a probe if one should be sent.
    ///
    /// Returns `nil` if:
    /// - DPLPMTUD is disabled
    /// - A probe is already in flight
    /// - The search has converged and reprobe interval hasn't elapsed
    /// - The state doesn't permit probing (e.g. `error` with raise timer active)
    ///
    /// - Returns: A `ProbeRequest` with the frame and target packet size,
    ///   or `nil` if no probe is needed.
    public func generateProbe() -> ProbeRequest? {
        return _state.withLock { s in
            guard s.activeProbe == nil else { return nil }

            switch s.phase {
            case .disabled:
                return nil

            case .base:
                // Start searching: first probe at the midpoint
                guard s.searchHigh - s.searchLow > configuration.searchGranularity else {
                    // Range too narrow — already at the best we can do
                    s.phase = .searchComplete
                    s.searchCompletedAt = .now
                    return nil
                }
                s.phase = .searching
                let probeSize = nextProbeSize(low: s.searchLow, high: s.searchHigh)
                return makeProbe(size: probeSize, state: &s)

            case .searching:
                // Continue binary search
                guard s.searchHigh - s.searchLow > configuration.searchGranularity else {
                    s.phase = .searchComplete
                    s.searchCompletedAt = .now
                    s.mtuHistory.append((size: s.currentPLPMTU, at: .now))
                    return nil
                }
                let probeSize = nextProbeSize(low: s.searchLow, high: s.searchHigh)
                return makeProbe(size: probeSize, state: &s)

            case .searchComplete:
                // Check if reprobe interval has elapsed
                guard let interval = configuration.reprobeInterval,
                      let completedAt = s.searchCompletedAt,
                      ContinuousClock.now - completedAt >= interval else {
                    return nil
                }
                // Re-probe: try a larger size in case the path improved
                s.searchLow = s.currentPLPMTU
                s.searchHigh = configuration.maxPLPMTU
                guard s.searchHigh > s.searchLow + configuration.searchGranularity else {
                    // Already at max
                    s.searchCompletedAt = .now
                    return nil
                }
                s.phase = .searching
                let probeSize = nextProbeSize(low: s.searchLow, high: s.searchHigh)
                return makeProbe(size: probeSize, state: &s)

            case .error:
                // Wait for raise timer before re-entering base
                return nil
            }
        }
    }

    // MARK: - Probe Acknowledgment

    /// Called when a PATH_RESPONSE is received that matches a PMTUD probe.
    ///
    /// - Parameter challengeData: The 8-byte data from the PATH_RESPONSE.
    /// - Returns: The newly confirmed PLPMTU if this was a PMTUD probe,
    ///   or `nil` if the data doesn't match the active probe.
    @discardableResult
    public func probeAcknowledged(challengeData: Data) -> Int? {
        return _state.withLock { s in
            guard let probe = s.activeProbe,
                  probe.challengeData == challengeData else {
                return nil
            }

            // Probe succeeded — this size works
            s.currentPLPMTU = probe.size
            s.searchLow = probe.size
            s.activeProbe = nil
            s.probeAttempts = 0

            // Check if search has converged
            if s.searchHigh - s.searchLow <= configuration.searchGranularity {
                s.phase = .searchComplete
                s.searchCompletedAt = .now
                s.mtuHistory.append((size: s.currentPLPMTU, at: .now))
            }
            // Otherwise stay in .searching — next generateProbe() will
            // try a larger size.

            return s.currentPLPMTU
        }
    }

    // MARK: - Probe Timeout / Failure

    /// Called when the probe timeout expires without acknowledgment.
    ///
    /// This may trigger a retry at the same size (up to `maxProbes`),
    /// or shrink the search range if retries are exhausted.
    ///
    /// - Returns: The current confirmed PLPMTU after processing the timeout.
    @discardableResult
    public func probeTimedOut() -> Int {
        return _state.withLock { s in
            guard let probe = s.activeProbe else {
                return s.currentPLPMTU
            }

            s.activeProbe = nil

            if s.probeAttempts < configuration.maxProbes {
                // Retry at the same size — don't change search bounds.
                // Next call to generateProbe() will re-issue.
                return s.currentPLPMTU
            }

            // Exhausted retries at this size — it's too large.
            s.searchHigh = probe.size - 1
            s.probeAttempts = 0

            // Check if search has converged
            if s.searchHigh - s.searchLow <= configuration.searchGranularity {
                s.phase = .searchComplete
                s.searchCompletedAt = .now
                s.mtuHistory.append((size: s.currentPLPMTU, at: .now))
            }

            return s.currentPLPMTU
        }
    }

    // MARK: - Black Hole Detection

    /// Signals a suspected PMTU black hole.
    ///
    /// A black hole is detected when multiple consecutive packets are
    /// lost at the current MTU but succeed at the base MTU.  This
    /// transitions to `error` state and falls back to `basePLPMTU`.
    ///
    /// - Returns: The base PLPMTU to use as fallback.
    @discardableResult
    public func blackHoleDetected() -> Int {
        return _state.withLock { s in
            guard s.phase != .disabled else { return s.currentPLPMTU }

            s.phase = .error
            s.currentPLPMTU = configuration.basePLPMTU
            s.activeProbe = nil
            s.probeAttempts = 0
            s.errorEnteredAt = .now
            s.searchLow = configuration.basePLPMTU
            s.searchHigh = configuration.maxPLPMTU

            return s.currentPLPMTU
        }
    }

    // MARK: - Timer Processing

    /// Called on each timer tick (typically aligned with the connection's
    /// timer processing loop).
    ///
    /// Handles:
    /// - Probe timeout detection
    /// - Error-state raise timer expiry
    ///
    /// - Returns: Actions the caller should take (see `PMTUTimerAction`).
    public func onTimerFired() -> PMTUTimerAction {
        return _state.withLock { s in
            // Check active probe timeout
            if let probe = s.activeProbe {
                let elapsed = ContinuousClock.now - probe.sentAt
                if elapsed >= configuration.probeTimeout {
                    // Probe timed out
                    s.activeProbe = nil

                    if s.probeAttempts >= configuration.maxProbes {
                        // Exhausted retries — shrink search range
                        s.searchHigh = probe.size - 1
                        s.probeAttempts = 0

                        if s.searchHigh - s.searchLow <= configuration.searchGranularity {
                            s.phase = .searchComplete
                            s.searchCompletedAt = .now
                            s.mtuHistory.append((size: s.currentPLPMTU, at: .now))
                            return .searchConverged(mtu: s.currentPLPMTU)
                        }
                    }
                    return .probeTimedOut(size: probe.size, attempt: probe.attempt)
                }
            }

            // Check error-state raise timer
            if s.phase == .error, let entered = s.errorEnteredAt {
                let elapsed = ContinuousClock.now - entered
                if elapsed >= configuration.raiseTimer {
                    // Re-enter base state to try again
                    s.phase = .base
                    s.errorEnteredAt = nil
                    s.searchLow = configuration.basePLPMTU
                    s.searchHigh = configuration.maxPLPMTU
                    return .raiseTimerExpired
                }
            }

            return .none
        }
    }

    /// The next deadline at which `onTimerFired()` should be called.
    ///
    /// Returns `nil` if no timer is active.
    public var nextTimerDeadline: ContinuousClock.Instant? {
        _state.withLock { s in
            var earliest: ContinuousClock.Instant?

            // Probe timeout
            if let probe = s.activeProbe {
                let deadline = probe.sentAt.advanced(by: configuration.probeTimeout)
                earliest = deadline
            }

            // Error raise timer
            if s.phase == .error, let entered = s.errorEnteredAt {
                let deadline = entered.advanced(by: configuration.raiseTimer)
                if let e = earliest {
                    earliest = min(e, deadline)
                } else {
                    earliest = deadline
                }
            }

            // Reprobe timer
            if s.phase == .searchComplete,
               let interval = configuration.reprobeInterval,
               let completed = s.searchCompletedAt {
                let deadline = completed.advanced(by: interval)
                if let e = earliest {
                    earliest = min(e, deadline)
                } else {
                    earliest = deadline
                }
            }

            return earliest
        }
    }

    // MARK: - Private Helpers

    /// Computes the next probe size using binary search midpoint.
    private func nextProbeSize(low: Int, high: Int) -> Int {
        // Midpoint, biased upward
        return low + (high - low + 1) / 2
    }

    /// Builds a `ProbeRequest` and records the probe in state.
    private func makeProbe(size: Int, state s: inout InternalState) -> ProbeRequest {
        let challengeData = generateChallengeData()
        s.probeAttempts += 1

        let probe = PMTUProbe(
            size: size,
            challengeData: challengeData,
            sentAt: .now,
            attempt: s.probeAttempts
        )
        s.activeProbe = probe

        return ProbeRequest(
            frame: .pathChallenge(challengeData),
            packetSize: size,
            challengeData: challengeData
        )
    }

    /// Generates random 8-byte challenge data for probes.
    private func generateChallengeData() -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: 64))
            .withUnsafeBytes { Data($0) }
    }
}

// MARK: - Timer Action

/// Actions returned by `PMTUDiscoveryManager.onTimerFired()`.
public enum PMTUTimerAction: Sendable, Equatable {
    /// No action needed.
    case none

    /// A probe timed out. The caller may generate a new probe via
    /// `generateProbe()` on the next opportunity.
    case probeTimedOut(size: Int, attempt: Int)

    /// The binary search has converged to a final MTU.
    /// The caller should update `maxDatagramSize` on the connection.
    case searchConverged(mtu: Int)

    /// The raise timer in `error` state expired.
    /// DPLPMTUD has re-entered `base` state and will probe again.
    case raiseTimerExpired
}

// MARK: - Integration Helpers

extension PMTUDiscoveryManager {

    /// Convenience: checks whether the given PATH_RESPONSE data
    /// belongs to a PMTUD probe (vs. a migration PATH_CHALLENGE).
    ///
    /// Use this to dispatch PATH_RESPONSE frames to either the
    /// `PathValidationManager` or the `PMTUDiscoveryManager`.
    public func isProbeResponse(_ challengeData: Data) -> Bool {
        _state.withLock { s in
            guard let probe = s.activeProbe else { return false }
            return probe.challengeData == challengeData
        }
    }

    /// Returns PADDING frame data needed to pad a packet to the probe size.
    ///
    /// - Parameter currentPacketSize: The current packet size before padding.
    /// - Returns: Number of PADDING bytes to add, or 0 if no padding needed.
    public func paddingNeeded(currentPacketSize: Int) -> Int {
        _state.withLock { s in
            guard let probe = s.activeProbe else { return 0 }
            let needed = probe.size - currentPacketSize
            return max(0, needed)
        }
    }

    /// Summary of the current PMTUD state for diagnostics / logging.
    public var diagnosticSummary: String {
        _state.withLock { s in
            var parts: [String] = []
            parts.append("phase=\(s.phase)")
            parts.append("plpmtu=\(s.currentPLPMTU)")
            parts.append("range=[\(s.searchLow),\(s.searchHigh)]")
            if let probe = s.activeProbe {
                parts.append("probe=\(probe.size)@attempt\(probe.attempt)")
            }
            parts.append("history=\(s.mtuHistory.count)entries")
            return parts.joined(separator: " ")
        }
    }
}