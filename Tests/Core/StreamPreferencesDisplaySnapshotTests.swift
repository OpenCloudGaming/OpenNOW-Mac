import AppKit
import Testing
@testable import OpenNOW

@MainActor @Suite(.serialized) struct StreamPreferencesDisplaySnapshotTests {
    /// The catalog resolves preferences on a detached task, and the main thread is usually busy with
    /// catalog work when it does. Reading the screen there used to be a `DispatchQueue.main.sync`, so
    /// a main thread that waited on that task deadlocked. Nothing on the read path may need the main
    /// thread to run.
    @Test func backgroundReadResolvesWhileTheMainThreadIsBlocked() {
        OPNStreamScreenSnapshotCache.refresh()
        let finished = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            _ = OPNStreamPreferences.loadDeviceCapabilities()
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 5) == .success)
    }

    @Test func backgroundReadMatchesTheMainActorRead() async {
        OPNStreamScreenSnapshotCache.refresh()
        let onMainActor = OPNStreamPreferences.loadDeviceCapabilities()
        let onBackgroundThread = await Task.detached { OPNStreamPreferences.loadDeviceCapabilities() }.value
        #expect(onBackgroundThread == onMainActor)
    }

    /// Every display-derived capability must resolve exactly as a direct `NSScreen` read would.
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
        let capturesBefore = OPNStreamScreenSnapshotCache.captureCount
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        var attempts = 0
        while OPNStreamScreenSnapshotCache.captureCount == capturesBefore, attempts < 100 {
            try? await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        #expect(OPNStreamScreenSnapshotCache.captureCount > capturesBefore)
    }
}
