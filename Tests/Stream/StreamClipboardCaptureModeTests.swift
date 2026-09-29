import CoreGraphics
import Foundation
import Testing
@testable import OpenNOW

/// The capture mode: one value, persisted, shared by the HUD selector and the Capture page.
@MainActor
struct StreamClipboardCaptureModeTests {
    private func makeController() -> StreamClipboardController {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenNOWTests.Mode.\(UUID().uuidString)", isDirectory: true)
        return StreamClipboardController(
            store: StreamClipboardHistoryStore(fileURL: directory.appendingPathComponent("ClipboardHistory.json"))
        )
    }

    private func onePixelImage() throws -> StreamScreenshotImage {
        let context = try #require(CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return StreamScreenshotImage(cgImage: try #require(context.makeImage()))
    }

    @Test func theHudSelectorWritesTheSameSettingTheCapturePathReads() {
        defer { StreamTextCaptureSettings.mode = .selection }
        let controller = makeController()
        controller.setCaptureMode(.region)
        #expect(controller.captureMode == .region)
        #expect(StreamTextCaptureSettings.mode == .region)
        controller.setCaptureMode(.off)
        #expect(StreamTextCaptureSettings.mode == .off)
    }

    /// Off also drops a read that was waiting to be joined: it belongs to capture being on, and
    /// switching back on minutes later must not splice a fragment the reader has moved past.
    @Test func switchingOffDropsAPendingJoin() {
        defer { StreamTextCaptureSettings.mode = .selection }
        let controller = makeController()
        controller.setCaptureMode(.selection)
        controller.pendingMerge = PendingTextMerge(entryID: UUID(), text: "head \u{2026}", capturedAt: Date())
        controller.setCaptureMode(.off)
        #expect(controller.pendingMerge == nil)
    }

    /// Leaving region mode while a frame is frozen must not strand the overlay over the stream.
    @Test func leavingRegionModeDropsTheFrozenFrame() throws {
        defer { StreamTextCaptureSettings.mode = .selection }
        let controller = makeController()
        controller.regionCapture = StreamRegionCapture(image: try onePixelImage())
        controller.setCaptureMode(.selection)
        #expect(controller.regionCapture == nil)
    }

    @Test func theSelectorStartsFromTheStoredMode() {
        defer { StreamTextCaptureSettings.mode = .selection }
        StreamTextCaptureSettings.mode = .region
        #expect(makeController().captureMode == .region)
    }

    /// A reader whose on/off toggle predates the three-way choice keeps their answer: off stays off,
    /// and an enabled capture lands on the selection read it used to be.
    @Test func aStoredToggleFromBeforeTheModeStillDecides() {
        let storage = OPNAppPreferenceStorage.standard
        let originalMode = storage.string(forKey: StreamTextCaptureSettings.modeKey)
        let originalToggle = storage.object(forKey: StreamTextCaptureSettings.enabledKey)
        defer {
            storage.removeObject(forKey: StreamTextCaptureSettings.modeKey)
            storage.removeObject(forKey: StreamTextCaptureSettings.enabledKey)
            if let originalMode { storage.set(originalMode, forKey: StreamTextCaptureSettings.modeKey) }
            if let originalToggle { storage.set(originalToggle, forKey: StreamTextCaptureSettings.enabledKey) }
        }
        storage.removeObject(forKey: StreamTextCaptureSettings.modeKey)
        storage.set(false, forKey: StreamTextCaptureSettings.enabledKey)
        #expect(StreamTextCaptureSettings.mode == .off)
        storage.set(true, forKey: StreamTextCaptureSettings.enabledKey)
        #expect(StreamTextCaptureSettings.mode == .selection)
        storage.removeObject(forKey: StreamTextCaptureSettings.enabledKey)
        #expect(StreamTextCaptureSettings.mode == .selection)
    }

    @Test func everyModeNamesItself() {
        #expect(StreamTextCaptureMode.allCases == [.off, .selection, .region])
        for mode in StreamTextCaptureMode.allCases {
            #expect(!mode.label.isEmpty)
            #expect(!mode.summary.isEmpty)
        }
    }
}
