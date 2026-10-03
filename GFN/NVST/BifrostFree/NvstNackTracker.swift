//  When to ask the seat to resend a missing video packet.
//

import Foundation

/// Schedules retransmission requests for missing video packets on the official client's timing,
/// as its log prints it: the first request 1 ms after a packet goes missing, then up to three
/// retries 4 ms apart, within the 52 ms it holds a frame for them.
struct NvstNackTracker {
    static let initialDelayNanoseconds: UInt64 = 1_000_000
    static let retryIntervalNanoseconds: UInt64 = 4_000_000
    static let maximumRetries = 3
    static let maximumWaitNanoseconds: UInt64 = 52_000_000

    private struct Request {
        let firstMissedAt: UInt64
        var lastSentAt: UInt64?
        var sendCount = 0
    }

    private var requests: [UInt64: Request] = [:]

    var isEmpty: Bool { requests.isEmpty }

    /// The missing indices to request now, recording that they were requested.
    mutating func due(missing: [UInt64], now: UInt64) -> [UInt64] {
        var due: [UInt64] = []
        for index in missing {
            var request = requests[index] ?? Request(firstMissedAt: now)
            let isDue: Bool
            if let lastSentAt = request.lastSentAt {
                isDue = request.sendCount <= Self.maximumRetries
                    && now &- lastSentAt >= Self.retryIntervalNanoseconds
            } else {
                isDue = now &- request.firstMissedAt >= Self.initialDelayNanoseconds
            }
            if isDue {
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
        return now &- request.firstMissedAt < Self.maximumWaitNanoseconds
    }

    /// Forgets an index that arrived. True when it had been requested, so the arrival is a repair.
    mutating func arrived(_ index: UInt64) -> Bool {
        (requests.removeValue(forKey: index)?.sendCount ?? 0) > 0
    }

    /// Forgets every index below `index`: delivered, or given up on.
    mutating func forget(below index: UInt64) {
        guard !requests.isEmpty else { return }
        requests = requests.filter { $0.key >= index }
    }

    mutating func reset() {
        requests.removeAll()
    }
}
