import AppKit
import Foundation
import Metal
import QuartzCore

typealias OPNArrivedVideoFrame = (frame: OPNVideoFrame, serial: UInt64, receivedAt: CFTimeInterval)

/// `vrr` only: decoded frames waiting for the render thread. Below the display's maximum refresh
/// every frame is shown in arrival order. At the maximum the display cannot go faster, so only the
/// newest is kept, as GeForce NOW does: queued frames would hold latency that never drains.
struct OPNVideoArrivalQueue<Element> {
    static var capacity: Int { 3 }
    static var cadenceWindow: Int { 60 }

    private(set) var elements: [Element] = []
    private(set) var isAtDisplayCeiling = false
    var displayRefreshInterval: CFTimeInterval = 0
    private var arrivals: [CFTimeInterval] = []

    /// Returns how many older elements were dropped to stay within `capacity`.
    @discardableResult
    mutating func push(_ element: Element, arrivedAt time: CFTimeInterval) -> Int {
        noteArrival(at: time)
        elements.append(element)
        let excess = elements.count - Self.capacity
        guard excess > 0 else { return 0 }
        elements.removeFirst(excess)
        return excess
    }

    mutating func next() -> Element? {
        guard !elements.isEmpty else { return nil }
        guard isAtDisplayCeiling else { return elements.removeFirst() }
        let newest = elements.removeLast()
        elements.removeAll()
        return newest
    }

    mutating func removeAll() {
        elements.removeAll()
        arrivals.removeAll()
        isAtDisplayCeiling = false
    }

    /// The stream is at the ceiling once its mean interval over the window is within 1% of the
    /// display's fastest refresh, and leaves it past 2%, so a stream hovering at the boundary does
    /// not flip between the two.
    private mutating func noteArrival(at time: CFTimeInterval) {
        arrivals.append(time)
        if arrivals.count > Self.cadenceWindow { arrivals.removeFirst(arrivals.count - Self.cadenceWindow) }
        guard displayRefreshInterval > 0, arrivals.count >= Self.cadenceWindow / 2,
              let first = arrivals.first, let last = arrivals.last else { return }
        let meanInterval = (last - first) / Double(arrivals.count - 1)
        if isAtDisplayCeiling {
            if meanInterval > displayRefreshInterval * 1.02 { isAtDisplayCeiling = false }
        } else if meanInterval < displayRefreshInterval * 1.01 {
            isAtDisplayCeiling = true
        }
    }
}

/// `vrr` at the display ceiling: how many frames may wait for the display. One shows the newest
/// frame a refresh sooner; a frame submitted within 2 ms of the previous refresh made the next one
/// in 99% of a traced session. If frames still drop with one, it goes back to two and waits twice
/// as long before each retry.
struct OPNInFlightBudget {
    static var dropWindow: Int { 60 }
    static var tolerableDrops: Int { 4 }
    static var lostPresentTimeout: CFTimeInterval { 0.05 }

    private(set) var inFlight = 0
    private(set) var allowsOneFrame = false
    private var lastSubmitAt: CFTimeInterval = 0
    private var drops: [Int] = []
    private var retryAt: CFTimeInterval = 0
    private var retryDelay: CFTimeInterval = 10

    mutating func limit(atCeiling: Bool, now: CFTimeInterval) -> Int {
        if inFlight > 0, now - lastSubmitAt > Self.lostPresentTimeout { inFlight = 0 }
        let wantsOneFrame = atCeiling && now >= retryAt
        if wantsOneFrame != allowsOneFrame {
            allowsOneFrame = wantsOneFrame
            drops.removeAll()
        }
        return allowsOneFrame ? 1 : 2
    }

    mutating func submitted(at time: CFTimeInterval, droppedBefore dropped: Int) {
        inFlight += 1
        lastSubmitAt = time
        guard allowsOneFrame else { return }
        drops.append(dropped)
        if drops.count > Self.dropWindow { drops.removeFirst(drops.count - Self.dropWindow) }
        guard drops.reduce(0, +) > Self.tolerableDrops else { return }
        allowsOneFrame = false
        retryAt = time + retryDelay
        retryDelay *= 2
        drops.removeAll()
    }

    mutating func presented() {
        inFlight = max(0, inFlight - 1)
    }
}

/// The thread `vrr` draws on. It runs `drain` each time it is signalled, so a present never waits
/// for the main thread.
final class OPNVideoRenderThread: @unchecked Sendable {
    private let wake = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var running = true

