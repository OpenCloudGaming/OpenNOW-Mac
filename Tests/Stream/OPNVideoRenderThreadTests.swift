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
        let droppedPerPush = (1...4).map { queue.push($0, arrivedAt: Double($0)) }
        #expect(droppedPerPush == [0, 0, 0, 1])
        #expect(queue.pendingElements == [2, 3, 4])
    }

    @Test func capacityOverflowIsCountedAsADrop() {
        var queue = OPNVideoArrivalQueue<Int>()
        for index in 1...4 { queue.push(index, arrivedAt: Double(index)) }
        #expect(queue.droppedElementCount == 1)
        #expect(queue.takeDroppedElementCount() == 1)
        #expect(queue.takeDroppedElementCount() == 0)
    }

    @Test func ceilingCoalescingIsCountedAsADrop() {
        var queue = makeQueue(arrivingEvery: refresh, count: 60)
        _ = queue.takeDroppedElementCount()
        queue.push(100, arrivedAt: 60 * refresh)
        queue.push(101, arrivedAt: 60 * refresh + 0.001)
        let shownElement = queue.next()
        #expect(shownElement == 101)
        #expect(queue.takeDroppedElementCount() == 1)
    }

    @Test func atTheDisplayCeilingOnlyTheNewestIsShown() {
        var queue = makeQueue(arrivingEvery: refresh, count: 60)
        queue.push(100, arrivedAt: 60 * refresh)
        queue.push(101, arrivedAt: 60 * refresh + 0.001)
        let shownElement = queue.next()
        #expect(queue.isAtDisplayCeiling)
        #expect(shownElement == 101)
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

    @Test func removeAllForgetsThePendingFrames() {
        var queue = makeQueue(arrivingEvery: refresh, count: 60)
        queue.push(100, arrivedAt: 60 * refresh)
        queue.removeAll()
        #expect(queue.pendingElements.isEmpty)
        #expect(queue.next() == nil)
    }

    @Test func removeAllClearsTheCeilingState() {
        var queue = makeQueue(arrivingEvery: refresh, count: 60)
        let isAtCeilingBeforeReset = queue.isAtDisplayCeiling
        queue.removeAll()
        #expect(isAtCeilingBeforeReset)
        #expect(!queue.isAtDisplayCeiling)
    }

    @Test func aStreamThatSlowsDownLeavesTheCeiling() {
        var queue = makeQueue(arrivingEvery: refresh, count: 60)
        let isAtCeilingBeforeSlowdown = queue.isAtDisplayCeiling
        for index in 0..<60 {
            queue.push(index, arrivedAt: 1 + Double(index) / 100)
            _ = queue.next()
        }
        #expect(isAtCeilingBeforeSlowdown)
        #expect(!queue.isAtDisplayCeiling)
    }
}

@Suite struct OPNInFlightBudgetTests {
    private let lifetime: UInt64 = 1

    @Test func belowTheCeilingTwoFramesMayWait() {
        var budget = OPNInFlightBudget(lifetime: lifetime)
        let limit = budget.inFlightLimit(isAtDisplayCeiling: false, now: 10)
        #expect(limit == 2)
    }

    @Test func atTheCeilingOneFrameMayWait() {
        var budget = OPNInFlightBudget(lifetime: lifetime)
        let limit = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        #expect(limit == 1)
    }

    @Test func droppingFramesWithOneInFlightFallsBackToTwoUntilTheRetry() {
        var budget = OPNInFlightBudget(lifetime: lifetime)
        let limitBefore = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        submitUntilTheFallbackTrips(&budget, from: 10)
        let limitDuringFallback = budget.inFlightLimit(isAtDisplayCeiling: true, now: 11)
        let limitAtRetry = budget.inFlightLimit(isAtDisplayCeiling: true, now: 21)
        #expect(limitBefore == 1)
        #expect(limitDuringFallback == 2)
        #expect(limitAtRetry == 1)
    }

    @Test func theRetryWaitDoublesAfterEachFailedOneFrameAttempt() {
        var budget = OPNInFlightBudget(lifetime: lifetime)
        _ = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        submitUntilTheFallbackTrips(&budget, from: 10)
        let limitAtFirstRetry = budget.inFlightLimit(isAtDisplayCeiling: true, now: 21)
        submitUntilTheFallbackTrips(&budget, from: 21)
        let limitDuringSecondFallback = budget.inFlightLimit(isAtDisplayCeiling: true, now: 31)
        let limitAtSecondRetry = budget.inFlightLimit(isAtDisplayCeiling: true, now: 42)
        #expect(limitAtFirstRetry == 1)
        #expect(limitDuringSecondFallback == 2)
        #expect(limitAtSecondRetry == 1)
    }

