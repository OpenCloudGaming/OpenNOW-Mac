import AppKit
import Testing
@testable import OpenNOW

private actor NativeInputRecorder {
    private var inputs: [NativeNVSTInput] = []

    func append(_ input: NativeNVSTInput) {
        inputs.append(input)
    }

    func snapshot() -> [NativeNVSTInput] {
        inputs
    }
}

private actor ControlledNativeInputRecorder {
    private var inputs: [NativeNVSTInput] = []
    private var blocked = true
    private var unblockContinuation: CheckedContinuation<Void, Never>?
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func append(_ input: NativeNVSTInput) async {
        inputs.append(input)
        let readyWaiters = countWaiters.filter { inputs.count >= $0.0 }
        countWaiters.removeAll { inputs.count >= $0.0 }
        readyWaiters.forEach { $0.1.resume() }
        guard blocked else { return }
        await withCheckedContinuation { continuation in
            unblockContinuation = continuation
        }
    }

    func waitForCount(_ count: Int) async {
        guard inputs.count < count else { return }
        await withCheckedContinuation { continuation in
            countWaiters.append((count, continuation))
        }
    }

    func unblock() {
        blocked = false
        unblockContinuation?.resume()
        unblockContinuation = nil
    }

    func snapshot() -> [NativeNVSTInput] {
        inputs
    }
}

@Test func nativeNVSTDispatcherOrdersEveryInputCategory() async {
    let recorder = NativeInputRecorder()
    let dispatcher = NativeNVSTInputDispatcher { input in
        if case .event(.keyboard(_)) = input {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await recorder.append(input)
    }
    let timestamp = MediaTimestamp(nanoseconds: 1_000)
    let keyboard = UserInputEvent.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 0, scanCode: 0, modifiers: [], isPressed: true, timestamp: timestamp))
    let text = UserInputEvent.text(deviceID: "keyboard", value: "a", timestamp: timestamp)
    let gamepad = UserInputEvent.gamepad(GamepadState(deviceID: "controller", playerIndex: 0, buttons: .south, timestamp: timestamp))
    let mouse = UserInputEvent.mouse(.moved(deviceID: "mouse", deltaX: 2, deltaY: -1, timestamp: timestamp))
    let absolute = NativeNVSTAbsoluteMouseEvent(x: 100, y: 200, timestamp: timestamp)

    dispatcher.enqueue(keyboard)
    dispatcher.enqueue(text)
    dispatcher.enqueue(gamepad)
    dispatcher.enqueueAbsoluteMove(absolute)
    dispatcher.enqueue(mouse)
    await dispatcher.finish()

    #expect(await recorder.snapshot() == [.event(keyboard), .event(text), .event(gamepad), .absoluteMove(absolute), .event(mouse)])
}

@Test func nativeNVSTFocusGuardAcceptsAllNeutralTransitions() {
    let timestamp = MediaTimestamp(nanoseconds: 1_000)

    #expect(NativeNVSTInputDispatcher.isNeutralizing(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 0, scanCode: 0, modifiers: [], isPressed: false, timestamp: timestamp))))
    #expect(NativeNVSTInputDispatcher.isNeutralizing(.mouse(.button(deviceID: "mouse", button: .left, isPressed: false, timestamp: timestamp))))
    #expect(NativeNVSTInputDispatcher.isNeutralizing(.gamepad(GamepadState(deviceID: "controller", playerIndex: 0, timestamp: timestamp))))
    #expect(!NativeNVSTInputDispatcher.isNeutralizing(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 0, scanCode: 0, modifiers: [], isPressed: true, timestamp: timestamp))))
    #expect(!NativeNVSTInputDispatcher.isNeutralizing(.gamepad(GamepadState(deviceID: "controller", playerIndex: 0, buttons: .south, timestamp: timestamp))))
}

