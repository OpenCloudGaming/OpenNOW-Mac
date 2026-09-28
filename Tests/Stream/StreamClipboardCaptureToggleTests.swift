import Foundation
import Testing
@testable import OpenNOW

/// The HUD's own on/off switch for the copy trigger: one value, persisted, shared with Settings.
@MainActor
struct StreamClipboardCaptureToggleTests {
    private func makeController() -> StreamClipboardController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenNOWTests.Toggle.\(UUID().uuidString)", isDirectory: true)
        return StreamClipboardController(
            store: StreamClipboardHistoryStore(fileURL: directory.appendingPathComponent("ClipboardHistory.json"))
        )
    }

    @Test func theHudSwitchWritesTheSameSettingTheCapturePathReads() {
        let original = StreamTextCaptureSettings.isTriggerEnabled
        defer { StreamTextCaptureSettings.isTriggerEnabled = original }
        let controller = makeController()
        controller.setCaptureEnabled(false)
        #expect(!controller.isCaptureEnabled)
        #expect(!StreamTextCaptureSettings.isTriggerEnabled)
        controller.setCaptureEnabled(true)
        #expect(controller.isCaptureEnabled)
        #expect(StreamTextCaptureSettings.isTriggerEnabled)
    }

    /// A switch-off also drops a read that was waiting to be joined: it belongs to the trigger being
    /// on, and re-enabling minutes later must not splice a fragment the reader has moved past.
    @Test func switchingOffDropsAPendingJoin() {
        let original = StreamTextCaptureSettings.isTriggerEnabled
        defer { StreamTextCaptureSettings.isTriggerEnabled = original }
        let controller = makeController()
        controller.setCaptureEnabled(true)
        controller.pendingMerge = PendingTextMerge(entryID: UUID(), text: "head \u{2026}", capturedAt: Date())
        controller.setCaptureEnabled(false)
        #expect(controller.pendingMerge == nil)
    }

    @Test func theSwitchStartsFromTheStoredPreference() {
        let original = StreamTextCaptureSettings.isTriggerEnabled
        defer { StreamTextCaptureSettings.isTriggerEnabled = original }
        StreamTextCaptureSettings.isTriggerEnabled = false
        #expect(!makeController().isCaptureEnabled)
        StreamTextCaptureSettings.isTriggerEnabled = true
        #expect(makeController().isCaptureEnabled)
    }
}
