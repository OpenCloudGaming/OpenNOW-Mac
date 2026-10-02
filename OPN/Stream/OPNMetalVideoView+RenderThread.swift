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

/// A frame the render thread took from the arrival queue, with the queue state it was taken in.
struct OPNQueuedFrameDraw {
    let frame: OPNNextVideoFrame
    let isAtDisplayCeiling: Bool
    let queueDepth: Int
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
    private var arrivalTimes: [CFTimeInterval] = []

    /// Returns how many older elements were dropped to stay within the capacity.
    @discardableResult
    mutating func push(_ element: Element, arrivedAt time: CFTimeInterval) -> Int {
        noteArrival(at: time)
        pendingElements.append(element)
        let excess = pendingElements.count - OPNVideoArrivalQueueLimits.capacity
        guard excess > 0 else { return 0 }
        pendingElements.removeFirst(excess)
        return excess
    }

    mutating func next() -> Element? {
        guard !pendingElements.isEmpty else { return nil }
        guard isAtDisplayCeiling else { return pendingElements.removeFirst() }
        let newest = pendingElements.removeLast()
        pendingElements.removeAll()
        return newest
    }

    mutating func removeAll() {
        pendingElements.removeAll()
        arrivalTimes.removeAll()
        isAtDisplayCeiling = false
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

    private(set) var framesInFlight = 0
    private(set) var isLimitedToOneFrame = false
    private var lastSubmitAt: CFTimeInterval = 0
    private var droppedFrameCounts: [Int] = []
    private var retryAt: CFTimeInterval = 0
    private var retryDelay: CFTimeInterval = 10

    /// The frames that may be in flight right now.
    mutating func inFlightLimit(isAtDisplayCeiling: Bool, now: CFTimeInterval) -> Int {
        if framesInFlight > 0, now - lastSubmitAt > Self.lostPresentTimeout { framesInFlight = 0 }
        let isOneFrameWanted = isAtDisplayCeiling && now >= retryAt
        if isOneFrameWanted != isLimitedToOneFrame {
            isLimitedToOneFrame = isOneFrameWanted
            droppedFrameCounts.removeAll()
        }
        return isLimitedToOneFrame ? 1 : 2
    }

    mutating func submitted(at time: CFTimeInterval, droppedBefore dropped: Int) {
        framesInFlight += 1
        lastSubmitAt = time
        guard isLimitedToOneFrame else { return }
        droppedFrameCounts.append(dropped)
        if droppedFrameCounts.count > Self.dropWindow { droppedFrameCounts.removeFirst(droppedFrameCounts.count - Self.dropWindow) }
        guard droppedFrameCounts.reduce(0, +) > Self.tolerableDrops else { return }
        isLimitedToOneFrame = false
        retryAt = time + retryDelay
        retryDelay *= 2
        droppedFrameCounts.removeAll()
    }

    mutating func presented() {
        framesInFlight = max(0, framesInFlight - 1)
    }
}

/// The thread `vrr` draws on. It runs `drain` each time it is signalled, so a present never waits
/// for the main thread.
final class OPNVideoRenderThread: @unchecked Sendable {
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var isRunning = true

    init(drain: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            while isStillRunning {
                wake.wait()
                if isStillRunning { drain() }
            }
            finished.signal()
        }
        thread.name = "OpenNOW video render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var isStillRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    func signal() {
        wake.signal()
    }

    /// Waits up to `timeout` for the draw in progress to finish.
    func stop(timeout: CFTimeInterval) {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
        wake.signal()
        _ = finished.wait(timeout: .now() + max(0, timeout))
    }
}

extension OPNMetalVideoView {
    /// Runs the `vrr` render thread while the view is on screen in that mode, and gives the arrival
    /// queue the fastest refresh of the screen it is on.
    func updateRenderThread() {
        let isThreadWanted = presentationMode == .vrr && window != nil
        let refreshInterval = window?.screen?.minimumRefreshInterval ?? 0
        os_unfair_lock_lock(&frameLock)
        if refreshInterval > 0 { arrivalQueue.displayRefreshInterval = refreshInterval }
        let existingThread = renderThread
        if !isThreadWanted {
            renderThread = nil
            arrivalQueue.removeAll()
        }
        os_unfair_lock_unlock(&frameLock)
        guard isThreadWanted else {
            // Longer than `nextDrawable()`'s one-second timeout, so the thread has let go of the
            // view before teardown continues.
            existingThread?.stop(timeout: 1.1)
            return
        }
        guard existingThread == nil else { return }
        os_unfair_lock_lock(&presentLock)
        inFlightBudget = OPNInFlightBudget()
        os_unfair_lock_unlock(&presentLock)
        let thread = OPNVideoRenderThread { [weak self] in self?.drawArrivedFrames() }
        os_unfair_lock_lock(&frameLock)
        arrivalQueue.removeAll()
        renderThread = thread
        os_unfair_lock_unlock(&frameLock)
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
            inFlightBudget.submitted(at: CACurrentMediaTime(),
                                     droppedBefore: queued.isAtDisplayCeiling ? max(0, queued.queueDepth - 1) : 0)
            os_unfair_lock_unlock(&presentLock)
            drawable.addPresentedHandler { [weak self] _ in self?.notePresented() }
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

    /// From the presented handler: frees the frame's place in the budget and wakes the render
    /// thread, which may have stopped at the limit.
    nonisolated private func notePresented() {
        os_unfair_lock_lock(&presentLock)
        inFlightBudget.presented()
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
        let isAtDisplayCeiling = arrivalQueue.isAtDisplayCeiling
        let queueDepth = arrivalQueue.pendingElements.count
        guard let arrived = arrivalQueue.next() else { return nil }
        let frame = OPNNextVideoFrame(frame: arrived.frame,
                                      serial: arrived.serial,
                                      sourceSize: sourceFrameSize,
                                      outputFormat: desiredOutputFormat,
                                      outputTransfer: desiredTransfer,
                                      receivedAt: arrived.receivedAt)
        return OPNQueuedFrameDraw(frame: frame, isAtDisplayCeiling: isAtDisplayCeiling, queueDepth: queueDepth)
    }

    nonisolated private func outputFormatIsApplied(_ frame: OPNNextVideoFrame) -> Bool {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        return metalLayer?.pixelFormat == frame.outputFormat && appliedTransfer == frame.outputTransfer
    }
}
