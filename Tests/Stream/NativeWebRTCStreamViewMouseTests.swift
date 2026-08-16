import AppKit
import Testing
@testable import OpenNOW

private actor MouseInputRecorder {
    private var events: [NativeNVSTMouseInput] = []

    func append(_ event: NativeNVSTMouseInput) {
        events.append(event)
    }

    func snapshot() -> [NativeNVSTMouseInput] {
        events
    }
}

private struct MouseButtonTransition: Equatable {
    let button: MouseButton
    let isPressed: Bool
}

@Test @MainActor func streamViewBalancesMouseButtonTransitions() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.directMouseInputEnabled = false
    var events: [UserInputEvent] = []
    view.onInputEvent = { events.append($0) }
    let mouseDown = try #require(makeMouseEvent(type: .leftMouseDown))
    let mouseUp = try #require(makeMouseEvent(type: .leftMouseUp))

    view.mouseDown(with: mouseDown)
    view.mouseDown(with: mouseDown)
    view.mouseUp(with: mouseUp)
    view.mouseUp(with: mouseUp)

    #expect(mouseButtonTransitions(events) == [
        MouseButtonTransition(button: .left, isPressed: true),
        MouseButtonTransition(button: .left, isPressed: false),
    ])
}

@Test @MainActor func pointerUnlockReleasesHeldMouseButtonsOnce() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    view.hidesCursorWhilePointerLocked = false
    window.contentView = view
    var events: [UserInputEvent] = []
    var releaseObservedWhileLocked = false
    view.onInputEvent = { event in
        events.append(event)
        if case .mouse(.button(_, .right, false, _)) = event {
            releaseObservedWhileLocked = view.isPointerLocked
        }
    }
    let mouseDown = try #require(makeMouseEvent(type: .leftMouseDown))
    let rightMouseDown = try #require(makeMouseEvent(type: .rightMouseDown))
    let rightMouseUp = try #require(makeMouseEvent(type: .rightMouseUp))

    view.mouseDown(with: mouseDown)
    view.rightMouseDown(with: rightMouseDown)
    view.setPointerLocked(false)
    view.rightMouseUp(with: rightMouseUp)

    #expect(mouseButtonTransitions(events) == [
        MouseButtonTransition(button: .right, isPressed: true),
        MouseButtonTransition(button: .right, isPressed: false),
    ])
    #expect(releaseObservedWhileLocked)
}

@Test @MainActor func pointerCaptureSuppressesTheCompleteActivationClick() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: .borderless, backing: .buffered, defer: false)
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    view.hidesCursorWhilePointerLocked = false
    window.contentView = view
    var events: [UserInputEvent] = []
    view.onInputEvent = { events.append($0) }
    let mouseDown = try #require(makeMouseEvent(type: .leftMouseDown))
    let mouseUp = try #require(makeMouseEvent(type: .leftMouseUp))
    defer { view.setPointerLocked(false) }

    view.mouseDown(with: mouseDown)
    view.mouseUp(with: mouseUp)

    #expect(view.isPointerLocked)
    #expect(mouseButtonTransitions(events).isEmpty)
}

@Test @MainActor func streamViewHidesCursorWhilePointerLockedByDefault() {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))

    #expect(view.hidesCursorWhilePointerLocked)
}

@Test @MainActor func streamViewLeavesApplicationMenuKeyEquivalentsLocal() {
    #expect(NativeWebRTCStreamView.reservesApplicationMenuKeyEquivalent(.command))
    #expect(NativeWebRTCStreamView.reservesApplicationMenuKeyEquivalent([.command, .shift]))
    #expect(!NativeWebRTCStreamView.reservesApplicationMenuKeyEquivalent(.option))
    #expect(!NativeWebRTCStreamView.reservesApplicationMenuKeyEquivalent(.control))
}

@Test @MainActor func streamViewOnlyCapturesKeysFromItsOwnWindow() {
    let streamWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
    let menuWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)

    #expect(NativeWebRTCStreamView.isStreamWindowKeyEvent(streamWindow, streamWindow: streamWindow))
    #expect(!NativeWebRTCStreamView.isStreamWindowKeyEvent(menuWindow, streamWindow: streamWindow))
    #expect(!NativeWebRTCStreamView.isStreamWindowKeyEvent(nil, streamWindow: streamWindow))
}

