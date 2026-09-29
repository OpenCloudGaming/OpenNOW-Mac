import AppKit
import Foundation
import Testing
@testable import OpenNOW

/// How the copy chords route: Command-C fires the capture and hands the seat the Control-C macOS
/// would otherwise have eaten; Control-C fires the capture and keeps travelling to the seat
/// untouched. Both ends are asserted, because getting only one right breaks either the game's copy
/// or the whole point of the feature.
@MainActor
struct StreamTextCaptureRoutingTests {
    private func keyEvent(
        _ type: NSEvent.EventType,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }

    private func makeView() -> (view: NativeStreamView, commands: () -> [StreamCommand], input: () -> [UserInputEvent]) {
        // The feature is behind an off-by-default Labs flag; enable it and leave it on, since it is a
        // preference no test asserts is off.
        OPNLabs.setEnabled(OPNLabs.clipboardCapture, true)
        // The shared store may have been customized in this process; the chords under test are the
        // shipped ones, so the binding goes back to its default first.
        OPNKeybindings.standard.reset(.captureStreamText)
        let view = NativeStreamView(frame: .zero)
        var commands: [StreamCommand] = []
        var input: [UserInputEvent] = []
        view.shouldHandleCommand = { _ in true }
        view.onCommand = { commands.append($0) }
        view.onInputEvent = { input.append($0) }
        return (view, { commands }, { input })
    }

    private func keyboardStrokes(_ input: [UserInputEvent]) -> [(keyCode: UInt16, isPressed: Bool)] {
        input.compactMap { event in
            guard case .keyboard(let keyboard) = event else { return nil }
            return (keyboard.keyCode, keyboard.isPressed)
        }
    }

    @Test func commandCopyFiresTheCaptureAndTranslatesToControl() throws {
        let (view, commands, input) = makeView()
        let down = try keyEvent(.keyDown, keyCode: 8, modifiers: .command, characters: "c")
        #expect(view.handleTextCaptureShortcut(down))
        #expect(commands() == [.captureStreamText])
        let strokes = keyboardStrokes(input())
        #expect(strokes.map(\.keyCode) == [55, 8, 8, 55])
        #expect(strokes.map(\.isPressed) == [true, true, false, false])
    }

    @Test func controlCopyFiresTheCaptureAndStillReachesTheSeat() throws {
        let (view, commands, input) = makeView()
        let down = try keyEvent(.keyDown, keyCode: 8, modifiers: .control, characters: "c")
        #expect(view.handleTextCaptureShortcut(down))
        #expect(commands() == [.captureStreamText])
        let strokes = keyboardStrokes(input())
        // Exactly the one key-down the ordinary forward path would have sent: no translation, no
        // extra strokes, nothing swallowed.
        #expect(strokes.map(\.keyCode) == [8])
        #expect(strokes.map(\.isPressed) == [true])
        let keyboard = input().compactMap { event -> KeyboardEvent? in
            guard case .keyboard(let keyboard) = event else { return nil }
            return keyboard
        }
        #expect(keyboard.first?.modifiers.contains(.control) == true)
    }

    @Test func controlCopyReleaseAlsoReachesTheSeat() throws {
        let (view, _, input) = makeView()
        let up = try keyEvent(.keyUp, keyCode: 8, modifiers: .control, characters: "c")
        #expect(view.handleTextCaptureShortcut(up))
        let strokes = keyboardStrokes(input())
        #expect(strokes.map(\.keyCode) == [8])
        #expect(strokes.map(\.isPressed) == [false])
    }

    @Test func aChordBoundToSomethingElseIsNotClaimed() throws {
        let (view, _, _) = makeView()
        let down = try keyEvent(.keyDown, keyCode: 40, modifiers: .command, characters: "k")
        #expect(!view.handleTextCaptureShortcut(down))
    }
}
