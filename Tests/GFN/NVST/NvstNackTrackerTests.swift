import Foundation
import Testing
@testable import OpenNOW

struct NvstNackTrackerTests {
    @Test func aMissingPacketIsRequestedAfterTheInitialDelay() {
        var tracker = NvstNackTracker()
        #expect(tracker.due(missing: [7], now: 0).isEmpty)
        #expect(tracker.due(missing: [7], now: NvstNackTracker.initialDelayNanoseconds - 1).isEmpty)
        #expect(tracker.due(missing: [7], now: NvstNackTracker.initialDelayNanoseconds) == [7])
    }

    @Test func aRequestIsRetriedThreeTimesAtTheRetryInterval() {
        var tracker = NvstNackTracker()
        _ = tracker.due(missing: [7], now: 0)
        var sendTimes: [UInt64] = []
        var now = NvstNackTracker.initialDelayNanoseconds
        while now <= NvstNackTracker.maximumWaitNanoseconds {
            if !tracker.due(missing: [7], now: now).isEmpty { sendTimes.append(now) }
            now += 1_000_000
        }
        #expect(sendTimes.count == 1 + NvstNackTracker.maximumRetries)
        #expect(zip(sendTimes, sendTimes.dropFirst()).allSatisfy { $1 - $0 == NvstNackTracker.retryIntervalNanoseconds })
    }

    @Test func aRequestedArrivalCountsAsARepair() {
        var tracker = NvstNackTracker()
        _ = tracker.due(missing: [7, 8], now: 0)
        _ = tracker.due(missing: [7, 8], now: NvstNackTracker.initialDelayNanoseconds)
        let notRequested = NvstNackTracker()
        var unrequested = notRequested
        _ = unrequested.due(missing: [9], now: 0)
        let repaired = tracker.arrived(7)
        let notRepaired = unrequested.arrived(9)
        #expect(repaired)
        #expect(!notRepaired)
        #expect(tracker.isAwaitingRetransmission(of: 8, now: NvstNackTracker.initialDelayNanoseconds))
        #expect(!tracker.isAwaitingRetransmission(of: 8, now: NvstNackTracker.maximumWaitNanoseconds))
        tracker.forget(below: 9)
        #expect(tracker.isEmpty)
    }
}