    /// Submits enough dropping frames to trip the fallback from one frame in flight back to two.
    private func submitUntilTheFallbackTrips(_ budget: inout OPNInFlightBudget, from time: CFTimeInterval) {
        for index in 0...OPNInFlightBudget.tolerableDrops {
            let ticket = budget.submitted(at: time + Double(index) / 120, droppedBefore: 1)
            budget.presented(ticket)
        }
    }

    @Test func aLatePresentCannotFreeANewerFramesSlot() {
        var budget = OPNInFlightBudget(lifetime: lifetime)
        _ = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        let timedOutTicket = budget.submitted(at: 10, droppedBefore: 0)
        _ = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10 + OPNInFlightBudget.lostPresentTimeout * 2)
        let currentTicket = budget.submitted(at: 10.2, droppedBefore: 0)
        budget.presented(timedOutTicket)
        #expect(budget.framesInFlight == 1)
        budget.presented(currentTicket)
        #expect(budget.framesInFlight == 0)
    }

    @Test func aPresentFromAReplacedWorkerCannotFreeASlot() {
        var replacedWorkerBudget = OPNInFlightBudget(lifetime: 1)
        _ = replacedWorkerBudget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        let staleTicket = replacedWorkerBudget.submitted(at: 10, droppedBefore: 0)

        var currentBudget = OPNInFlightBudget(lifetime: 2)
        _ = currentBudget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        let currentTicket = currentBudget.submitted(at: 10, droppedBefore: 0)
        currentBudget.presented(staleTicket)
        #expect(currentBudget.framesInFlight == 1)
        currentBudget.presented(currentTicket)
        #expect(currentBudget.framesInFlight == 0)
    }

    @Test func aPresentThatNeverLandsStopsHoldingTheBudget() {
        var budget = OPNInFlightBudget(lifetime: lifetime)
        _ = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10)
        _ = budget.submitted(at: 10, droppedBefore: 0)
        let frameCountWhileUnpresented = budget.framesInFlight
        _ = budget.inFlightLimit(isAtDisplayCeiling: true, now: 10 + OPNInFlightBudget.lostPresentTimeout * 2)
        #expect(frameCountWhileUnpresented == 1)
        #expect(budget.framesInFlight == 0)
    }
}

@Suite struct OPNVideoRenderThreadTests {
    @Test func drainsWhenSignalled() {
        let drained = DispatchSemaphore(value: 0)
        let thread = OPNVideoRenderThread { drained.signal() }
        thread.signal()
        let isDrained = drained.wait(timeout: .now() + 1) == .success
        thread.stop(timeout: 1)
        #expect(isDrained)
    }

    @Test func ignoresSignalsAfterStopping() {
        let drained = DispatchSemaphore(value: 0)
        let thread = OPNVideoRenderThread { drained.signal() }
        thread.stop(timeout: 1)
        thread.signal()
        let isDrainedAfterStop = drained.wait(timeout: .now() + 0.1) == .success
        #expect(!isDrainedAfterStop)
    }

    @Test func aThreadCreatedAfterAStopDrainsAgain() {
        let firstDrain = DispatchSemaphore(value: 0)
        let firstThread = OPNVideoRenderThread { firstDrain.signal() }
        firstThread.signal()
        let isFirstDrained = firstDrain.wait(timeout: .now() + 1) == .success
        firstThread.stop(timeout: 1)

        let secondDrain = DispatchSemaphore(value: 0)
        let secondThread = OPNVideoRenderThread { secondDrain.signal() }
        secondThread.signal()
        let isSecondDrained = secondDrain.wait(timeout: .now() + 1) == .success
        secondThread.stop(timeout: 1)
        #expect(isFirstDrained)
        #expect(isSecondDrained)
    }

    @Test func stopReportsThatTheWorkerHasLeft() {
        let thread = OPNVideoRenderThread {}
        let isStoppedInline = thread.stop(timeout: 1)
        let isStoppedAgain = thread.stop(timeout: 0)
        #expect(isStoppedInline)
        #expect(isStoppedAgain)
        #expect(thread.isFinished)
    }

    @Test func aWorkerBlockedInADrawReportsThatItHasNotLeftYet() {
        let drawStarted = DispatchSemaphore(value: 0)
        let releaseDraw = DispatchSemaphore(value: 0)
        let exitReported = DispatchSemaphore(value: 0)
        let thread = OPNVideoRenderThread {
            drawStarted.signal()
            releaseDraw.wait()
        } onExit: {
            exitReported.signal()
        }
        thread.signal()
        let isDrawStarted = drawStarted.wait(timeout: .now() + 1) == .success
        let isStoppedInline = thread.stop(timeout: OPNVideoRenderThread.inlineStopTimeout)
        let isAlive = !thread.isFinished
        releaseDraw.signal()
        let isExitReported = exitReported.wait(timeout: .now() + 1) == .success
        #expect(isDrawStarted)
        #expect(!isStoppedInline)
        #expect(isAlive)
        #expect(isExitReported)
        #expect(thread.isFinished)
    }
}
