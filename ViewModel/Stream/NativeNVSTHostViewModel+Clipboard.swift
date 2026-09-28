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
        /// A selection read that found nothing is usually a selection the detector could not see. The
        /// way out is the other mode, so the flash names it rather than leaving the reader to guess.
        static let regionAdvice = "No text found \u{2014} try Region mode to drag a box"

        /// What an empty read says, and how long it is worth leaving up. A missing frame is a
        /// different failure — Region mode cannot help there — so only a read that had a frame and
        /// found nothing in it points at the other mode.
        static func emptyReadMessage(reason: String, mode: StreamTextCaptureMode) -> String {
            reason != "no-frame" && mode == .selection ? regionAdvice : empty
        }

        static func emptyReadDuration(reason: String, mode: StreamTextCaptureMode) -> Duration {
            emptyReadMessage(reason: reason, mode: mode) == regionAdvice ? .seconds(4) : .seconds(2)
        }
    }

    /// How long a dragged selection stays usable. Long enough to select and then reach for the copy
    /// chord; short enough that a drag from another moment is not read as this copy's selection.
    static let pointerSelectionMaximumAge: TimeInterval = 20

    /// How long a clipped read waits for the rest of itself. Long enough to scroll the field and copy
    /// again; short enough that an unrelated copy much later is not joined to it.
    static let mergeWindow: TimeInterval = 120

    /// Reads the persisted history. Newest first, exactly as the HUD lists it. The mode is refreshed
    /// alongside it: the Capture page can change it while the HUD is closed, and the selector has to
    /// show what the next press will actually do.
    func reloadClipboardHistory() {
        clipboard.reload()
        clipboard.captureMode = StreamTextCaptureSettings.mode
    }

    /// Fires on either copy chord, and does whatever the current mode says. The mode is read from the
    /// setting rather than the HUD's published copy, so a change made on the Capture page mid-session
    /// takes effect on the next press rather than the next HUD open.
    func captureStreamText() {
        guard StreamTextCaptureSettings.isEnabled else { return }
        switch StreamTextCaptureSettings.mode {
        case .off:
            return
        case .selection:
            captureSelectionText()
        case .region:
            beginRegionCapture()
        }
    }

    /// Reads the text the reader selected. Guarded so a held key or a burst of presses cannot start a
    /// second capture, and cooldowned because Control-C is a common gameplay binding that would
    /// otherwise run a recognizer pass on every press.
    private func captureSelectionText() {
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

    // MARK: - Region mode

    /// Freezes the frame and waits for the reader to drag the area worth reading.
    func beginRegionCapture() {
        guard isConnected, !isEnding, !didEnd, let path else { return }
        guard clipboard.regionCapture == nil, clipboard.task == nil else { return }
        // A frozen frame belongs over the game, not over the app's own panels.
        guard !unifiedHUDVisible, !streamControlsVisible, !isShortcutsHelpVisible, !isHUDCustomizeVisible, !isPictureInPicture else { return }
        clipboard.task = Task { @MainActor [weak self] in
            defer { self?.clipboard.task = nil }
            guard let self else { return }
            guard let image = await path.takeScreenshot() else {
                self.showEmptyCaptureMessage(reason: "no-frame")
                return
            }
            self.clipboard.regionCapture = StreamRegionCapture(image: image)
            // The drag is the reader's, not the game's: the frozen overlay takes the pointer until the
            // region is read or the capture is dismissed.
            self.nativeView?.remoteInputEnabled = false
            OPNStreamTelemetry.capture("nvst.ui.clipboard.region.opened", level: .info, message: "Region capture opened on a frozen frame.", attributes: ["applicationID": self.configuration.applicationID])
        }
    }

    /// Reads the rectangle the reader dragged over the frozen frame.
    func completeRegionCapture(_ visionRect: CGRect) {
        guard let capture = clipboard.regionCapture else { return }
        clipboard.regionCapture = nil
        nativeView?.remoteInputEnabled = unifiedHUDVisible ? false : networkPathAvailable
        nativeView?.restoreInputFocus()
        // The frozen frame is from this session's own stream, so the cooldown that guards the copy
        // chords has nothing to do with a drag the reader made deliberately.
        clipboard.task = Task { @MainActor [weak self] in
            defer { self?.clipboard.task = nil }
            guard let self else { return }
            let recognition = await self.clipboard.recognizer.recognizeText(in: capture.image, preferredRegion: visionRect)
            guard !recognition.text.isEmpty else {
                self.showEmptyCaptureMessage(reason: "no-selection-text")
                return
            }
            self.fileCapturedText(recognition.text, usedSelection: true, at: Date())
            OPNStreamTelemetry.capture("nvst.ui.clipboard.region.read", level: .info, message: "Region capture read text from the frozen frame.", attributes: [
                "applicationID": self.configuration.applicationID,
                "characters": String(recognition.text.count),
            ])
        }
    }

    func cancelRegionCapture() {
        guard clipboard.regionCapture != nil else { return }
        clipboard.regionCapture = nil
        nativeView?.remoteInputEnabled = unifiedHUDVisible ? false : networkPathAvailable
        nativeView?.restoreInputFocus()
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

    /// Switches the capture mode from the HUD. Persisted, so it survives the session and the Capture
    /// page shows the same value.
    func setClipboardCaptureMode(_ mode: StreamTextCaptureMode) {
        guard clipboard.captureMode != mode else { return }
        if clipboard.regionCapture != nil { cancelRegionCapture() }
        clipboard.setCaptureMode(mode)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.capture_mode", level: .info, message: "Clipboard capture mode changed from the HUD.", attributes: [
            "applicationID": configuration.applicationID,
            "mode": mode.rawValue,
        ])
    }

    /// The pad's activate: steps through the three modes in order, wrapping.
    func cycleClipboardCaptureMode() {
        let modes = StreamTextCaptureMode.allCases
        let next = (modes.firstIndex(of: clipboard.captureMode).map { $0 + 1 } ?? 0) % modes.count
        setClipboardCaptureMode(modes[next])
    }

    /// Drops one entry from the history.
    func removeClipboardEntry(_ entry: StreamClipboardEntry) {
        guard clipboard.store.remove(id: entry.id) else { return }
        if clipboard.pendingMerge?.entryID == entry.id { clipboard.pendingMerge = nil }
        reloadClipboardHistory()
        OPNStreamTelemetry.capture("nvst.ui.clipboard.removed", level: .info, message: "Clipboard history entry removed from the HUD.", attributes: ["applicationID": configuration.applicationID])
    }

    func clearClipboardHistory() {
        clipboard.pendingMerge = nil
        clipboard.store.clear()
        reloadClipboardHistory()
        OPNStreamTelemetry.capture("nvst.ui.clipboard.cleared", level: .info, message: "Clipboard history cleared from the HUD.", attributes: ["applicationID": configuration.applicationID])
    }

    private func showEmptyCaptureMessage(reason: String) {
        // A selection read that comes back empty is usually a selection the detector could not see,
        // and Region mode is the reader's way round that. The advice also stays up longer than a
        // plain "nothing found": it is the only failure whose fix takes a second act.
        let mode = StreamTextCaptureSettings.mode
        let advisesRegion = Self.StreamTextCaptureMessage.emptyReadMessage(reason: reason, mode: mode) == Self.StreamTextCaptureMessage.regionAdvice
        showNativeTransientStreamMessage(
            Self.StreamTextCaptureMessage.emptyReadMessage(reason: reason, mode: mode),
            duration: Self.StreamTextCaptureMessage.emptyReadDuration(reason: reason, mode: mode)
        )
        OPNStreamTelemetry.capture("nvst.ui.clipboard.empty", level: .info, message: "Frame text capture found nothing to file.", attributes: [
            "applicationID": configuration.applicationID,
            "reason": reason,
            "advisedRegion": String(advisesRegion),
        ])
    }
}
