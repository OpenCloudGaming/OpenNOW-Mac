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
