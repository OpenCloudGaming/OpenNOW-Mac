//  The in-stream clipboard history as this session sees it: the copy chords read a frame, and the
//  text is filed locally. Curation happens later, from the HUD panel.
//

import Foundation

/// Why a capture filed nothing.
enum StreamTextCaptureEmptyReason: Equatable, Sendable {
    case noFrame
    case noSelection
    case noTextInSelection

    var label: String {
        switch self {
        case .noFrame: "no-frame"
        case .noSelection: "no-selection"
        case .noTextInSelection: "no-selection-text"
        }
    }

    /// A missing frame is a different failure: Region mode cannot help there.
    var advisesRegionMode: Bool {
        self != .noFrame
    }
}

@MainActor
extension NativeNVSTHostViewModel {

    /// What the reader can see. A capture never fails silently: an empty read says so as plainly as
    /// a save does, and a fragment cut off by a field says that too rather than passing as complete.
    enum StreamTextCaptureMessage {
        static let saved = "Saved into the clipboard history"
        static let clipped = "Saved \u{2014} text looks cut off, copy the rest to join"
        static let merged = "Joined the two reads"
        static let copied = "Copied to clipboard"
        static let empty = "No text found in frame"
        /// The way out of a selection the detector could not see is the other mode.
        static let regionAdvice = "No text found \u{2014} try Region mode to drag a box"

        /// What an empty read says and how long it stays up. The advice lasts longer than a plain
        /// "nothing found", because it is the only failure whose fix takes a second act.
        struct EmptyReadNotice: Equatable {
            let message: String
            let duration: Duration
            let advisesRegionMode: Bool

            static func make(reason: StreamTextCaptureEmptyReason, mode: StreamTextCaptureMode) -> EmptyReadNotice {
                guard reason.advisesRegionMode, mode == .selection else {
                    return EmptyReadNotice(message: empty, duration: .seconds(2), advisesRegionMode: false)
                }
                return EmptyReadNotice(message: regionAdvice, duration: .seconds(4), advisesRegionMode: true)
            }
        }
    }

    /// How long a dragged selection stays usable before a copy stops counting it.
    static let pointerSelectionMaximumAge: TimeInterval = 20

    /// How long a clipped read waits for the rest of itself.
    static let mergeWindow: TimeInterval = 120

    /// Reads the persisted history, and refreshes the mode the Capture page may have changed.
    func reloadClipboardHistory() {
        clipboard.reload()
        clipboard.captureMode = StreamTextCaptureSettings.mode
    }

    /// Fires on either copy chord and does whatever the current mode says. The mode is read from the
    /// setting, so a change on the Capture page applies to the next press, not the next HUD open.
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

    /// Reads the text the reader selected, cooldowned because Control-C is a common gameplay binding.
    private func captureSelectionText() {
        guard isConnected, !isEnding, !didEnd, let path else { return }
        guard clipboard.captureTask == nil else { return }
        let now = Date()
        guard clipboard.cooldown.allowsCapture(at: now) else { return }
        clipboard.cooldown.recordCapture(at: now)
        // Read before the screenshot so a drag landing between the two is not half-applied.
        let draggedSelection = clipboard.pointerSelection.recentSelection(at: now, maximumAge: Self.pointerSelectionMaximumAge)
        clipboard.captureTask = Task { @MainActor [weak self] in
            defer { self?.clipboard.captureTask = nil }
            guard let self else { return }
            guard let image = await path.takeScreenshot() else {
                self.showEmptyCaptureMessage(reason: .noFrame)
                return
            }
            let recognition = await self.clipboard.recognizer.recognizeText(in: image, preferredRegion: draggedSelection)
            guard !recognition.text.isEmpty else {
                self.showEmptyCaptureMessage(reason: recognition.isSelectionUsed ? .noTextInSelection : .noSelection)
                return
            }
            self.fileCapturedText(recognition.text, isSelectionUsed: recognition.isSelectionUsed, at: Date())
        }
    }

    // MARK: - Region mode

    /// Freezes the frame and waits for the reader to drag the area worth reading.
    func beginRegionCapture() {
        guard isConnected, !isEnding, !didEnd, let path else { return }
        guard clipboard.regionCapture == nil, clipboard.captureTask == nil else { return }
        guard !unifiedHUDVisible, !streamControlsVisible, !isShortcutsHelpVisible, !isHUDCustomizeVisible, !isPictureInPicture else { return }
        clipboard.captureTask = Task { @MainActor [weak self] in
            defer { self?.clipboard.captureTask = nil }
            guard let self else { return }
            guard let image = await path.takeScreenshot() else {
                self.showEmptyCaptureMessage(reason: .noFrame)
                return
            }
            self.clipboard.regionCapture = StreamRegionCapture(image: image)
            // The drag belongs to the reader, not the game, until the region is read or dismissed.
            self.nativeView?.remoteInputEnabled = false
            OPNStreamTelemetry.capture("nvst.ui.clipboard.region.opened", level: .info, message: "Region capture opened on a frozen frame.", attributes: ["applicationID": self.configuration.applicationID])
        }
    }

