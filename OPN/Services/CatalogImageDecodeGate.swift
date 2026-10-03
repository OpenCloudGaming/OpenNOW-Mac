import Foundation

/// The concurrency budget for catalog artwork decodes, and the peak it has reached.
///
/// Every visible tile on the eager home page used to spawn its own detached decode on the first
/// frame. The gate caps that wave and keeps a lane free for the hero and the first-frame prefetch.
nonisolated final class CatalogImageDecodeGate: @unchecked Sendable {
    /// The epic's first-frame ceiling for concurrent decodes.
    static let maximumConcurrentDecodes = 6
    /// Slots inside the ceiling that only first-frame work may occupy.
    static let reservedFirstFrameSlots = 2

    private let limiter: OPNRequestConcurrencyLimiter
    private let limit: Int
    private let reservedForFirstFrame: Int
    private let logLock = NSLock()
    private var loggedPeak = 0

    init(
        limit: Int = CatalogImageDecodeGate.maximumConcurrentDecodes,
        reservedForFirstFrame: Int = CatalogImageDecodeGate.reservedFirstFrameSlots
    ) {
        self.limit = limit
        self.reservedForFirstFrame = reservedForFirstFrame
        self.limiter = OPNRequestConcurrencyLimiter(limit: limit, reservedForPriority: reservedForFirstFrame)
    }

    var peakConcurrentCount: Int {
        limiter.peakConcurrentCount
    }

    /// Runs `operation` once the gate has capacity, holding that slot until the operation returns.
    func run<T: Sendable>(isFirstFrame: Bool, _ operation: @escaping @Sendable () async -> T) async -> T {
        let result = await limiter.withPermit(isPriority: isFirstFrame) {
            await operation()
        }
        // Reported after the slot is released: logging is not part of the work the bound protects.
        logNewPeak()
        return result
    }

    private func logNewPeak() {
        let peak = limiter.peakConcurrentCount
        logLock.lock()
        let isNewPeak = peak > loggedPeak
        if isNewPeak { loggedPeak = peak }
        logLock.unlock()
        guard isNewPeak else { return }
        OPNLog.info(.cache, "Catalog image decode peak=\(peak) limit=\(limit) firstFrameReserved=\(reservedForFirstFrame)")
    }
}
