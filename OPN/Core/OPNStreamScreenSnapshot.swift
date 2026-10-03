import AppKit
import CoreGraphics
import Foundation

/// The screen values `loadDeviceCapabilities` derives its display capabilities from, captured on the
/// main actor because `NSScreen` is main-actor only.
struct OPNStreamScreenSnapshot: Sendable {
    let backingScaleFactor: CGFloat
    let screenNumber: UInt32?
    let frameSize: CGSize
    /// Pixel dimensions of the screen's current mode; 0 when the screen exposes no display id.
    let pixelWidth: Int
    let pixelHeight: Int
    /// Refresh rate of the screen's current mode in Hz; 0 when the mode reports none.
    let refreshRate: Int
    let maximumFramesPerSecond: Int
    let maximumPotentialExtendedDynamicRangeColorComponentValue: CGFloat

    @MainActor init?(screen: NSScreen?) {
        guard let screen else { return nil }
        backingScaleFactor = screen.backingScaleFactor
        frameSize = screen.frame.size
        maximumFramesPerSecond = screen.maximumFramesPerSecond
        maximumPotentialExtendedDynamicRangeColorComponentValue = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
        guard let displayNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            screenNumber = nil
            pixelWidth = 0
            pixelHeight = 0
            refreshRate = 0
            return
        }
        screenNumber = displayNumber
        let displayID = CGDirectDisplayID(displayNumber)
        pixelWidth = CGDisplayPixelsWide(displayID)
        pixelHeight = CGDisplayPixelsHigh(displayID)
        let modeRefreshRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        refreshRate = modeRefreshRate.isFinite && modeRefreshRate > 0 ? Int(modeRefreshRate.rounded()) : 0
    }
}

/// The process-wide screen snapshot every stream preference read resolves against. Captured at launch
/// and on every display change, so a read never hops to the main thread and waits for it to be free.
enum OPNStreamScreenSnapshotCache {
    private struct State {
        var snapshot: OPNStreamScreenSnapshot?
        var observerTokens: [NSObjectProtocol] = []
        var refreshCount = 0
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var state = State()

    /// The snapshot for the calling thread: the cached one, or a fresh capture when the caller is
    /// already on the main actor. `nil` on a background thread before the first capture.
    static func resolvedSnapshot() -> OPNStreamScreenSnapshot? {
        if let cachedSnapshot = lock.withLock({ state.snapshot }) { return cachedSnapshot }
        guard Thread.isMainThread else { return nil }
        MainActor.assumeIsolated { refresh() }
        return lock.withLock { state.snapshot }
    }

    /// Captures the current display state. Main actor only, because `NSScreen` is.
    @MainActor
    static func refresh() {
        let capturedSnapshot = OPNStreamScreenSnapshot(screen: NSScreen.main)
        lock.withLock {
            state.snapshot = capturedSnapshot
            state.refreshCount += 1
        }
    }

    /// Captures the snapshot and re-captures it whenever `NSScreen.main` would resolve differently.
    @MainActor
    static func install() {
        refresh()
        guard lock.withLock({ state.observerTokens.isEmpty }) else { return }
        let notificationCenter = NotificationCenter.default
        let recaptureSnapshot: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { OPNStreamScreenSnapshotCache.refresh() }
        }
        let observedNames: [Notification.Name] = [
            NSApplication.didChangeScreenParametersNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didBecomeKeyNotification
        ]
        let observerTokens = observedNames.map { observedName in
            notificationCenter.addObserver(forName: observedName, object: nil, queue: .main, using: recaptureSnapshot)
        }
        lock.withLock { state.observerTokens = observerTokens }
    }

    /// How many times the snapshot has been captured. Test-facing.
    static var refreshCount: Int {
        lock.withLock { state.refreshCount }
    }
}
