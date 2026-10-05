//  When to ask the seat to resend a missing video packet.
//

import Foundation

/// Schedules retransmission requests for missing video packets on the official client's timing,
/// as its log prints it: the first request 1 ms after a packet goes missing, then up to three
/// retries, each one round trip plus 4 ms after the last (`useRtdForRtpNackToggle`).
///
/// A retry sooner than the round trip asks for a packet that is already on its way, and the seat
/// sends it again, so retries stay off until a round trip has been measured. The time a requested
/// packet is held for follows the same measurement: the first request's answer arrives one round
/// trip after it, and one retry is allowed, so the hold covers two. The official client's flat
/// 52 ms only covers that at a ~20 ms round trip — below it the gap waited longer than the answer
/// could take, and above it the answer arrived after the gap had already fallen back.
struct NvstNackTracker {
    static let initialDelayNanoseconds: UInt64 = 1_000_000
    static let extraRetryWaitNanoseconds: UInt64 = 4_000_000
    static let maximumRetries = 3
    /// The wait the official client holds a frame for, and what is used until a round trip is known.
    static let defaultWaitNanoseconds: UInt64 = 52_000_000
    /// Never give up on a requested packet sooner than this, whatever the round trip reads: the
    /// answer's arrival has to absorb scheduling jitter on both ends.
    static let minimumWaitNanoseconds: UInt64 = 16_000_000
    /// The receiver's own wall-clock bound on an unrepaired gap (`fecRepairMaximumWaitNanoseconds`).
    /// A hold longer than this can never end, because that bound finalizes the gap first.
    static let maximumWaitCeilingNanoseconds: UInt64 = 100_000_000
    /// A round trip above this is not a measurement worth deriving a wait from.
    static let maximumRoundTripNanoseconds: UInt64 = 2_000_000_000

    /// The wait before a retry: the extra wait alone until a round trip has been measured.
    private(set) var retryIntervalNanoseconds = NvstNackTracker.extraRetryWaitNanoseconds
    /// Whether a second request may go out at all. Off until a round trip is known.
    private(set) var retriesEnabled = false
    /// How long a requested packet is held for, before the gap falls back to a keyframe.
    private(set) var maximumWaitNanoseconds = NvstNackTracker.defaultWaitNanoseconds
    private(set) var retryCount = 0

    private struct Request {
        let firstMissedAt: UInt64
        var lastSentAt: UInt64?
        var sendCount = 0
    }

    private var requests: [UInt64: Request] = [:]

    var isEmpty: Bool { requests.isEmpty }

    mutating func useRoundTrip(nanoseconds: UInt64) {
        let roundTrip = min(nanoseconds, Self.maximumRoundTripNanoseconds)
        retryIntervalNanoseconds = roundTrip + Self.extraRetryWaitNanoseconds
        retriesEnabled = true
        let derived = Self.initialDelayNanoseconds + 2 * retryIntervalNanoseconds
        maximumWaitNanoseconds = min(Self.maximumWaitCeilingNanoseconds,
                                     max(Self.minimumWaitNanoseconds, derived))
    }

    /// The missing indices to request now, recording that they were requested.
    mutating func due(missing: [UInt64], now: UInt64) -> [UInt64] {
        var due: [UInt64] = []
        for index in missing {
            var request = requests[index] ?? Request(firstMissedAt: now)
            let isDue: Bool
            if let lastSentAt = request.lastSentAt {
                isDue = retriesEnabled
                    && request.sendCount <= Self.maximumRetries
                    && now &- lastSentAt >= retryIntervalNanoseconds
            } else {
                isDue = now &- request.firstMissedAt >= Self.initialDelayNanoseconds
            }
            if isDue {
                if request.sendCount > 0 { retryCount += 1 }
                request.lastSentAt = now
                request.sendCount += 1
                due.append(index)
            }
            requests[index] = request
        }
        return due
    }

    /// Whether `index` was requested and is still inside the time its retransmission takes.
    func isAwaitingRetransmission(of index: UInt64, now: UInt64) -> Bool {
        guard let request = requests[index], request.sendCount > 0 else { return false }
        return now &- request.firstMissedAt < maximumWaitNanoseconds
    }

    /// Forgets an index that arrived. True when it had been requested, so the arrival is a repair.
    mutating func arrived(_ index: UInt64) -> Bool {
        (requests.removeValue(forKey: index)?.sendCount ?? 0) > 0
    }

    /// Forgets every index below `index`: delivered, or given up on.
    mutating func forget(below index: UInt64) {
        guard !requests.isEmpty else { return }
        guard requests.keys.contains(where: { $0 < index }) else { return }
        requests = requests.filter { $0.key >= index }
    }

    mutating func reset() {
        requests.removeAll()
    }
}
