//  The in-stream clipboard history as this session sees it: the copy chords drive a frame capture,
//  the frame goes through on-device OCR, and the recognized text is filed locally. Curation — the
//  per-entry copy and the clear action — happens later, from the HUD panel.
//

import Foundation

@MainActor
extension NativeNVSTHostViewModel {

    /// The three outcomes the reader can see. A capture never fails silently: an empty frame says so
    /// as plainly as a save does.
    enum StreamTextCaptureMessage {
        static let saved = "Saved into the clipboard history"
        static let copied = "Copied to clipboard"
        static let empty = "No text found in frame"
    }

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
        clipboard.task = Task { @MainActor [weak self] in
            defer { self?.clipboard.task = nil }
            guard let self else { return }
            guard let image = await path.takeScreenshot() else {
                self.showEmptyCaptureMessage(reason: "no-frame")
                return
            }
            let recognition = await self.clipboard.recognizer.recognizeText(in: image)
            let text = recognition.text
            guard !text.isEmpty else {
                self.showEmptyCaptureMessage(reason: recognition.usedSelection ? "no-selection-text" : "no-text")
                return
            }
            let stored = self.clipboard.store.append(
                text: text,
                applicationID: self.configuration.applicationID,
                gameTitle: self.configuration.title
            )
            self.reloadClipboardHistory()
            // A duplicate inside the dedupe window files nothing new, but the text is already in
            // history and the reader did ask for it, so the same confirmation is the honest one.
            self.showNativeTransientStreamMessage(Self.StreamTextCaptureMessage.saved)
            OPNStreamTelemetry.capture("nvst.ui.clipboard.saved", level: .info, message: "Frame text filed into the clipboard history.", attributes: [
                "applicationID": self.configuration.applicationID,
                "characters": String(text.count),
                "duplicate": String(stored == nil),
                "scope": recognition.usedSelection ? "selection" : "frame",
            ])
        }
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
        clipboard.store.clear()
        reloadClipboardHistory()
        OPNStreamTelemetry.capture("nvst.ui.clipboard.cleared", level: .info, message: "Clipboard history cleared from the HUD.", attributes: ["applicationID": configuration.applicationID])
    }

    private func showEmptyCaptureMessage(reason: String) {
        showNativeTransientStreamMessage(Self.StreamTextCaptureMessage.empty)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.empty", level: .info, message: "Frame text capture found nothing to file.", attributes: [
            "applicationID": configuration.applicationID,
            "reason": reason,
        ])
    }
}
