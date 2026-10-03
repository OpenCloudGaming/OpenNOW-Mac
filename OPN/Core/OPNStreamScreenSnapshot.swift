import AppKit
import CoreGraphics
import Foundation

/// Everything `loadDeviceCapabilities` resolves off the current screen: the `NSScreen` properties
/// plus the CoreGraphics metrics for the same display.
///
/// `NSScreen` is main-actor only, so the values are captured there once and cached. The previous
/// implementation read them from whatever thread called `loadDeviceCapabilities` and reached the
/// main actor with a blocking synchronous hop, which stalled the catalog's detached preference task
/// for as long as the main thread was busy.
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
        guard let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            self.screenNumber = nil
            pixelWidth = 0
            pixelHeight = 0
            refreshRate = 0
            return
        }
        self.screenNumber = screenNumber
        let displayID = CGDirectDisplayID(screenNumber)
        pixelWidth = CGDisplayPixelsWide(displayID)
        pixelHeight = CGDisplayPixelsHigh(displayID)
        let modeRefreshRate = CGDisplayCopyDisplayMode(displayID)?.refreshRate ?? 0
        refreshRate = modeRefreshRate.isFinite && modeRefreshRate > 0 ? Int(modeRefreshRate.rounded()) : 0
    }
}

/// The process-wide screen snapshot every stream preference read resolves against.
///
/// Captured once during launch and re-captured on every display-configuration change, so the read
/// path never hops to the main thread: a caller on any thread takes the last capture, and only a
/// caller already on the main actor captures on demand.
enum OPNStreamScreenSnapshotCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var snapshot: OPNStreamScreenSnapshot?
    private nonisolated(unsafe) static var observers: [NSObjectProtocol] = []
    private nonisolated(unsafe) static var captures = 0

    /// The last snapshot captured on the main actor, or `nil` before the first capture.
    static func current() -> OPNStreamScreenSnapshot? {
        lock.withLock { snapshot }
    }

    /// The snapshot for the calling thread: the cached one, or a fresh capture when the caller is
    /// already on the main actor. `nil` on a background thread before the first capture, which in
    /// the app is `install()` during launch.
    static func resolved() -> OPNStreamScreenSnapshot? {
        if let cached = current() { return cached }
        guard Thread.isMainThread else { return nil }
        MainActor.assumeIsolated { refresh() }
        return current()
    }

    /// Captures the current display state. Main actor only, because `NSScreen` is.
    @MainActor
    static func refresh() {
        let captured = OPNStreamScreenSnapshot(screen: NSScreen.main)
        lock.withLock {
            snapshot = captured
            captures += 1
        }
    }

    /// Captures the snapshot now and re-captures it whenever `NSScreen.main` would resolve
    /// differently: displays added, removed, rearranged or reconfigured, a window moved to another
    /// display, its backing properties changed, or a different window taking key.
    @MainActor
    static func install() {
        refresh()
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let recapture: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { OPNStreamScreenSnapshotCache.refresh() }
        }
        for name in [
            NSApplication.didChangeScreenParametersNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification,
            NSWindow.didBecomeKeyNotification
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main, using: recapture))
        }
    }

    /// How many times the snapshot has been captured. Test-facing.
    static var captureCount: Int {
        lock.withLock { captures }
    }
}
