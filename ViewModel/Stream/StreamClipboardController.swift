//  One session's clipboard history state: the store, the recognizer, and the in-flight capture.
//

import Combine
import Foundation

@MainActor
final class StreamClipboardController: ObservableObject {
    /// Newest first, exactly as the HUD lists it.
    @Published var entries: [StreamClipboardEntry] = []
    /// The first press on "Clear history" arms it; the second clears.
    @Published var isClearArmed = false
    /// What the copy chords do, mirroring the Capture setting so the two surfaces cannot disagree.
    @Published var captureMode = StreamTextCaptureSettings.mode
    /// The frozen frame the reader is dragging a region over, if region mode is mid-capture.
    @Published var regionCapture: StreamRegionCapture?

    let store: StreamClipboardHistoryStore
    let recognizer: StreamTextRecognizer
    let systemIntegration: any SystemIntegrationServing

    var cooldown = StreamTextCaptureCooldown()
    var captureTask: Task<Void, Never>?
    /// The reader's last dragged rectangle, preferred over any highlight the scanner would guess at.
    var pointerSelection = StreamPointerSelectionTracker()
    /// The clipped read kept aside so the next copy completes it; only a clipped read is held.
    var pendingMerge: PendingTextMerge?

    init(
        store: StreamClipboardHistoryStore = .shared,
        recognizer: StreamTextRecognizer = StreamTextRecognizer(),
        systemIntegration: any SystemIntegrationServing = AppKitSystemIntegration()
    ) {
        self.store = store
        self.recognizer = recognizer
        self.systemIntegration = systemIntegration
    }

    func reload() {
        entries = store.load()
    }

    func cancelCapture() {
        captureTask?.cancel()
        captureTask = nil
    }

    /// Switches what the copy chords do, persisted immediately.
    func setCaptureMode(_ mode: StreamTextCaptureMode) {
        if captureMode != mode {
            captureMode = mode
            StreamTextCaptureSettings.mode = mode
        }
        // The Capture page can write the same value directly, so both clearances run unconditionally.
        if mode == .off { pendingMerge = nil }
        if mode != .region { regionCapture = nil }
    }
}

/// A clipped read waiting to be completed by a later copy of the same field.
struct PendingTextMerge: Equatable {
    let entryID: UUID
    let text: String
    let capturedAt: Date
}