    /// Reads the rectangle the reader dragged over the frozen frame.
    func completeRegionCapture(_ visionRect: CGRect) {
        guard let regionCapture = clipboard.regionCapture else { return }
        clipboard.regionCapture = nil
        restoreClipboardInput()
        clipboard.captureTask = Task { @MainActor [weak self] in
            defer { self?.clipboard.captureTask = nil }
            guard let self else { return }
            let recognition = await self.clipboard.recognizer.recognizeText(in: regionCapture.image, preferredRegion: visionRect)
            guard !recognition.text.isEmpty else {
                self.showEmptyCaptureMessage(reason: .noTextInSelection)
                return
            }
            self.fileCapturedText(recognition.text, isSelectionUsed: true, at: Date())
            OPNStreamTelemetry.capture("nvst.ui.clipboard.region.read", level: .info, message: "Region capture read text from the frozen frame.", attributes: [
                "applicationID": self.configuration.applicationID,
                "characters": String(recognition.text.count),
            ])
        }
    }

    func cancelRegionCapture() {
        guard clipboard.regionCapture != nil else { return }
        clipboard.regionCapture = nil
        restoreClipboardInput()
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

    /// Drops one entry from the history.
    func removeClipboardEntry(_ entry: StreamClipboardEntry) {
        guard clipboard.store.remove(id: entry.id) else { return }
        if clipboard.pendingMerge?.entryID == entry.id { clipboard.pendingMerge = nil }
        reloadClipboardHistory()
        OPNStreamTelemetry.capture("nvst.ui.clipboard.removed", level: .info, message: "Clipboard history entry removed from the HUD.", attributes: ["applicationID": configuration.applicationID])
    }

    /// Two-step clear: the first call arms, the second performs.
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

    /// Switches the capture mode from the HUD, persisted.
    func setClipboardCaptureMode(_ mode: StreamTextCaptureMode) {
        guard clipboard.captureMode != mode else { return }
        if clipboard.regionCapture != nil { cancelRegionCapture() }
        clipboard.setCaptureMode(mode)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.capture_mode", level: .info, message: "Clipboard capture mode changed from the HUD.", attributes: [
            "applicationID": configuration.applicationID,
            "mode": mode.rawValue,
        ])
    }

    /// The pad's activate: steps through the modes in order, wrapping.
    func cycleClipboardCaptureMode() {
        let modes = StreamTextCaptureMode.allCases
        let nextIndex = (modes.firstIndex(of: clipboard.captureMode).map { $0 + 1 } ?? 0) % modes.count
        setClipboardCaptureMode(modes[nextIndex])
    }

    /// Files a read, completing a pending clipped entry when this read overlaps it.
    private func fileCapturedText(_ text: String, isSelectionUsed: Bool, at date: Date) {
        guard !completePendingRead(with: text, at: date) else { return }
        let isClipped = StreamTextCaptureFilter.isClipped(text)
        let storedEntry = clipboard.store.append(text: text, applicationID: configuration.applicationID, gameTitle: configuration.title)
        clipboard.pendingMerge = makePendingMerge(entryID: storedEntry?.id, text: text, isClipped: isClipped, at: date)
        reloadClipboardHistory()
        showNativeTransientStreamMessage(isClipped ? Self.StreamTextCaptureMessage.clipped : Self.StreamTextCaptureMessage.saved)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.saved", level: .info, message: "Frame text filed into the clipboard history.", attributes: [
            "applicationID": configuration.applicationID,
            "characters": String(text.count),
            "duplicate": String(storedEntry == nil),
            "scope": isSelectionUsed ? "selection" : "none",
            "clipped": String(isClipped),
        ])
    }

    /// Completes the pending clipped entry when this read overlaps it, and answers whether it did.
    private func completePendingRead(with text: String, at date: Date) -> Bool {
        guard let pendingMerge = clipboard.pendingMerge else { return false }
        guard date.timeIntervalSince(pendingMerge.capturedAt) <= Self.mergeWindow else { return false }
        guard let joinedText = StreamTextCaptureFilter.mergedOverlap(pendingMerge.text, text) else { return false }
        guard clipboard.store.replace(id: pendingMerge.entryID, text: joinedText) != nil else { return false }
        let isClipped = StreamTextCaptureFilter.isClipped(joinedText)
        clipboard.pendingMerge = makePendingMerge(entryID: pendingMerge.entryID, text: joinedText, isClipped: isClipped, at: date)
        reloadClipboardHistory()
        showNativeTransientStreamMessage(Self.StreamTextCaptureMessage.merged)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.merged", level: .info, message: "Two reads of one clipped text were joined.", attributes: [
            "applicationID": configuration.applicationID,
            "characters": String(joinedText.count),
            "clipped": String(isClipped),
        ])
        return true
    }

    /// Only a clipped read waits to be joined; a complete one has nothing to recover.
    private func makePendingMerge(entryID: UUID?, text: String, isClipped: Bool, at date: Date) -> PendingTextMerge? {
        guard let entryID, isClipped else { return nil }
        return PendingTextMerge(entryID: entryID, text: text, capturedAt: date)
    }

    private func restoreClipboardInput() {
        nativeView?.remoteInputEnabled = unifiedHUDVisible ? false : networkPathAvailable
        nativeView?.restoreInputFocus()
    }

    private func showEmptyCaptureMessage(reason: StreamTextCaptureEmptyReason) {
        let notice = Self.StreamTextCaptureMessage.EmptyReadNotice.make(reason: reason, mode: StreamTextCaptureSettings.mode)
        showNativeTransientStreamMessage(notice.message, duration: notice.duration)
        OPNStreamTelemetry.capture("nvst.ui.clipboard.empty", level: .info, message: "Frame text capture found nothing to file.", attributes: [
            "applicationID": configuration.applicationID,
            "reason": reason.label,
            "advisedRegion": String(notice.advisesRegionMode),
        ])
    }
}