@Test func nativeNVSTDispatcherCoalescesAdjacentRelativeMotionWithoutReorderingButtons() async {
    let recorder = ControlledNativeInputRecorder()
    let dispatcher = NativeNVSTInputDispatcher(capacity: 4) { input in
        await recorder.append(input)
    }
    let timestamp = MediaTimestamp(nanoseconds: 1_000)
    let press = UserInputEvent.mouse(.button(deviceID: "mouse", button: .left, isPressed: true, timestamp: timestamp))
    let release = UserInputEvent.mouse(.button(deviceID: "mouse", button: .left, isPressed: false, timestamp: timestamp))

    dispatcher.enqueue(press)
    await recorder.waitForCount(1)
    dispatcher.enqueue(.mouse(.moved(deviceID: "mouse", deltaX: 4, deltaY: -2, timestamp: timestamp)))
    dispatcher.enqueue(.mouse(.moved(deviceID: "mouse", deltaX: 3, deltaY: 5, timestamp: MediaTimestamp(nanoseconds: 2_000))))
    dispatcher.enqueue(release)
    await recorder.unblock()
    await recorder.waitForCount(3)
    await dispatcher.finish()

    #expect(await recorder.snapshot() == [
        .event(press),
        .event(.mouse(.moved(deviceID: "mouse", deltaX: 7, deltaY: 3, timestamp: MediaTimestamp(nanoseconds: 2_000)))),
        .event(release),
    ])
}

@Test func nativeNVSTDispatcherBoundsBacklogAndRetainsNeutralizationAtShutdown() async {
    let recorder = ControlledNativeInputRecorder()
    let dispatcher = NativeNVSTInputDispatcher(capacity: 3) { input in
        await recorder.append(input)
    }
    let timestamp = MediaTimestamp(nanoseconds: 1_000)
    let keyPress = UserInputEvent.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 0, scanCode: 0, modifiers: [], isPressed: true, timestamp: timestamp))
    let keyRelease = UserInputEvent.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: 0, scanCode: 0, modifiers: [], isPressed: false, timestamp: timestamp))
    let gamepadNeutral = UserInputEvent.gamepad(GamepadState(deviceID: "controller", playerIndex: 0, timestamp: timestamp))

    dispatcher.enqueue(keyPress)
    await recorder.waitForCount(1)
    for playerIndex in 0..<20 {
        dispatcher.enqueue(.gamepad(GamepadState(deviceID: "controller-\(playerIndex)", playerIndex: playerIndex, leftStickX: 0.5, timestamp: timestamp)))
        #expect(dispatcher.pendingInputCount <= 3)
    }
    dispatcher.enqueue(keyRelease)
    dispatcher.enqueue(gamepadNeutral)
    #expect(dispatcher.pendingInputCount <= 3)
    let finishTask = Task { await dispatcher.finish() }
    await recorder.unblock()
    await finishTask.value

    #expect(await recorder.snapshot() == [.event(keyPress), .event(keyRelease), .event(gamepadNeutral)])
}

@Test @MainActor func focusLossNeutralizesEveryActiveDeviceBeforePointerUnlock() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    view.hidesCursorWhilePointerLocked = false
    window.contentView = view
    var sequence: [String] = []
    view.onInputEvent = { event in
        switch event {
        case .keyboard(let keyboard) where !keyboard.isPressed: sequence.append("keyboard-neutral")
        case .mouse(.button(_, _, false, _)): sequence.append("mouse-neutral")
        case .gamepad(let state) where state.buttons.isEmpty: sequence.append("gamepad-neutral")
        default: break
        }
    }
    view.onPointerLockChanged = { locked in
        if !locked { sequence.append("pointer-unlocked") }
    }
    let activationClick = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let rightMouseDown = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    let keyDown = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))

    view.mouseDown(with: activationClick)
    view.rightMouseDown(with: rightMouseDown)
    view.keyDown(with: keyDown)
    view.receiveGamepadState(GamepadState(deviceID: "controller", playerIndex: 2, buttons: .south, timestamp: MediaTimestamp(nanoseconds: 1_000)))
    sequence.removeAll()
    view.handleFocusLoss()

    #expect(Set(sequence.dropLast()) == Set(["keyboard-neutral", "mouse-neutral", "gamepad-neutral"]))
    #expect(sequence.last == "pointer-unlocked")
    #expect(!view.isPointerLocked)
}

@Test func gamepadSlotsRemainStableAndReuseOnlyVacatedPlayers() {
    var slots = NativeWebRTCGamepadSlotMap<String>()

    #expect(slots.update(identifiers: ["a", "b", "c"]).isEmpty)
    #expect(slots.slots == ["a": 0, "b": 1, "c": 2])
    let removed = slots.update(identifiers: ["b", "c", "d"])

    #expect(removed.count == 1)
    #expect(removed.first?.identifier == "a")
    #expect(removed.first?.playerIndex == 0)
    #expect(slots.slots == ["b": 1, "c": 2, "d": 0])
    #expect(NativeWebRTCGamepadTopology(playerIndices: Array(slots.slots.values)).registrationBitmap == 0x0707)
}

