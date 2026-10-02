import Foundation
import Testing
@testable import OpenNOW

@Suite struct OPNVideoArrivalQueueTests {
    private let refresh = 1.0 / 120.0

    private func makeQueue(arrivingEvery interval: Double, count: Int) -> OPNVideoArrivalQueue<Int> {
        var queue = OPNVideoArrivalQueue<Int>()
        queue.displayRefreshInterval = refresh
        for index in 0..<count {
            queue.push(index, arrivedAt: Double(index) * interval)
            _ = queue.next()
        }
        return queue
    }

    @Test func framesLeaveInArrivalOrder() {
        var queue = OPNVideoArrivalQueue<Int>()
        queue.push(1, arrivedAt: 0)
        queue.push(2, arrivedAt: 0.001)
        let first = queue.next()
        let second = queue.next()
        let third = queue.next()
        #expect([first, second, third] == [1, 2, nil])
    }

    @Test func overflowDropsTheOldest() {
        var queue = OPNVideoArrivalQueue<Int>()
        let dropped = (1...4).map { queue.push($0, arrivedAt: Double($0)) }
        #expect(dropped == [0, 0, 0, 1])
        #expect(queue.pendingElements == [2, 3, 4])
    }

    @Test func atTheDisplayCeilingOnlyTheNewestIsShown() {
        var queue = makeQueue(arrivingEvery: refresh, count: 60)
        queue.push(100, arrivedAt: 60 * refresh)
        queue.push(101, arrivedAt: 60 * refresh + 0.001)
        let shown = queue.next()
        #expect(queue.isAtDisplayCeiling)
        #expect(shown == 101)
        #expect(queue.pendingElements.isEmpty)
    }

    @Test func belowTheCeilingEveryFrameIsShownInOrder() {
        var queue = makeQueue(arrivingEvery: 1.0 / 116.0, count: 60)
        queue.push(100, arrivedAt: 60 / 116.0)
        queue.push(101, arrivedAt: 60 / 116.0 + 0.001)
        let first = queue.next()
        let second = queue.next()
        #expect(!queue.isAtDisplayCeiling)
        #expect([first, second] == [100, 101])
    }

    @Test func removeAllForgetsThePendingFramesAndTheCeiling() {
        var queue = makeQueue(arrivingEvery: refresh, count: 60)
        queue.push(100, arrivedAt: 60 * refresh)
        let wasAtCeiling = queue.isAtDisplayCeiling
        queue.removeAll()
        #expect(wasAtCeiling)
        #expect(!queue.isAtDisplayCeiling)
        #expect(queue.pendingElements.isEmpty)
        #expect(queue.next() == nil)
    }

    @Test func aStreamThatSlowsDownLeavesTheCeiling() {
        var queue = makeQueue(arrivingEvery: refresh, count: 60)
        let wasAtCeiling = queue.isAtDisplayCeiling
        for index in 0..<60 {
            queue.push(index, arrivedAt: 1 + Double(index) / 100)
            _ = queue.next()
        }
        #expect(wasAtCeiling)
        #expect(!queue.isAtDisplayCeiling)
    }
}

@Suite struct OPNInFlightBudgetTests {
    @Test func belowTheCeilingTwoFramesMayWait() {
        var budget = OPNInFlightBudget()
        let limit = budget.inFlightLimit(isAtDisplayCeiling: false, now: 10)
        #expect(limit == 2)
    }

    @Test func atTheCeilingOneFrameMayWait() {
        var budget = OPNInFlightBudget()
        let limit = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        #expect(limit == 1)
    }

    @Test func droppingFramesWithOneInFlightFallsBackToTwoUntilTheRetry() {
        var budget = OPNInFlightBudget()
        let before = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        for index in 0...OPNInFlightBudget.tolerableDrops {
            budget.submitted(at: 10 + Double(index) / 120, droppedBefore: 1)
            budget.presented()
        }
        let during = budget.inFlightLimit(isAtDisplayCeiling: true, now: 11)
        let afterRetry = budget.inFlightLimit(isAtDisplayCeiling: true, now: 21)
        #expect(before == 1)
        #expect(during == 2)
        #expect(afterRetry == 1)
    }

    @Test func theRetryWaitDoublesAfterEachFailedOneFrameAttempt() {
        var budget = OPNInFlightBudget()
        _ = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        tripTheFallback(&budget, from: 10)
        let firstRetry = budget.inFlightLimit(isAtDisplayCeiling: true, now: 21)
        tripTheFallback(&budget, from: 21)
        let duringSecondFallback = budget.inFlightLimit(isAtDisplayCeiling: true, now: 31)
        let secondRetry = budget.inFlightLimit(isAtDisplayCeiling: true, now: 42)
        #expect(firstRetry == 1)
        #expect(duringSecondFallback == 2)
        #expect(secondRetry == 1)
    }

    /// Submits enough dropping frames to trip the fallback from one frame in flight back to two.
    private func tripTheFallback(_ budget: inout OPNInFlightBudget, from time: CFTimeInterval) {
        for index in 0...OPNInFlightBudget.tolerableDrops {
            budget.submitted(at: time + Double(index) / 120, droppedBefore: 1)
            budget.presented()
        }
    }

    @Test func aStalePresentCallbackCannotFreeASlotItNeverHeld() {
        var budget = OPNInFlightBudget()
        let limit = budget.inFlightLimit(isAtDisplayCeiling: false, now: 10)
        budget.presented()
        budget.presented()
        #expect(limit == 2)
        #expect(budget.framesInFlight == 0)
        budget.submitted(at: 10, droppedBefore: 0)
        #expect(budget.framesInFlight == 1)
    }

    @Test func aPresentThatNeverLandsStopsHoldingTheBudget() {
        var budget = OPNInFlightBudget()
        _ = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        budget.submitted(at: 10, droppedBefore: 0)
        let held = budget.framesInFlight
        _ = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10 + OPNInFlightBudget.lostPresentTimeout * 2)
        #expect(held == 1)
        #expect(budget.framesInFlight == 0)
    }
}

@Suite struct OPNVideoRenderThreadTests {
    @Test func drainsWhenSignalledAndNotAfterStopping() {
        let drained = DispatchSemaphore(value: 0)
        let thread = OPNVideoRenderThread { drained.signal() }
        thread.signal()
        let ran = drained.wait(timeout: .now() + 1) == .success
        thread.stop(timeout: 1)
        thread.signal()
        let ranAfterStop = drained.wait(timeout: .now() + 0.1) == .success
        #expect(ran)
        #expect(!ranAfterStop)
    }

    @Test func aThreadCreatedAfterAStopDrainsAgain() {
        let firstDrain = DispatchSemaphore(value: 0)
        let first = OPNVideoRenderThread { firstDrain.signal() }
        first.signal()
        let ranFirst = firstDrain.wait(timeout: .now() + 1) == .success
        first.stop(timeout: 1)

        let secondDrain = DispatchSemaphore(value: 0)
        let second = OPNVideoRenderThread { secondDrain.signal() }
        second.signal()
        let ranSecond = secondDrain.wait(timeout: .now() + 1) == .success
        second.stop(timeout: 1)
        #expect(ranFirst)
        #expect(ranSecond)
    }
}
