//  The in-stream clipboard history as this session sees it: the copy chords drive a frame capture,
//  the frame goes through on-device OCR, and the recognized text is filed locally. Curation — the
//  per-entry copy and the clear action — happens later, from the HUD panel.
//

import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    /// What the reader can see. A capture never fails silently: an empty frame says so as plainly as
    /// a save does, and a fragment cut off by a field says that too rather than passing as complete.
    enum StreamTextCaptureMessage {
        static let saved = "Saved into the clipboard history"
        static let clipped = "Saved \u{2014} text looks cut off, copy the rest to join"
        static let merged = "Joined the two reads"
        static let copied = "Copied to clipboard"
        static let empty = "No text found in frame"
        static let noSelection = "No selected text in frame"
    }

    /// How long a dragged selection stays usable. Long enough to select and then reach for the copy
    /// chord; short enough that a drag from another moment is not read as this copy's selection.
    static let pointerSelectionMaximumAge: TimeInterval = 20

    /// How long a clipped read waits for the rest of itself. Long enough to scroll the field and copy
    /// again; short enough that an unrelated copy much later is not joined to it.
    static let mergeWindow: TimeInterval = 120

    /// Reads the persisted history. Newest first, exactly as the HUD lists it.
    func reloadClipboardHistory() {
        clipboard.reload()
    }

    /// Fires on either copy chord. Guarded so a held key or a burst of presses cannot start a second
    /// capture, and cooldowned because Control-C is a common gameplay binding that would otherwise
    /// run a recognizer pass on every press.
    func captureStreamText() {
        guard StreamTextCaptureSettings.isEnabled else { return }
        guard isConnected, !isEnding, !didEnd, let path else { return }
        guard clipboard.task == nil else { return }
        let now = Date()
        guard clipboard.cooldown.allowsCapture(at: now) else { return }
        clipboard.cooldown.recordCapture(at: now)
        // Read before the screenshot so a drag that lands between the two is not half-applied.
        let selection = clipboard.pointerSelection.recentSelection(at: now, maximumAge: Self.pointerSelectionMaximumAge)
        clipboard.task = Task { @MainActor [weak self] in
            defer { self?.clipboard.task = nil }
            guard let self else { return }
            guard let image = await path.takeScreenshot() else {
                self.showEmptyCaptureMessage(reason: "no-frame")
                return
            }
            let recognition = await self.clipboard.recognizer.recognizeText(in: image, preferredRegion: selection)
            let text = recognition.text
            guard !text.isEmpty else {
                self.showEmptyCaptureMessage(reason: recognition.usedSelection ? "no-selection-text" : "no-selection")
                return
            }
            self.fileCapturedText(text, usedSelection: recognition.usedSelection, at: Date())
        }
    }

    /// Files a read, first trying to complete the last clipped one.
    ///
    /// A field that cuts text off shows a different slice of it at each scroll position, so a second
    /// copy after scrolling is the rest of the same string. When the two reads provably overlap, the
    /// clipped entry is completed in place rather than a second fragment being filed beside it.
    private func fileCapturedText(_ text: String, usedSelection: Bool, at date: Date) {
        if let pending = clipboard.pendingMerge,
           date.timeIntervalSince(pending.capturedAt) <= Self.mergeWindow,
           let joined = StreamTextCaptureFilter.mergedOverlap(pending.text, text),
           clipboard.store.replace(id: pending.entryID, text: joined) != nil {
            // Still cut off — the reader may scroll further, so it keeps waiting to be joined.
            clipboard.pendingMerge = StreamTextCaptureFilter.isClipped(joined)
                ? PendingTextMerge(entryID: pending.entryID, text: joined, capturedAt: date)
                : nil
            reloadClipboardHistory()
            showNativeTransientStreamMessage(Self.StreamTextCaptureMessage.merged)
            OPNStreamTelemetry.capture("nvst.ui.clipboard.merged", level: .info, message: "Two reads of one clipped text were joined.", attributes: [
                "applicationID": configuration.applicationID,
                "characters": String(joined.count),
                "clipped": String(StreamTextCaptureFilter.isClipped(joined)),
            ])
            return
        }

        let isClipped = StreamTextCaptureFilter.isClipped(text)
        let stored = clipboard.store.append(
            text: text,
            applicationID: configuration.applicationID,
            gameTitle: configuration.title
        )
        // A duplicate inside the dedupe window files nothing new, but the text is already in history
        // and the reader did ask for it, so the same confirmation is the honest one.
        clipboard.pendingMerge = stored.flatMap { entry in
            isClipped ? PendingTextMerge(entryID: entry.id, text: text, capturedAt: date) : nil
        }
        reloadClipboardHistory()
        showNativeTransientStreamMessage(isClipped ? Self.StreamTextCaptureMessage.clipped : Self.StreamTextCaptureMessage.saved)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.saved", level: .info, message: "Frame text filed into the clipboard history.", attributes: [
            "applicationID": configuration.applicationID,
            "characters": String(text.count),
            "duplicate": String(stored == nil),
            "scope": usedSelection ? "selection" : "none",
            "clipped": String(isClipped),
        ])
    }

    func copyClipboardEntry(_ entry: StreamClipboardEntry) {
        clipboard.isClearArmed = false
        clipboard.systemIntegration.copyToPasteboard(entry.text)
        showNativeTransientStreamMessage(Self.StreamTextCaptureMessage.copied)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.copied", level: .info, message: "Clipboard history entry copied to the pasteboard.", attributes: [
            "applicationID": configuration.applicationID,
            "characters": String(entry.text.count),
        ])
    }

    /// Two-step clear: the first call arms, the second performs. Disarming on a copy is deliberate —
    /// an armed row that survives another action becomes a trap.
    func requestClearClipboardHistory() {
        guard clipboard.isClearArmed else {
            clipboard.isClearArmed = true
            return
        }
        clipboard.isClearArmed = false
        clearClipboardHistory()
    }

    func clearClipboardHistory() {
        clipboard.pendingMerge = nil
        clipboard.store.clear()
        reloadClipboardHistory()
        OPNStreamTelemetry.capture("nvst.ui.clipboard.cleared", level: .info, message: "Clipboard history cleared from the HUD.", attributes: ["applicationID": configuration.applicationID])
    }

    private func showEmptyCaptureMessage(reason: String) {
        let message = reason == "no-selection" ? Self.StreamTextCaptureMessage.noSelection : Self.StreamTextCaptureMessage.empty
        showNativeTransientStreamMessage(message)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.empty", level: .info, message: "Frame text capture found nothing to file.", attributes: [
            "applicationID": configuration.applicationID,
            "reason": reason,
        ])
    }
}
