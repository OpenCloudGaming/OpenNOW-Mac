import Foundation
import Testing
@testable import OpenNOW

/// OCR filtering and the cooldown, apart from Vision so they run without rendering a frame.
struct StreamTextCaptureFilterTests {
    @Test func lowConfidenceLinesAreDropped() {
        let text = StreamTextCaptureFilter.acceptedText(from: [
            StreamRecognizedLine(text: "confident", confidence: 0.9),
            StreamRecognizedLine(text: "guess", confidence: 0.1),
        ])
        #expect(text == "confident")
    }

    @Test func shortLinesAreDroppedAsHudNoise() {
        let text = StreamTextCaptureFilter.acceptedText(from: [
            StreamRecognizedLine(text: "99", confidence: 0.95),
            StreamRecognizedLine(text: "Health", confidence: 0.9),
        ])
        #expect(text == "Health")
    }

    @Test func survivingLinesKeepTheirOrderAndJoinOnNewlines() {
        let text = StreamTextCaptureFilter.acceptedText(from: [
            StreamRecognizedLine(text: "  first line  ", confidence: 0.8),
            StreamRecognizedLine(text: "second line", confidence: 0.8),
        ])
        #expect(text == "first line\nsecond line")
    }

    @Test func anEmptyFrameYieldsEmptyText() {
        #expect(StreamTextCaptureFilter.acceptedText(from: []).isEmpty)
        #expect(StreamTextCaptureFilter.acceptedText(from: [StreamRecognizedLine(text: "x", confidence: 1)]).isEmpty)
    }

    // MARK: - Joining a clipped read

    @Test func anOverlappingTailCompletesTheHead() {
        #expect(StreamTextCaptureFilter.mergedOverlap("Check out the entire collection on", "collection on Steam") == "Check out the entire collection on Steam")
    }

    @Test func theJoinWorksWhicheverHalfWasCopiedFirst() {
        #expect(StreamTextCaptureFilter.mergedOverlap("collection on Steam", "Check out the entire collection on") == "Check out the entire collection on Steam")
    }

    @Test func oneReadContainingTheOtherWins() {
        #expect(StreamTextCaptureFilter.mergedOverlap("Check out the entire collection on Steam", "collection on Steam") == "Check out the entire collection on Steam")
        #expect(StreamTextCaptureFilter.mergedOverlap("same", "same") == "same")
    }

    /// A field can scroll by a whole page, leaving characters that were never rendered at all. Two
    /// reads with nothing in common must stay two entries rather than be spliced into an invented one.
    @Test func readsWithNothingInCommonAreNotJoined() {
        #expect(StreamTextCaptureFilter.mergedOverlap("Check out the entire", "on Steam") == nil)
        #expect(StreamTextCaptureFilter.mergedOverlap("abreaaca", "MY ACHIEVEMENTS") == nil)
    }

    @Test func aShortOverlapIsNotProofEnough() {
        #expect(StreamTextCaptureFilter.mergedOverlap("abc", "cd") == nil)
        #expect(StreamTextCaptureFilter.mergedOverlap("abcdef", "defghi") == "abcdefghi")
    }

    @Test func anEmptyHalfChangesNothing() {
        #expect(StreamTextCaptureFilter.mergedOverlap("", "tail") == nil)
        #expect(StreamTextCaptureFilter.mergedOverlap("head", "") == nil)
    }

    // MARK: - Clipped text

    @Test func aTrailingEllipsisReadsAsClipped() {
        #expect(StreamTextCaptureFilter.isClipped("Check out the entire collection on\u{2026}"))
        #expect(StreamTextCaptureFilter.isClipped("Check out the entire collection on..."))
        #expect(StreamTextCaptureFilter.isClipped("  trailing space after the clip\u{2026}  "))
    }

    @Test func completeTextIsNotClipped() {
        #expect(!StreamTextCaptureFilter.isClipped("Check out the entire collection on Steam"))
        #expect(!StreamTextCaptureFilter.isClipped("Ends with a full stop."))
        #expect(!StreamTextCaptureFilter.isClipped(""))
    }

    // MARK: - Selection scope