@Test @MainActor func absoluteMouseModeMapsDisplayedVideoCoordinates() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    view.mouseInputMode = .absolute
    view.setStreamContentSize(width: 1920, height: 1080)
    view.layoutSubtreeIfNeeded()
    let timestamp = MediaTimestamp(nanoseconds: 1_000)

    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 500), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 800, y: 450, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 0, y: 50), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 0, y: 899, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 1599, y: 949), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 1599, y: 1, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 25), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 800, y: 899, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 800, y: 975), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 800, y: 0, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: -100, y: 500), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 0, y: 450, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: 1700, y: 500), timestamp: timestamp) == NativeNVSTAbsoluteMouseEvent(x: 1599, y: 450, timestamp: timestamp))
    #expect(view.absoluteMouseEvent(at: CGPoint(x: CGFloat.nan, y: 500), timestamp: timestamp) == nil)
}

@Test @MainActor func absoluteMouseModeForwardsCompleteClickWithoutPointerLock() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.mouseInputMode = .absolute
    var events: [UserInputEvent] = []
    var sequence: [String] = []
    view.onAbsoluteMouseMove = { event in sequence.append("position:\(event.x),\(event.y)") }
    view.onInputEvent = { event in
        events.append(event)
        if case .mouse(.button(_, _, let isPressed, _)) = event { sequence.append(isPressed ? "down" : "up") }
    }
    let mouseDown = try #require(makeMouseEvent(type: .leftMouseDown))
    let mouseUp = try #require(makeMouseEvent(type: .leftMouseUp))

    view.mouseDown(with: mouseDown)
    view.mouseUp(with: mouseUp)

    #expect(!view.isPointerLocked)
    #expect(mouseButtonTransitions(events) == [
        MouseButtonTransition(button: .left, isPressed: true),
        MouseButtonTransition(button: .left, isPressed: false),
    ])
    #expect(sequence == ["position:0,719", "down", "position:0,719", "up"])
}

@Test @MainActor func absoluteMouseModeClampsLetterboxClickBeforeEachButtonEdge() throws {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
    view.mouseInputMode = .absolute
    view.setStreamContentSize(width: 1920, height: 1080)
    view.layoutSubtreeIfNeeded()
    var sequence: [String] = []
    view.onAbsoluteMouseMove = { event in sequence.append("position:\(event.x),\(event.y)") }
    view.onInputEvent = { event in
        if case .mouse(.button(_, _, let isPressed, _)) = event { sequence.append(isPressed ? "down" : "up") }
    }
    let location = NSPoint(x: 800, y: 975)
    let mouseDown = try #require(makeMouseEvent(type: .leftMouseDown, location: location))
    let mouseUp = try #require(makeMouseEvent(type: .leftMouseUp, location: location))

    view.mouseDown(with: mouseDown)
    view.mouseUp(with: mouseUp)

    #expect(sequence == ["position:800,0", "down", "position:800,0", "up"])
}

@Test func nativeNVSTMouseDispatcherPreservesEventOrder() async {
    let recorder = MouseInputRecorder()
    let dispatcher = NativeNVSTMouseInputDispatcher { event in
        if case .event(.mouse(.button(_, .left, true, _))) = event {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        await recorder.append(event)
    }
    let timestamp = MediaTimestamp(nanoseconds: 1_000)
    let events: [UserInputEvent] = [
        .mouse(.button(deviceID: "mouse", button: .left, isPressed: true, timestamp: timestamp)),
        .mouse(.moved(deviceID: "mouse", deltaX: 4, deltaY: -2, timestamp: timestamp)),
        .mouse(.wheel(deviceID: "mouse", delta: 120, timestamp: timestamp)),
        .mouse(.button(deviceID: "mouse", button: .left, isPressed: false, timestamp: timestamp)),
    ]

    dispatcher.enqueue(events[0])
    dispatcher.enqueueAbsoluteMove(NativeNVSTAbsoluteMouseEvent(x: 640, y: 360, timestamp: timestamp))
    events.dropFirst().forEach { dispatcher.enqueue($0) }
    await dispatcher.finish()

    #expect(await recorder.snapshot() == [
        .event(events[0]),
        .absoluteMove(NativeNVSTAbsoluteMouseEvent(x: 640, y: 360, timestamp: timestamp)),
        .event(events[1]),
        .event(events[2]),
        .event(events[3]),
    ])
}

@MainActor private func makeMouseEvent(type: NSEvent.EventType, location: NSPoint = .zero) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}

private func mouseButtonTransitions(_ events: [UserInputEvent]) -> [MouseButtonTransition] {
    events.compactMap { event in
        guard case .mouse(.button(_, let button, let isPressed, _)) = event else { return nil }
        return MouseButtonTransition(button: button, isPressed: isPressed)
    }
}