@Test func nativeTextCompositionUsesUTF16RangesAndCommitsMarkedText() throws {
    var state = NativeNVSTTextInputState()
    state.setMarkedText(NSAttributedString(string: "拼音"), selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(state.hasMarkedText)
    #expect(state.markedRange == NSRange(location: 0, length: 2))
    #expect(state.selection == NSRange(location: 2, length: 0))
    let substring = try #require(state.attributedSubstring(for: NSRange(location: 1, length: 4)))
    #expect(substring.0.string == "音")
    #expect(substring.1 == NSRange(location: 1, length: 1))

    state.setMarkedText(NSAttributedString(string: "😀"), selectedRange: NSRange(location: 2, length: 4), replacementRange: NSRange(location: 0, length: 2))
    #expect(state.markedRange == NSRange(location: 0, length: 2))
    #expect(state.selection == NSRange(location: 2, length: 0))
    #expect(state.unmark() == "😀")
    #expect(!state.hasMarkedText)
}

@Test func nativeTextCompositionCancelDropsUncommittedText() {
    var state = NativeNVSTTextInputState()
    state.setMarkedText(NSAttributedString(string: "e\u{301}"), selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    state.cancel()

    #expect(!state.hasMarkedText)
    #expect(state.unmark() == nil)
}

@Test @MainActor func nativeTextClientEmitsOnlyCommittedUnicode() {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var values: [String] = []
    view.onInputEvent = { event in
        if case .text(_, let value, _) = event { values.append(value) }
    }

    view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(values.isEmpty)
    view.insertText(NSAttributedString(string: "你😀"), replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(values == ["你😀"])
    #expect(!view.hasMarkedText())
}

@Test @MainActor func nativeTextRoutingPreservesASCIIPhysicalKeysAndUsesIMEComposition() throws {
    let ascii = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    let deadKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "e", isARepeat: false, keyCode: 14))

    #expect(!NativeWebRTCStreamView.shouldInterpretAsText(ascii, hasMarkedText: false, inputSourceID: "com.apple.keylayout.US"))
    #expect(NativeWebRTCStreamView.shouldInterpretAsText(ascii, hasMarkedText: false, inputSourceID: "com.apple.inputmethod.SCIM.ITABC"))
    #expect(NativeWebRTCStreamView.shouldInterpretAsText(deadKey, hasMarkedText: false, inputSourceID: "com.apple.keylayout.US"))
}

@Test func nativePushToTalkIsEdgeTriggeredAndRequiresConfiguredModifiers() {
    var states: [Bool] = []
    let pushToTalk = NativeNVSTPushToTalkState(keyCode: 9, modifierMask: Int(KeyboardModifiers.control.rawValue)) { states.append($0) }
    let timestamp = MediaTimestamp(nanoseconds: 1)
    let wrongModifiers = KeyboardEvent(deviceID: "keyboard", keyCode: 9, scanCode: 9, modifiers: [], isPressed: true, timestamp: timestamp)
    let press = KeyboardEvent(deviceID: "keyboard", keyCode: 9, scanCode: 9, modifiers: [.control], isPressed: true, timestamp: timestamp)
    let release = KeyboardEvent(deviceID: "keyboard", keyCode: 9, scanCode: 9, modifiers: [], isPressed: false, timestamp: timestamp)

    #expect(!pushToTalk.handle(wrongModifiers))
    #expect(pushToTalk.handle(press))
    #expect(pushToTalk.handle(press))
    #expect(pushToTalk.handle(release))
    #expect(states == [true, false])
}

@Test @MainActor func nativePushToTalkReleasesOnFocusLoss() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var states: [Bool] = []
    view.configurePushToTalk(keyCode: 9) { states.append($0) }
    let press = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))

    view.keyDown(with: press)
    view.handleFocusLoss()

    #expect(states == [true, false])
}

@Test @MainActor func nativePushToTalkKeepsPressedStateAcrossViewReconfiguration() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    var initialStates: [Bool] = []
    var updatedStates: [Bool] = []
    view.configurePushToTalk(keyCode: 9) { initialStates.append($0) }
    let press = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
    let release = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))

    view.keyDown(with: press)
    view.configurePushToTalk(keyCode: 9) { updatedStates.append($0) }
    view.keyUp(with: release)

    #expect(initialStates == [true])
    #expect(updatedStates == [false])
}
