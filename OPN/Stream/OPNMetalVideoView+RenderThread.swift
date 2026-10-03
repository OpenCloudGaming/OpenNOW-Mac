import AppKit
import Foundation
import Metal
import QuartzCore

/// A decoded frame on its way to the `vrr` render thread.
struct OPNArrivedVideoFrame {
    let frame: OPNVideoFrame
    let serial: UInt64
    let receivedAt: CFTimeInterval
}

/// A frame the render thread took from the arrival queue, with the frames lost before it was taken.
struct OPNQueuedFrameDraw {
    let frame: OPNNextVideoFrame
    let droppedBefore: Int
}

/// Identifies the presentation one submitted frame is waiting for. The lifetime separates a worker
/// from its replacement, so a late callback cannot complete a newer frame's slot.
struct OPNPresentationTicket: Equatable {
    let lifetime: UInt64
    let sequence: UInt64
}

/// Tuning for `OPNVideoArrivalQueue`, which cannot hold static stored properties of its own.
private enum OPNVideoArrivalQueueLimits {
    static let capacity = 3
    static let cadenceWindow = 60
    static let ceilingEntryTolerance = 1.01
    static let ceilingExitTolerance = 1.02
}

/// `vrr` only: decoded frames waiting for the render thread. Below the display's maximum refresh
/// every frame is shown in arrival order; at the maximum only the newest is kept, so a stream the
/// display cannot follow never builds latency.
struct OPNVideoArrivalQueue<Element> {
    private(set) var pendingElements: [Element] = []
    private(set) var isAtDisplayCeiling = false
    var displayRefreshInterval: CFTimeInterval = 0
    /// Every element lost since the last take: capacity trims plus, at the ceiling, the older
    /// elements the newest-only rule coalesced away.
    private(set) var droppedElementCount = 0
    private var arrivalTimes: [CFTimeInterval] = []

    /// Returns how many older elements were dropped to stay within the capacity.
    @discardableResult
    mutating func push(_ element: Element, arrivedAt time: CFTimeInterval) -> Int {
        noteArrival(at: time)
        pendingElements.append(element)
        let excess = pendingElements.count - OPNVideoArrivalQueueLimits.capacity
        guard excess > 0 else { return 0 }
        pendingElements.removeFirst(excess)
        droppedElementCount += excess
        return excess
    }

    mutating func next() -> Element? {
        guard !pendingElements.isEmpty else { return nil }
        guard isAtDisplayCeiling else { return pendingElements.removeFirst() }
        let newest = pendingElements.removeLast()
        droppedElementCount += pendingElements.count
        pendingElements.removeAll()
        return newest
    }

    /// The elements dropped since the previous call, which is what the in-flight budget acts on.
    mutating func takeDroppedElementCount() -> Int {
        let dropped = droppedElementCount
        droppedElementCount = 0
        return dropped
    }

    mutating func removeAll() {
        pendingElements.removeAll()
        arrivalTimes.removeAll()
        isAtDisplayCeiling = false
        droppedElementCount = 0
    }

    /// Enters the ceiling within 1% of the display's fastest refresh and leaves it past 2%, so a
    /// stream hovering at the boundary does not flip between the two.
    private mutating func noteArrival(at time: CFTimeInterval) {
        arrivalTimes.append(time)
        if arrivalTimes.count > OPNVideoArrivalQueueLimits.cadenceWindow {
            arrivalTimes.removeFirst(arrivalTimes.count - OPNVideoArrivalQueueLimits.cadenceWindow)
        }
        guard let meanInterval = meanArrivalInterval() else { return }
        if isAtDisplayCeiling, meanInterval > displayRefreshInterval * OPNVideoArrivalQueueLimits.ceilingExitTolerance {
            isAtDisplayCeiling = false
            return
        }
        guard meanInterval < displayRefreshInterval * OPNVideoArrivalQueueLimits.ceilingEntryTolerance else { return }
        isAtDisplayCeiling = true
    }

    /// The mean time between the arrivals in the window, or nil while the window is still filling.
    private func meanArrivalInterval() -> CFTimeInterval? {
        guard displayRefreshInterval > 0, arrivalTimes.count >= OPNVideoArrivalQueueLimits.cadenceWindow / 2,
              let first = arrivalTimes.first, let last = arrivalTimes.last else { return nil }
        return (last - first) / Double(arrivalTimes.count - 1)
    }
}

/// `vrr` at the display ceiling: how many frames may wait for the display. One shows the newest
/// frame a refresh sooner; if frames still drop with one, it goes back to two and doubles the wait
/// before each retry.
struct OPNInFlightBudget {
    static let dropWindow = 60
    static let tolerableDrops = 4
    static let lostPresentTimeout: CFTimeInterval = 0.05

    /// Separates this budget's tickets from a replacement budget's, so a callback from a stopped
    /// worker cannot complete a frame the new worker submitted.
    let lifetime: UInt64

