import Foundation

/// The concurrency budget for catalog artwork decodes, and the peak it has reached.
///
/// On-demand decodes used to be unbounded: every visible tile's `.task(id: url)` spawned its own
/// detached decode on the first frame, and the eager home page fires one per tile. The gate caps
/// that wave and keeps a reserved lane free for first-frame work, so the hero and the prefetch that
/// warms the first rail never queue behind a screenful of tiles.
///
/// A bound nobody can read is a bound nobody can verify, so each new peak is reported once through
/// the ordinary log path and lands in the diagnostics log a user can already send.
nonisolated final class CatalogImageDecodeGate: @unchecked Sendable {
    /// The epic's first-frame ceiling for concurrent decodes.
    static let defaultLimit = 6
    /// Slots inside `defaultLimit` that only first-frame work may occupy. At least one slot always
    /// stays available to on-demand work, so the reservation can never starve the catalog.
    static let defaultReservedForFirstFrame = 2

    private let limiter: OPNRequestConcurrencyLimiter
    private let limit: Int
    private let reservedForFirstFrame: Int
    private let logLock = NSLock()
    private var loggedPeak = 0

    init(
        limit: Int = CatalogImageDecodeGate.defaultLimit,
        reservedForFirstFrame: Int = CatalogImageDecodeGate.defaultReservedForFirstFrame
    ) {
        self.limit = limit
        self.reservedForFirstFrame = reservedForFirstFrame
        self.limiter = OPNRequestConcurrencyLimiter(limit: limit, reservedForPriority: reservedForFirstFrame)
    }

    var peakConcurrentCount: Int {
        limiter.peakConcurrentCount
    }

    /// Runs `operation` once the gate has capacity and holds that slot until the operation returns.
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
