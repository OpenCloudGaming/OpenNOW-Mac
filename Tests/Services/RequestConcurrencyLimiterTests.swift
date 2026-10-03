import Testing
@testable import OpenNOW

/// The decode limiter turns a first-frame decode stampede into a bounded wave, so these pin the two
/// properties that make it a bound rather than a queue: the ceiling holds, and priority work never
/// waits behind the normal backlog.
struct RequestConcurrencyLimiterTests {
    @Test func normalWorkCannotOccupyTheReservedLane() async {
        let limiter = OPNRequestConcurrencyLimiter(limit: 4, reservedForPriority: 2)
        let gate = WorkGate()
        let starts = AsyncStream<Void>.makeStream()
        var startIterator = starts.stream.makeAsyncIterator()

        let normalWork = (0..<6).map { _ in
            Task {
                await limiter.withPermit {
                    starts.continuation.yield()
                    await gate.wait()
                }
            }
        }

        // Four slots, two reserved: six submitted normal operations settle at two running, not four.
        _ = await startIterator.next()
        _ = await startIterator.next()
        #expect(limiter.concurrentCount == 2)

        let priorityWork = Task {
            await limiter.withPermit(isPriority: true) {
                starts.continuation.yield()
                await gate.wait()
            }
        }
        _ = await startIterator.next()
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
        let starts = AsyncStream<Void>.makeStream()
        var startIterator = starts.stream.makeAsyncIterator()

        let work = (0..<5).map { _ in
            Task {
                await limiter.withPermit {
                    starts.continuation.yield()
                    await gate.wait()
                }
            }
        }

        for _ in 0..<3 { _ = await startIterator.next() }
        #expect(limiter.concurrentCount == 3)

        await gate.open()
        for task in work { await task.value }

        #expect(limiter.peakConcurrentCount == 3)
    }

    @Test func queuedPriorityWorkIsAdmittedAheadOfWaitingNormalWork() async {
        let limiter = OPNRequestConcurrencyLimiter(limit: 1)
        let admissions = AsyncStream<String>.makeStream()
        var admissionIterator = admissions.stream.makeAsyncIterator()
        let holderStarted = AsyncStream<Void>.makeStream()
        var holderStartIterator = holderStarted.stream.makeAsyncIterator()
        let holderRelease = WorkGate()

        limiter.submit { finish in
            Task {
                holderStarted.continuation.yield()
                await holderRelease.wait()
                finish()
            }
        }
        _ = await holderStartIterator.next()

        // The normal operation queues first; the priority operation still starts first.
        limiter.submit { finish in
            Task {
                admissions.continuation.yield("normal")
                finish()
            }
        }
        limiter.submit(isPriority: true) { finish in
            Task {
                admissions.continuation.yield("priority")
                finish()
            }
        }

        await holderRelease.open()
        let firstAdmission = await admissionIterator.next()
        let secondAdmission = await admissionIterator.next()
        #expect(firstAdmission == "priority")
        #expect(secondAdmission == "normal")
    }
}

/// The epic's first-frame target is `<= 6` concurrent decodes, and a reserved lane only means
/// anything if it is a real slice of that budget rather than the whole of it.
struct CatalogImageDecodeBudgetTests {
    @Test func theDecodeBudgetStaysInsideTheEpicCeiling() {
        #expect(CatalogImageDecodeGate.maximumConcurrentDecodes <= 6)
        #expect(CatalogImageDecodeGate.reservedFirstFrameSlots > 0)
        #expect(CatalogImageDecodeGate.reservedFirstFrameSlots < CatalogImageDecodeGate.maximumConcurrentDecodes)
    }
}

/// Holds every operation that reaches it until `open`, so a test can observe the limiter's ceiling.
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