    private(set) var isLimitedToOneFrame = false
    /// The frames handed to the display whose presented callback has not arrived, with the time
    /// each was submitted.
    private var outstandingPresentations: [(ticket: OPNPresentationTicket, submittedAt: CFTimeInterval)] = []
    private var nextSequence: UInt64 = 1
    private var droppedFrameCounts: [Int] = []
    private var retryAt: CFTimeInterval = 0
    private var retryDelay: CFTimeInterval = 10

    var framesInFlight: Int { outstandingPresentations.count }

    init(lifetime: UInt64) {
        self.lifetime = lifetime
    }

    /// The frames that may be in flight right now.
    mutating func inFlightLimit(isAtDisplayCeiling: Bool, now: CFTimeInterval) -> Int {
        expireLostPresentations(at: now)
        let isOneFrameWanted = isAtDisplayCeiling && now >= retryAt
        if isOneFrameWanted != isLimitedToOneFrame {
            isLimitedToOneFrame = isOneFrameWanted
            droppedFrameCounts.removeAll()
        }
        return isLimitedToOneFrame ? 1 : 2
    }

    /// Records a frame handed to the display and returns the ticket its presented callback must
    /// carry. Only pacing drops feed the fallback; renderer failures are a capability signal.
    mutating func submitted(at time: CFTimeInterval, droppedBefore dropped: Int) -> OPNPresentationTicket {
        let ticket = OPNPresentationTicket(lifetime: lifetime, sequence: nextSequence)
        nextSequence += 1
        outstandingPresentations.append((ticket, time))
        guard isLimitedToOneFrame else { return ticket }
        droppedFrameCounts.append(dropped)
        if droppedFrameCounts.count > Self.dropWindow { droppedFrameCounts.removeFirst(droppedFrameCounts.count - Self.dropWindow) }
        guard droppedFrameCounts.reduce(0, +) > Self.tolerableDrops else { return ticket }
        isLimitedToOneFrame = false
        retryAt = time + retryDelay
        retryDelay *= 2
        droppedFrameCounts.removeAll()
        return ticket
    }

    /// Completes the presentation the ticket was issued for. A ticket that already timed out, or
    /// that a replaced worker issued, completes nothing.
    mutating func presented(_ ticket: OPNPresentationTicket) {
        outstandingPresentations.removeAll { $0.ticket == ticket }
    }

    /// Forgets presentations whose callback never arrived, so a lost present cannot hold a slot.
    private mutating func expireLostPresentations(at now: CFTimeInterval) {
        outstandingPresentations.removeAll { now - $0.submittedAt > Self.lostPresentTimeout }
    }
}

/// The thread `vrr` draws on. It runs `drain` each time it is signalled, so a present never waits
/// for the main thread.
final class OPNVideoRenderThread: @unchecked Sendable {
    /// How long `stop` waits inline; a draw that outlives it is reported as unfinished and `onExit`
    /// runs when the worker leaves.
    static let inlineStopTimeout: CFTimeInterval = 0.05

    /// The worker's lifecycle, guarded by `stateLock`: running until `stop` asks it to leave, and
    /// finished once the thread body has returned.
    private struct Lifecycle {
        var isRunning = true
        var isFinished = false
    }

    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let onExit: @Sendable () -> Void
    private let stateLock = NSLock()
    private var lifecycle = Lifecycle()

    init(drain: @escaping @Sendable () -> Void, onExit: @escaping @Sendable () -> Void = {}) {
        self.onExit = onExit
        let thread = Thread { [self] in
            while isStillRunning {
                wake.wait()
                if isStillRunning { drain() }
            }
            markFinished()
            finished.signal()
            onExit()
        }
        thread.name = "OpenNOW video render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var isStillRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycle.isRunning
    }

    /// True once the worker has returned from its last draw and left the thread.
    var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lifecycle.isFinished
    }

    func signal() {
        wake.signal()
    }

    /// Asks the worker to leave and waits up to `timeout` for it. False means a draw is still
    /// running; `onExit` fires when it finishes.
    @discardableResult
    func stop(timeout: CFTimeInterval) -> Bool {
        stateLock.lock()
        if lifecycle.isFinished {
            stateLock.unlock()
            return true
        }
        lifecycle.isRunning = false
        stateLock.unlock()
        wake.signal()
        return finished.wait(timeout: .now() + max(0, timeout)) == .success
    }

    private func markFinished() {
        stateLock.lock()
        lifecycle.isFinished = true
        stateLock.unlock()
    }
}

