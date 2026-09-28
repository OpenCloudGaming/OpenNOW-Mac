//  One session's clipboard history state: the persisted store, the recognizer, the cooldown, the
//  in-flight capture, and the two pieces of HUD state the CLIPBOARD panel draws. Split out of
//  `NativeNVSTHostViewModel` to keep that class inside its size budget; the capture and curation
//  actions stay on the session's extension so they can read its connection state.
//

import Combine
import Foundation

@MainActor
final class StreamClipboardController: ObservableObject {
    /// Newest first, exactly as the HUD lists it.
    @Published var entries: [StreamClipboardEntry] = []
    /// The first press on "Clear history" arms it; the second clears. A pad's activate and a click
    /// both run the same confirm step, so neither can wipe the history by accident.
    @Published var isClearArmed = false

    let store: StreamClipboardHistoryStore
    let recognizer: StreamTextRecognizer
    let systemIntegration: any SystemIntegrationServing

    var cooldown = StreamTextCaptureCooldown()
    var task: Task<Void, Never>?
    /// The rectangle the reader last dragged over the stream. Preferred over any detected highlight
    /// when a capture fires, because it is the selection they actually made.
    var pointerSelection = StreamPointerSelectionTracker()
    /// The clipped read kept aside so the next copy can complete it. Only a clipped read is held:
    /// a complete one has nothing to recover, and joining two unrelated copies would be a guess.
    var pendingMerge: PendingTextMerge?
    /// Whether the copy chords file anything. Mirrors the Capture setting, so the HUD switch and the
    /// Settings switch are one value in one place rather than two that can disagree.
    @Published var isCaptureEnabled = StreamTextCaptureSettings.isTriggerEnabled

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
        task?.cancel()
        task = nil
    }

    /// Turns the copy trigger on or off. Persisted immediately, so it survives the session and is
    /// the same value Settings shows.
    func setCaptureEnabled(_ enabled: Bool) {
        guard isCaptureEnabled != enabled else { return }
        isCaptureEnabled = enabled
        StreamTextCaptureSettings.isTriggerEnabled = enabled
        // A read waiting to be joined belongs to the trigger being on; leaving it behind would let a
        // re-enable minutes later splice a fragment the reader has stopped thinking about.
        if !enabled { pendingMerge = nil }
    }
}

/// A clipped read waiting to be completed by a later copy of the same field.
struct PendingTextMerge: Equatable {
    let entryID: UUID
    let text: String
    let capturedAt: Date
}
