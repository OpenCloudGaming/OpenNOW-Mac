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

    @Test func aRequestIsRetriedAtTheRetryIntervalWithinTheRetryBudget() {
        var tracker = NvstNackTracker()
        tracker.useRoundTrip(nanoseconds: 16_000_000)
        _ = tracker.due(missing: [7], now: 0)
        var sendTimes: [UInt64] = []
        var now: UInt64 = 0
        while now <= tracker.maximumWaitNanoseconds {
            if !tracker.due(missing: [7], now: now).isEmpty { sendTimes.append(now) }
            now += 1_000_000
        }
        #expect(sendTimes.first == NvstNackTracker.initialDelayNanoseconds)
        #expect(zip(sendTimes, sendTimes.dropFirst()).allSatisfy { $1 - $0 == tracker.retryIntervalNanoseconds })
        #expect(sendTimes.count <= 1 + NvstNackTracker.maximumRetries)
        #expect(tracker.retryCount == sendTimes.count - 1)
    }

    /// A fixed short retry re-asks for a packet that is already on its way, and the seat sends it
    /// again. Without a measured round trip there is nothing to wait for, so there is one request.
    @Test func aRequestIsNotRetriedBeforeTheRoundTripIsKnown() {
        var tracker = NvstNackTracker()
        _ = tracker.due(missing: [7], now: 0)
        #expect(tracker.due(missing: [7], now: NvstNackTracker.initialDelayNanoseconds) == [7])
        var now = NvstNackTracker.initialDelayNanoseconds + 1_000_000
        while now <= NvstNackTracker.defaultWaitNanoseconds {
            #expect(tracker.due(missing: [7], now: now).isEmpty)
            now += 1_000_000
        }
        #expect(tracker.retryCount == 0)
    }

    /// The hold has to cover the answer to the first request and to one retry; below the official
    /// client's 52 ms it fell back before the answer could arrive, and above it the answer arrived
    /// after the fallback. It stays inside the receiver's own wall-clock bound on an unrepaired gap.
    @Test func theHoldCoversTwoRoundTripsAndIsClamped() {
        var tracker = NvstNackTracker()
        #expect(tracker.maximumWaitNanoseconds == NvstNackTracker.defaultWaitNanoseconds)

        tracker.useRoundTrip(nanoseconds: 1_000_000)
        #expect(tracker.maximumWaitNanoseconds == NvstNackTracker.minimumWaitNanoseconds)

        tracker.useRoundTrip(nanoseconds: 20_000_000)
        #expect(tracker.maximumWaitNanoseconds == 49_000_000)

        tracker.useRoundTrip(nanoseconds: 60_000_000)
        #expect(tracker.maximumWaitNanoseconds == NvstNackTracker.maximumWaitCeilingNanoseconds)

        // A nonsensical measurement cannot push the wait past that bound, nor overflow the derivation.
        tracker.useRoundTrip(nanoseconds: .max)
        #expect(tracker.maximumWaitNanoseconds == NvstNackTracker.maximumWaitCeilingNanoseconds)
    }

    /// With the round trip known, a retry waits for the answer the first request could bring.
    @Test func aRetryWaitsOneRoundTripPlusTheExtraWait() {
        var tracker = NvstNackTracker()
        tracker.useRoundTrip(nanoseconds: 16_000_000)
        _ = tracker.due(missing: [7], now: 0)
        let first = NvstNackTracker.initialDelayNanoseconds
        #expect(tracker.due(missing: [7], now: first) == [7])
        #expect(tracker.due(missing: [7], now: first + 19_999_999).isEmpty)
        #expect(tracker.due(missing: [7], now: first + 20_000_000) == [7])
        #expect(tracker.retryCount == 1)
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
        #expect(!tracker.isAwaitingRetransmission(of: 8, now: NvstNackTracker.defaultWaitNanoseconds))
        tracker.forget(below: 9)
        #expect(tracker.isEmpty)
    }
}
