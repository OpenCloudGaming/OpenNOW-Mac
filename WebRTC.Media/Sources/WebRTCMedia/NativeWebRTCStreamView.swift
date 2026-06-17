import AppKit

@MainActor
public final class NativeWebRTCStreamView: NSView {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    private var trackingArea: NSTrackingArea?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        trackingArea = area
        addTrackingArea(area)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emitMouseButton(.left, isPressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        emitMouseButton(.left, isPressed: false)
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emitMouseButton(.right, isPressed: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        emitMouseButton(.right, isPressed: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        emitMouseButton(mouseButton(event.buttonNumber), isPressed: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        emitMouseButton(mouseButton(event.buttonNumber), isPressed: false)
    }

    public override func mouseMoved(with event: NSEvent) {
        emitMouseMove(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        emitMouseMove(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        emitMouseMove(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        emitMouseMove(event)
    }

    public override func scrollWheel(with event: NSEvent) {
        onInputEvent?(.mouse(.wheel(deviceID: "mouse", delta: Self.clampedInt16(Int((event.scrollingDeltaY * 120).rounded())), timestamp: Self.timestamp())))
    }

    public override func keyDown(with event: NSEvent) {
        emitKey(event, isPressed: true)
    }

    public override func keyUp(with event: NSEvent) {
        emitKey(event, isPressed: false)
    }

    private func emitMouseMove(_ event: NSEvent) {
        onInputEvent?(.mouse(.moved(
            deviceID: "mouse",
            deltaX: Self.clampedInt16(Int(event.deltaX.rounded())),
            deltaY: Self.clampedInt16(Int(event.deltaY.rounded())),
            timestamp: Self.timestamp()
        )))
    }

    private func emitMouseButton(_ button: MouseButton, isPressed: Bool) {
        onInputEvent?(.mouse(.button(deviceID: "mouse", button: button, isPressed: isPressed, timestamp: Self.timestamp())))
    }

    private func emitKey(_ event: NSEvent, isPressed: Bool) {
        onInputEvent?(.keyboard(KeyboardEvent(
            deviceID: "keyboard",
            keyCode: UInt16(event.keyCode),
            scanCode: UInt16(event.keyCode),
            modifiers: Self.modifiers(event.modifierFlags),
            isPressed: isPressed,
            timestamp: Self.timestamp()
        )))
    }

    private func mouseButton(_ buttonNumber: Int) -> MouseButton {
        switch buttonNumber {
        case 2:
            .middle
        case 3:
            .back
        case 4:
            .forward
        default:
            .middle
        }
    }

    private static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyboardModifiers {
        var modifiers: KeyboardModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.numericPad) { modifiers.insert(.numericPad) }
        return modifiers
    }

    private static func clampedInt16(_ value: Int) -> Int16 {
        Int16(max(Int(Int16.min), min(Int(Int16.max), value)))
    }

    private static func timestamp() -> MediaTimestamp {
        MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}
