import Foundation
import Testing
@testable import OpenNOW

/// The decode limiter is what turns a first-frame decode stampede into a bounded wave, so these pin
/// the two properties that make it a bound rather than a queue: the ceiling holds, and priority work
/// never waits behind the normal backlog.
struct RequestConcurrencyLimiterTests {
    @Test func normalWorkCannotOccupyTheReservedLane() async {
        let limiter = OPNRequestConcurrencyLimiter(limit: 4, reservedForPriority: 2)
        let gate = WorkGate()
        let started = StartSignals()

        let normalWork = (0..<6).map { _ in
            Task {
                await limiter.withPermit {
                    await started.signal()
                    await gate.wait()
                }
            }
        }

        // Four slots, two reserved: six submitted normal operations settle at two running, not four.
        await started.waitForCount(2)
        #expect(limiter.concurrentCount == 2)

        let priorityWork = Task {
            await limiter.withPermit(isPriority: true) {
                await started.signal()
                await gate.wait()
            }
        }
        await started.waitForCount(3)
        #expect(limiter.concurrentCount == 3)

        await gate.open()
        for task in normalWork { await task.value }
        await priorityWork.value

        #expect(limiter.concurrentCount == 0)
        #expect(limiter.peakConcurrentCount == 3)
    }

    @Test func aLimiterWithoutAReservedLaneRunsUpToItsLimit() async {
        let limiter = OPNRequestConcurrencyLimiter(limit: 3)
        let gate = WorkGate()
        let started = StartSignals()

        let work = (0..<5).map { _ in
            Task {
                await limiter.withPermit {
                    await started.signal()
                    await gate.wait()
                }
            }
        }

        await started.waitForCount(3)
        #expect(limiter.concurrentCount == 3)

        await gate.open()
        for task in work { await task.value }

        #expect(limiter.peakConcurrentCount == 3)
    }

    @Test func queuedPriorityWorkIsAdmittedAheadOfWaitingNormalWork() async {
        let limiter = OPNRequestConcurrencyLimiter(limit: 1)
        let admissionOrder = AdmissionOrder()
        let holderRelease = WorkGate()

        limiter.submit { finish in
            Task {
                await holderRelease.wait()
                finish()
            }
        }
        await waitUntil { limiter.concurrentCount == 1 }

        // The normal operation queues first; the priority operation still starts first.
        limiter.submit { finish in
            Task {
                await admissionOrder.record("normal")
                finish()
            }
        }
        limiter.submit(isPriority: true) { finish in
            Task {
                await admissionOrder.record("priority")
                finish()
            }
        }

        await holderRelease.open()
        await waitUntil { await admissionOrder.entries.count == 2 }
        #expect(await admissionOrder.entries == ["priority", "normal"])
    }
}

/// The epic's first-frame target is `<= 6` concurrent decodes, and a reserved lane only means
/// anything if it is a real slice of that budget rather than the whole of it.
struct CatalogImageDecodeBudgetTests {
    @Test func theDecodeBudgetStaysInsideTheEpicCeiling() {
        #expect(CatalogImageDecodeGate.defaultLimit <= 6)
        #expect(CatalogImageDecodeGate.defaultReservedForFirstFrame > 0)
        #expect(CatalogImageDecodeGate.defaultReservedForFirstFrame < CatalogImageDecodeGate.defaultLimit)
    }
}

private actor WorkGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor StartSignals {
    private var count = 0
    private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func signal() {
        count += 1
        resumeSatisfiedWaiters()
    }

    func waitForCount(_ threshold: Int) async {
        guard count < threshold else { return }
        await withCheckedContinuation { continuation in
            waiters.append((threshold, continuation))
            resumeSatisfiedWaiters()
        }
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = waiters.filter { $0.threshold <= count }
        guard !satisfied.isEmpty else { return }
        waiters.removeAll { $0.threshold <= count }
        for waiter in satisfied { waiter.continuation.resume() }
    }
}

private actor AdmissionOrder {
    private(set) var entries: [String] = []

    func record(_ entry: String) {
        entries.append(entry)
    }
}

private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("condition was not met within \(timeout)")
}