    init(drain: @escaping @Sendable () -> Void) {
        let thread = Thread { [self] in
            while isRunning {
                wake.wait()
                if isRunning { drain() }
            }
            finished.signal()
        }
        thread.name = "OpenNOW video render"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func signal() {
        wake.signal()
    }

    /// Waits up to `timeout` for the draw in progress to finish.
    func stop(timeout: CFTimeInterval) {
        lock.lock()
        running = false
        lock.unlock()
        wake.signal()
        _ = finished.wait(timeout: .now() + timeout)
    }
}

extension OPNMetalVideoView {
    /// Runs the `vrr` render thread while the view is on screen in that mode, and gives the arrival
    /// queue the fastest refresh of the screen it is on.
    func updateRenderThread() {
        let wantsThread = presentationMode == .vrr && window != nil
        let refreshInterval = window?.screen?.minimumRefreshInterval ?? 0
        os_unfair_lock_lock(&frameLock)
        if refreshInterval > 0 { arrivalQueue.displayRefreshInterval = refreshInterval }
        let running = renderThread
        if !wantsThread {
            renderThread = nil
            arrivalQueue.removeAll()
        }
        os_unfair_lock_unlock(&frameLock)
        guard wantsThread else {
            // Longer than `nextDrawable()`'s one-second timeout, so the thread has let go of the
            // view before teardown continues.
            running?.stop(timeout: 1.1)
            return
        }
        guard running == nil else { return }
        os_unfair_lock_lock(&presentLock)
        inFlightBudget = OPNInFlightBudget()
        os_unfair_lock_unlock(&presentLock)
        let thread = OPNVideoRenderThread { [weak self] in self?.drawArrivedFrames() }
        os_unfair_lock_lock(&frameLock)
        arrivalQueue.removeAll()
        renderThread = thread
        os_unfair_lock_unlock(&frameLock)
    }

    /// On the render thread: presents the queued frames as drawables free up. The frame is taken
    /// once a drawable is in hand, so at the display ceiling it is the newest one, not one that
    /// waited a refresh for the drawable.
    nonisolated func drawArrivedFrames() {
        while hasArrivedFrame(), mayPresentAnother(), let metalLayer, let drawable = metalLayer.nextDrawable() {
            guard let taken = nextArrivedFrame() else { return }
            let next = taken.frame
            guard next.frame.width > 0, next.frame.height > 0 else { continue }
            guard outputFormatIsApplied(next.output) else {
                let output = next.output
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { _ = self?.applyOutputFormatIfNeeded(output.0, transfer: output.1) }
                }
                continue
            }
            os_unfair_lock_lock(&presentLock)
            inFlightBudget.submitted(at: CACurrentMediaTime(), droppedBefore: taken.atCeiling ? max(0, taken.depth - 1) : 0)
            os_unfair_lock_unlock(&presentLock)
            drawable.addPresentedHandler { [weak self] _ in self?.notePresented() }
            os_unfair_lock_lock(&drawLock)
            render(next, into: drawable)
            os_unfair_lock_unlock(&drawLock)
        }
    }

    nonisolated private func mayPresentAnother() -> Bool {
        os_unfair_lock_lock(&frameLock)
        let atCeiling = arrivalQueue.isAtDisplayCeiling
        os_unfair_lock_unlock(&frameLock)
        os_unfair_lock_lock(&presentLock)
        defer { os_unfair_lock_unlock(&presentLock) }
        let limit = inFlightBudget.limit(atCeiling: atCeiling, now: CACurrentMediaTime())
        return inFlightBudget.inFlight < limit
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
        return presentationMode == .vrr && !arrivalQueue.elements.isEmpty
    }

    nonisolated private func nextArrivedFrame() -> (frame: OPNNextVideoFrame, atCeiling: Bool, depth: Int)? {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        let atCeiling = arrivalQueue.isAtDisplayCeiling
        let depth = arrivalQueue.elements.count
        guard presentationMode == .vrr, let next = arrivalQueue.next() else { return nil }
        return ((next.frame, next.serial, sourceFrameSize, (desiredOutputFormat, desiredTransfer), next.receivedAt), atCeiling, depth)
    }

    nonisolated private func outputFormatIsApplied(_ output: (MTLPixelFormat, OPNVideoTransferFunction)) -> Bool {
        os_unfair_lock_lock(&frameLock)
        defer { os_unfair_lock_unlock(&frameLock) }
        return metalLayer?.pixelFormat == output.0 && appliedTransfer == output.1
    }
}
