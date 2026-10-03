import Foundation

/// Caps how many operations of one kind run at once, queueing the rest.
///
/// `reservedForPriority` keeps a lane free: normal work never occupies more than
/// `limit - reservedForPriority` slots, so priority work waits at most for other priority work.
final class OPNRequestConcurrencyLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private let reservedForPriority: Int
    private var running = 0
    private var peakRunning = 0
    private var pendingPriority: [@Sendable () -> Void] = []
    private var pendingNormal: [@Sendable () -> Void] = []

    init(limit: Int, reservedForPriority: Int = 0) {
        let resolvedLimit = max(1, limit)
        self.limit = resolvedLimit
        // A reservation that took the whole limit would starve normal work, so one slot stays free.
        self.reservedForPriority = min(max(0, reservedForPriority), resolvedLimit - 1)
    }

    /// Highest number of operations ever run at once, so the bound is readable rather than assumed.
    var peakConcurrentCount: Int {
        lock.withLock { peakRunning }
    }

    var concurrentCount: Int {
        lock.withLock { running }
    }

    /// `work` receives a completion handler it must call exactly once when its request finishes.
    func submit(isPriority: Bool = false, _ work: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        let launch: @Sendable () -> Void = { [self] in
            work { self.finish() }
        }
        lock.lock()
        if canStartLocked(isPriority: isPriority) {
            admitLocked()
            lock.unlock()
            launch()
            return
        }
        enqueueLocked(launch, isPriority: isPriority)
        lock.unlock()
    }

    /// Runs `operation` once a slot is free, holding that slot until the operation returns.
    func withPermit<T: Sendable>(isPriority: Bool = false, _ operation: @escaping @Sendable () async -> T) async -> T {
        await withCheckedContinuation { continuation in
            submit(isPriority: isPriority) { finish in
                Task {
                    let result = await operation()
                    finish()
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func canStartLocked(isPriority: Bool) -> Bool {
        guard running < limit else { return false }
        if isPriority { return true }
        return running < limit - reservedForPriority
    }

    private func enqueueLocked(_ launch: @escaping @Sendable () -> Void, isPriority: Bool) {
        if isPriority {
            pendingPriority.append(launch)
            return
        }
        pendingNormal.append(launch)
    }

    private func admitLocked() {
        running += 1
        peakRunning = max(peakRunning, running)
    }

    private func finish() {
        lock.lock()
        running = max(running - 1, 0)
        let next = dequeueNextLocked()
        lock.unlock()
        next?()
    }

    /// Hands the freed slot to priority work first, then to normal work while its lane stays free.
    private func dequeueNextLocked() -> (@Sendable () -> Void)? {
        if !pendingPriority.isEmpty, running < limit {
            admitLocked()
            return pendingPriority.removeFirst()
        }
        if !pendingNormal.isEmpty, running < limit - reservedForPriority {
            admitLocked()
            return pendingNormal.removeFirst()
        }
        return nil
    }
}
