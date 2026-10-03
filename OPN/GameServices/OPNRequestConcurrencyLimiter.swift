import Foundation

/// Caps how many operations of one kind run at once, queueing the rest. Used where a single logical
/// operation fans out into dozens of large requests (catalog metadata enrichment, artwork decodes)
/// that would otherwise crowd out the work the visible frame depends on.
///
/// `reservedForPriority` keeps a lane free for priority work: normal operations can never occupy
/// more than `limit - reservedForPriority` slots, so a priority operation waits at most for another
/// priority operation, never for the normal backlog.
final class OPNRequestConcurrencyLimiter: @unchecked Sendable {
    let lock = NSLock()
    private let limit: Int
    private let reservedForPriority: Int
    private var running = 0
    private var peakRunning = 0
    private var pendingPriority: [@Sendable () -> Void] = []
    private var pendingNormal: [@Sendable () -> Void] = []

    init(limit: Int, reservedForPriority: Int = 0) {
        let resolvedLimit = max(1, limit)
        self.limit = resolvedLimit
        // A reservation that consumed the whole limit would starve normal work entirely, so at
        // least one slot always stays available to it.
        self.reservedForPriority = min(max(0, reservedForPriority), resolvedLimit - 1)
    }

    /// Highest number of operations this limiter has run at once. A bound nobody can read is a
    /// bound nobody can verify, so callers report this rather than trusting the constant.
    var peakConcurrentCount: Int {
        lock.withLock { peakRunning }
    }

    var concurrentCount: Int {
        lock.withLock { running }
    }

    /// `work` receives a completion handler it must call exactly once, when its request has
    /// finished, so the next queued item can start. Priority work is admitted ahead of queued
    /// normal work and draws on the reserved lane.
    func submit(isPriority: Bool = false, _ work: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        let launch: @Sendable () -> Void = { [self] in
            work { self.finish() }
        }
        lock.lock()
        if canStartLocked(isPriority: isPriority) {
            running += 1
            peakRunning = max(peakRunning, running)
            lock.unlock()
            launch()
            return
        }
        if isPriority {
            pendingPriority.append(launch)
        } else {
            pendingNormal.append(launch)
        }
        lock.unlock()
    }

    /// Runs `operation` once a slot is free and holds that slot until it returns. The operation
    /// crosses onto its own task, so its result has to be safe to send.
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

    private func finish() {
        lock.lock()
        running = max(running - 1, 0)
        let next = nextLaunchLocked()
        if next != nil {
            running += 1
            peakRunning = max(peakRunning, running)
        }
        lock.unlock()
        next?()
    }

    /// Priority work first, then normal work only while the reserved lane stays free.
    private func nextLaunchLocked() -> (@Sendable () -> Void)? {
        if !pendingPriority.isEmpty, running < limit {
            return pendingPriority.removeFirst()
        }
        if !pendingNormal.isEmpty, running < limit - reservedForPriority {
            return pendingNormal.removeFirst()
        }
        return nil
    }
}
