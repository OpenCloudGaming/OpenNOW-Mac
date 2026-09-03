import Foundation

/// Caps how many callback-style requests of one kind are in flight, queueing the
/// rest. Used where a single logical operation fans out into dozens of large
/// requests (catalog metadata enrichment) that would otherwise crowd out the
/// artwork downloads the visible frame depends on.
final class OPNRequestConcurrencyLimiter: @unchecked Sendable {
    let lock = NSLock()
    private let limit: Int
    private var running = 0
    private var pending: [@Sendable () -> Void] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// `work` receives a completion handler it must call exactly once, when its
    /// request has finished, so the next queued item can start.
    func submit(_ work: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        let launch: @Sendable () -> Void = { [self] in
            work { self.finish() }
        }
        lock.lock()
        if running < limit {
            running += 1
            lock.unlock()
            launch()
        } else {
            pending.append(launch)
            lock.unlock()
        }
    }

    private func finish() {
        lock.lock()
        let next = pending.isEmpty ? nil : pending.removeFirst()
        if next == nil { running = max(running - 1, 0) }
        lock.unlock()
        next?()
    }
}