extension OPNMetalVideoView {
    /// Runs the `vrr` render thread while the view is on screen in that mode, and gives the arrival
    /// queue the fastest refresh of the screen it is on.
    func updateRenderThread() {
        let isThreadWanted = presentationMode == .vrr && window != nil
        let refreshInterval = window?.screen?.minimumRefreshInterval ?? 0
        let isRetiringThreadAlive = retiringRenderThread?.isFinished == false
        if !isRetiringThreadAlive { retiringRenderThread = nil }
        os_unfair_lock_lock(&frameLock)
        if refreshInterval > 0 { arrivalQueue.displayRefreshInterval = refreshInterval }
        let existingThread = renderThread
        if !isThreadWanted {
            renderThread = nil
            arrivalQueue.removeAll()
        }
        os_unfair_lock_unlock(&frameLock)
        guard isThreadWanted else {
            retireRenderThread(existingThread)
            return
        }
        // A worker still finishing a draw holds drawables the replacement would fight it for.
        guard existingThread == nil, !isRetiringThreadAlive else { return }
        os_unfair_lock_lock(&presentLock)
        inFlightBudget = OPNInFlightBudget(lifetime: nextRenderThreadLifetime)
        nextRenderThreadLifetime &+= 1
        os_unfair_lock_unlock(&presentLock)
        let thread = OPNVideoRenderThread { [weak self] in
            self?.drawArrivedFrames()
        } onExit: { [weak self] in
            Task { @MainActor in self?.updateRenderThread() }
        }
        os_unfair_lock_lock(&frameLock)
        arrivalQueue.removeAll()
        renderThread = thread
        os_unfair_lock_unlock(&frameLock)
    }

    /// Asks a worker to leave, remembering it while a draw finishes so nothing replaces it first.
    private func retireRenderThread(_ thread: OPNVideoRenderThread?) {
        guard let thread else { return }
        guard !thread.stop(timeout: OPNVideoRenderThread.inlineStopTimeout) else { return }
        retiringRenderThread = thread
    }

    /// On the render thread: presents queued frames as drawables free up. The frame is taken once a
    /// drawable is in hand, so at the display ceiling it is the newest one, not one that waited.
    nonisolated func drawArrivedFrames() {
        while hasArrivedFrame(), mayPresentAnother(), let metalLayer, let drawable = metalLayer.nextDrawable() {
            guard let queued = takeNextArrivedFrame() else { return }
            guard queued.frame.isRenderable else { continue }
            guard outputFormatIsApplied(queued.frame) else {
                requestOutputFormat(queued.frame)
                continue
            }
            os_unfair_lock_lock(&presentLock)
            let ticket = inFlightBudget.submitted(at: CACurrentMediaTime(), droppedBefore: queued.droppedBefore)
            os_unfair_lock_unlock(&presentLock)
            drawable.addPresentedHandler { [weak self] _ in self?.notePresented(ticket) }
            os_unfair_lock_lock(&drawLock)
            render(queued.frame, into: drawable)
            os_unfair_lock_unlock(&drawLock)
        }
    }

    /// Asks the main actor for the drawable format this frame needs; the next pass picks it up.
    nonisolated private func requestOutputFormat(_ frame: OPNNextVideoFrame) {
        let format = frame.outputFormat
        let transfer = frame.outputTransfer
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { _ = self?.applyOutputFormat(format, transfer: transfer) }
        }
    }

    nonisolated private func mayPresentAnother() -> Bool {
        os_unfair_lock_lock(&frameLock)
        let isAtDisplayCeiling = arrivalQueue.isAtDisplayCeiling
        os_unfair_lock_unlock(&frameLock)
        os_unfair_lock_lock(&presentLock)
        defer { os_unfair_lock_unlock(&presentLock) }
        let limit = inFlightBudget.inFlightLimit(isAtDisplayCeiling: isAtDisplayCeiling, now: CACurrentMediaTime())
        return inFlightBudget.framesInFlight < limit
    }

    /// From the presented handler: completes the presentation the ticket was issued for and wakes
    /// the render thread, which may have stopped at the limit.
    nonisolated private func notePresented(_ ticket: OPNPresentationTicket) {
        os_unfair_lock_lock(&presentLock)
        inFlightBudget.presented(ticket)
        os_unfair_lock_unlock(&presentLock)
        os_unfair_lock_lock(&frameLock)
        let thread = renderThread
        os_unfair_lock_unlock(&frameLock)
        thread?.signal()
    }

    nonisolated private func hasArrivedFrame() -> Bool {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        return presentationMode == .vrr && !arrivalQueue.pendingElements.isEmpty
    }

    nonisolated private func takeNextArrivedFrame() -> OPNQueuedFrameDraw? {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        guard presentationMode == .vrr else { return nil }
        guard let arrived = arrivalQueue.next() else { return nil }
        let droppedBefore = arrivalQueue.takeDroppedElementCount()
        let frame = OPNNextVideoFrame(frame: arrived.frame,
                                      serial: arrived.serial,
                                      sourceSize: sourceFrameSize,
                                      outputFormat: desiredOutputFormat,
                                      outputTransfer: desiredTransfer,
                                      receivedAt: arrived.receivedAt)
        return OPNQueuedFrameDraw(frame: frame, droppedBefore: droppedBefore)
    }

    nonisolated private func outputFormatIsApplied(_ frame: OPNNextVideoFrame) -> Bool {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        return appliedOutputFormat == frame.outputFormat && appliedTransfer == frame.outputTransfer
    }
}
