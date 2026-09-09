import AppKit
import CoreGraphics
import Testing
@testable import OpenNOW

// The Mouse & Keyboard page: where its Input Monitoring banner reads permission from, and whether
// the Direct Mouse Input copy still describes the toggle people actually get.

@Test func theInputMonitoringBannerReadsLiveSystemStateNotACachedFlag() {
    // `SteamControllerHIDMonitor.inputMonitoringPermissionGranted` is only ever written by the
    // Steam Controller activation path, so it reads `false` for a player who granted Input
    // Monitoring but never enabled Steam Controller support — the banner was permanent for them.
    // Anything but the live preflight here reintroduces that divergence.
    #expect(InputSettingsPage.isInputMonitoringGranted == CGPreflightListenEventAccess())
}

@Test func directMouseInputCopyNamesTheShortcutThatActuallyReleasesThePointer() {
    let subtitle = InputSettingsPage.directMouseInputSubtitle
    #expect(WebRTCMediaStreamCommand.shortcutCommand(keyCode: 35, modifierFlags: .command) == .togglePointerCapture)
    #expect(subtitle.contains("Command-P"))
    #expect(!subtitle.contains("Command-G"), "Command-G is the HUD, not the pointer")
    #expect(!subtitle.contains("Command-Q"), "Command-Q opens the quit menu")
}

@Test func directMouseInputCopyDescribesClickCaptureRatherThanAllRelativeInput() {
    let subtitle = InputSettingsPage.directMouseInputSubtitle
    #expect(subtitle.localizedCaseInsensitiveContains("click"), "the preference gates whether a click may take the pointer")
    #expect(subtitle.localizedCaseInsensitiveContains("hide"), "a seat that hides its cursor still pulls the client into relative aiming")
}