    /// Highlights are read top-of-frame first, the order whole-frame lines come back in.
    @Test func highlightsAreReadTopToBottom() {
        let lower = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.05)
        let upper = CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.05)
        #expect(StreamTextCaptureFilter.readingOrder([lower, upper]) == [upper, lower])
    }

    private func line(_ text: String, _ rect: CGRect) -> StreamRecognizedLine {
        StreamRecognizedLine(text: text, confidence: 0.9, bounds: rect)
    }

    /// A highlight hugs its line: a little taller, a little wider.
    @Test func aHighlightHuggingItsLineIsASelection() {
        let block = CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.06)
        #expect(StreamTextCaptureFilter.isTextSelection(block, lines: [line("selected", CGRect(x: 0.12, y: 0.51, width: 0.36, height: 0.05))]))
    }

    /// A multi-line selection is one block over all of the lines it covers.
    @Test func aMultiLineHighlightIsASelection() {
        let block = CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.15)
        let lines = [
            line("first", CGRect(x: 0.12, y: 0.31, width: 0.45, height: 0.04)),
            line("second", CGRect(x: 0.12, y: 0.41, width: 0.45, height: 0.04)),
        ]
        #expect(StreamTextCaptureFilter.isTextSelection(block, lines: lines))
    }

    /// A button is a big filled rectangle with a small label centred in it, which is not a selection.
    @Test func aButtonIsNotASelection() {
        let block = CGRect(x: 0.6, y: 0.8, width: 0.35, height: 0.09)
        #expect(!StreamTextCaptureFilter.isTextSelection(block, lines: [line("Add to your wishlist", CGRect(x: 0.7, y: 0.82, width: 0.15, height: 0.028))]))
    }

    /// A short label on a full-width button is the shape that used to slip through: not tall enough
    /// to fail the height bound, but many times wider than its own word.
    @Test func aWideShortButtonIsNotASelection() {
        let block = CGRect(x: 0.1, y: 0.3, width: 0.6, height: 0.09)
        #expect(!StreamTextCaptureFilter.isTextSelection(block, lines: [line("Copy", CGRect(x: 0.4, y: 0.32, width: 0.09, height: 0.07))]))
    }

    /// A field with generous highlight padding runs taller than its line, and is still a selection.
    @Test func aRoomierFieldHighlightIsStillASelection() {
        let block = CGRect(x: 0.2, y: 0.5, width: 0.5, height: 0.05)
        #expect(StreamTextCaptureFilter.isTextSelection(block, lines: [line("0b4b75c0681540df", CGRect(x: 0.21, y: 0.512, width: 0.45, height: 0.026))]))
    }

    /// The other direction: a highlight can be shorter than Vision's line box, because that box
    /// carries ascenders and descenders the field does not paint. A selected password measured 0.72
    /// of its own line on a real stream and was dropped by the old 0.85 floor.
    @Test func aHighlightShorterThanItsLineBoxIsStillASelection() {
        let block = CGRect(x: 0.5375, y: 0.7481, width: 0.0250, height: 0.0148)
        #expect(StreamTextCaptureFilter.isTextSelection(block, lines: [line("R525aa", CGRect(x: 0.5378, y: 0.7457, width: 0.0262, height: 0.0206))]))
    }

    /// A run of coloured text has no block around it: the "block" is the glyphs, so it comes out
    /// clearly narrower than the line box Vision reports.
    @Test func aRunOfColouredTextIsNotASelection() {
        let block = CGRect(x: 0.2, y: 0.4, width: 0.08, height: 0.03)
        #expect(!StreamTextCaptureFilter.isTextSelection(block, lines: [line("heading", CGRect(x: 0.2, y: 0.4, width: 0.12, height: 0.03))]))
    }

    /// A field's highlight is drawn tight, so it can come out a hair narrower than the line box —
    /// measured at 0.97 on a real selected word in a game's text field. That is still a selection.
    @Test func aHighlightATouchNarrowerThanTheLineBoxIsStillASelection() {
        let block = CGRect(x: 0.4, y: 0.7, width: 0.045, height: 0.03)
        #expect(StreamTextCaptureFilter.isTextSelection(block, lines: [line("abreaaca", CGRect(x: 0.41, y: 0.705, width: 0.046, height: 0.024))]))
    }

    @Test func aBlockWithNoTextInItIsNotASelection() {
        let block = CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.06)
        #expect(!StreamTextCaptureFilter.isTextSelection(block, lines: []))
    }

    /// A highlight is expanded before it is read: Vision wants a margin around the glyphs, and the
    /// margin is proportional so it works for a small chat line and a large subtitle alike.
    @Test func aHighlightIsExpandedForReading() {
        let rect = CGRect(x: 0.2, y: 0.4, width: 0.3, height: 0.04)
        let inflated = StreamTextRecognizer.inflatedSelection(rect)
        #expect(inflated.minX < rect.minX)
        #expect(inflated.maxX > rect.maxX)
        #expect(inflated.minY < rect.minY)
        #expect(inflated.maxY > rect.maxY)
        #expect(inflated.width <= 1 && inflated.height <= 1)
    }

    @Test func aHighlightAtTheEdgeStaysInsideTheFrame() {
        let rect = CGRect(x: 0, y: 0, width: 0.1, height: 0.03)
        let inflated = StreamTextRecognizer.inflatedSelection(rect)
        #expect(inflated.minX >= 0 && inflated.minY >= 0)
        #expect(inflated.maxX <= 1 && inflated.maxY <= 1)
    }
}

