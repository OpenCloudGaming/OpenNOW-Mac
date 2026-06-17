import AppKit

@MainActor
public enum WebRTCMediaStreamCommand: Sendable {
    case toggleStatsHUD
    case toggleSidebar
}

@MainActor
public final class NativeWebRTCStreamView: NSView {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    public var onPointerLockChanged: ((Bool) -> Void)?
    public var onCommand: ((WebRTCMediaStreamCommand) -> Void)?
    public private(set) var isPointerLocked = false
    private var trackingArea: NSTrackingArea?
    private var keyEquivalentMonitor: Any?
    private let gamepadMonitor = NativeWebRTCGamepadMonitor()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        gamepadMonitor.onInputEvent = { [weak self] event in self?.onInputEvent?(event) }
        gamepadMonitor.start()
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
        if window == nil {
            removeKeyEquivalentMonitor()
            gamepadMonitor.stop()
            setPointerLocked(false)
        } else {
            installKeyEquivalentMonitor()
            gamepadMonitor.start()
        }
    }

    public func setPointerLocked(_ locked: Bool) {
        guard isPointerLocked != locked else { return }
        isPointerLocked = locked
        if locked {
            NSCursor.hide()
            CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
            window?.makeFirstResponder(self)
        } else {
            CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
            NSCursor.unhide()
        }
        onPointerLockChanged?(locked)
        WebRTCMediaTelemetry.capture("webrtc.input.pointer_lock", level: .info, message: locked ? "Pointer lock enabled." : "Pointer lock disabled.", attributes: ["locked": String(locked)])
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
        if event.clickCount >= 2 { setPointerLocked(true) }
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
        if handleCommand(event) { return }
        if event.keyCode == 53, isPointerLocked {
            setPointerLocked(false)
            return
        }
        emitKey(event, isPressed: true)
    }

    public override func keyUp(with event: NSEvent) {
        emitKey(event, isPressed: false)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleCommand(event) || super.performKeyEquivalent(with: event)
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

    private func handleCommand(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else { return false }
        switch event.keyCode {
        case 45:
            onCommand?(.toggleStatsHUD)
            return true
        case 5:
            onCommand?(.toggleSidebar)
            return true
        default:
            return false
        }
    }

    private func installKeyEquivalentMonitor() {
        guard keyEquivalentMonitor == nil else { return }
        keyEquivalentMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.handleCommand(event) ? nil : event
        }
    }

    private func removeKeyEquivalentMonitor() {
        guard let keyEquivalentMonitor else { return }
        NSEvent.removeMonitor(keyEquivalentMonitor)
        self.keyEquivalentMonitor = nil
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
