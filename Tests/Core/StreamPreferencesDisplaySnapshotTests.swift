import AppKit
import Testing
@testable import OpenNOW

@MainActor @Suite(.serialized) struct StreamPreferencesDisplaySnapshotTests {
    /// The catalog resolves preferences on a detached task, so the read path must never wait on the
    /// main thread. Blocking it here would deadlock the read if it did.
    @Test func loadDeviceCapabilitiesResolvesWhileTheMainThreadIsBlocked() {
        OPNStreamScreenSnapshotCache.refresh()
        let isResolved = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            _ = OPNStreamPreferences.loadDeviceCapabilities()
            isResolved.signal()
        }
        #expect(isResolved.wait(timeout: .now() + 5) == .success)
    }

    @Test func loadDeviceCapabilitiesMatchesOnEveryThread() async {
        OPNStreamScreenSnapshotCache.refresh()
        let onMainActor = OPNStreamPreferences.loadDeviceCapabilities()
        let onBackgroundThread = await Task.detached { OPNStreamPreferences.loadDeviceCapabilities() }.value
        #expect(onBackgroundThread == onMainActor)
    }

    /// Skipped when the process has no display, which is what a headless test runner reports.
    @Test func capabilitiesMatchTheScreenTheyWereCapturedFrom() {
        OPNStreamScreenSnapshotCache.refresh()
        guard let screen = NSScreen.main else { return }
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        #expect(capabilities.displayDpi == max(100, Int((100.0 * screen.backingScaleFactor).rounded())))
        #expect(capabilities.maxDisplayRefreshRate >= screen.maximumFramesPerSecond)
        #expect(capabilities.hdrDisplaySupported == (screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.0))
        guard let screenNumber = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return }
        let displayID = CGDirectDisplayID(screenNumber)
        #expect(capabilities.maxDisplayWidth == CGDisplayPixelsWide(displayID))
        #expect(capabilities.maxDisplayHeight == CGDisplayPixelsHigh(displayID))
    }

    @Test func displayConfigurationChangeRecapturesTheSnapshot() async {
        OPNStreamScreenSnapshotCache.install()
        let refreshesBefore = OPNStreamScreenSnapshotCache.refreshCount
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        var attempts = 0
        while OPNStreamScreenSnapshotCache.refreshCount == refreshesBefore, attempts < 100 {
            try? await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(OPNStreamScreenSnapshotCache.refreshCount > refreshesBefore)
    }
}