struct StreamTextCaptureCooldownTests {
    @Test func theFirstCaptureIsAlwaysAllowed() {
        let cooldown = StreamTextCaptureCooldown(interval: 2)
        #expect(cooldown.allowsCapture(at: Date()))
    }

    @Test func aPressInsideTheWindowIsHeldOff() {
        let start = Date()
        var cooldown = StreamTextCaptureCooldown(interval: 2)
        cooldown.recordCapture(at: start)
        #expect(!cooldown.allowsCapture(at: start.addingTimeInterval(1)))
        #expect(cooldown.allowsCapture(at: start.addingTimeInterval(2)))
    }
}

/// The feature is behind a Labs flag that is off by default, so a test of anything it offers has to
/// turn it on. The flag is process-global and left on: it is a preference, not a fixture, and no
/// test asserts it is off.
private func enableClipboardCaptureLabsFlag() {
    OPNLabs.setEnabled(OPNLabs.clipboardCapture, true)
}

/// The rebindable chords behind the capture. A private defaults suite keeps this parallel-safe.
private func makeCaptureKeybindings() -> OPNKeybindings {
    let suiteName = "OpenNOWTests.ClipboardKeys.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("could not create a defaults suite named \(suiteName)")
        return OPNKeybindings(storage: .standard)
    }
    return OPNKeybindings(storage: OPNAppPreferenceStorage(defaults: defaults, defaultsDomain: suiteName))
}

struct StreamTextCaptureShortcutTests {
    @Test func itShipsOnBothCopyChords() {
        enableClipboardCaptureLabsFlag()
        let bindings = makeCaptureKeybindings()
        #expect(bindings.resolvedAction(keyCode: 8, modifierFlags: .command, in: .stream) == .captureStreamText)
        #expect(bindings.resolvedAction(keyCode: 8, modifierFlags: .control, in: .stream) == .captureStreamText)
    }

    @Test func rebindingReplacesBothDefaultChords() {
        enableClipboardCaptureLabsFlag()
        let bindings = makeCaptureKeybindings()
        bindings.assign(OPNKeyCombo(keyCode: 9, modifiers: [.command, .shift]), to: .captureStreamText)
        #expect(bindings.resolvedAction(keyCode: 9, modifierFlags: [.command, .shift], in: .stream) == .captureStreamText)
        #expect(bindings.resolvedAction(keyCode: 8, modifierFlags: .command, in: .stream) == nil)
        #expect(bindings.resolvedAction(keyCode: 8, modifierFlags: .control, in: .stream) == nil)
    }

    @Test func disablingRemovesEveryChordAndResetRestoresThem() {
        enableClipboardCaptureLabsFlag()
        let bindings = makeCaptureKeybindings()
        bindings.setEnabled(false, for: .captureStreamText)
        #expect(!bindings.isEnabled(.captureStreamText))
        #expect(bindings.combos(for: .captureStreamText).isEmpty)
        #expect(bindings.resolvedAction(keyCode: 8, modifierFlags: .command, in: .stream) == nil)
        bindings.reset(.captureStreamText)
        #expect(bindings.isEnabled(.captureStreamText))
        #expect(bindings.resolvedAction(keyCode: 8, modifierFlags: .control, in: .stream) == .captureStreamText)
    }

    @Test func nothingElseInTheStreamSharesTheCopyChords() {
        enableClipboardCaptureLabsFlag()
        let bindings = makeCaptureKeybindings()
        #expect(bindings.conflictingActions(for: .captureStreamText).isEmpty)
    }

    /// The translation the seat receives: Control wraps the whole chord and both keys are released,
    /// in order, so no failure path can leave Control held.
    @Test func theTranslatedCopyReleasesBothKeysInOrder() {
        let strokes = NativeStreamView.commandShortcutStrokes(keyCode: 8, shift: false, option: false)
        #expect(strokes.map(\.keyCode) == [55, 8, 8, 55])
        #expect(strokes.map(\.isPressed) == [true, true, false, false])
        #expect(strokes.filter { $0.keyCode == 55 }.count == 2)
        #expect(strokes.filter { $0.keyCode == 8 }.count == 2)
    }
}
