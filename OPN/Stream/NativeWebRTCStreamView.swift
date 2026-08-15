import AppKit
import QuartzCore

private final class NativeWebRTCVideoSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class NativeNVSTRendererWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

public enum WebRTCMediaStreamCommand: Sendable {
    case toggleStatsHUD
    case toggleUnifiedHUD
    case toggleMicrophone
    case toggleRecording
    case toggleAntiAFK
    case showQuitMenu
}

public final class NativeWebRTCStreamView: NSView {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    public var onPointerLockChanged: ((Bool) -> Void)?
    public var onCommand: ((WebRTCMediaStreamCommand) -> Void)?
    public var shouldHandleCommand: ((WebRTCMediaStreamCommand) -> Bool)?
    public private(set) var isPointerLocked = false
    public var remoteInputEnabled = true {
        didSet {
            if oldValue && !remoteInputEnabled {
                releasePressedInputs()
                setPointerLocked(false)
            } else if !oldValue && remoteInputEnabled {
                gamepadMonitor.refreshInputState()
            }
        }
    }
    public var directMouseInputEnabled = true {
        didSet {
            if !directMouseInputEnabled { setPointerLocked(false) }
        }
    }
    public var hidesCursorWhilePointerLocked = true {
        didSet {
            guard isPointerLocked else { return }
            updatePointerLockCursorVisibility()
        }
    }
    private var trackingArea: NSTrackingArea?
    private var keyEquivalentMonitor: Any?
    private var pointerLockMonitor: Any?
    private var pointerLockNotificationTokens: [NSObjectProtocol] = []
    private var pointerLockRestoreLocation: CGPoint?
    private var pointerLockCursorHidden = false
    private var pressedKeyboardEvents: [UInt16: KeyboardEvent] = [:]
    private var pressedMouseButtons: Set<MouseButton> = []
    private var activeGamepadStates: [Int: GamepadState] = [:]
    private var streamContentSize = CGSize.zero
    private let videoSurface = NativeWebRTCVideoSurfaceView(frame: .zero)
    private let nativeNVSTRendererWindow = NativeNVSTRendererWindow(
        contentRect: .zero,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    private weak var nativeNVSTRendererParentWindow: NSWindow?
    private weak var nativeNVSTMetalView: NSView?
    private var nativeNVSTRendererEnabled = false
    private var nativeNVSTRendererPreparedForShutdown = false
    private var nativeNVSTVideoVisible = false
    private let gamepadMonitor = NativeWebRTCGamepadMonitor()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(videoSurface)
        nativeNVSTRendererWindow.backgroundColor = .clear
        nativeNVSTRendererWindow.colorSpace = .sRGB
        nativeNVSTRendererWindow.contentView = NativeWebRTCVideoSurfaceView(frame: .zero)
        nativeNVSTRendererWindow.hasShadow = false
        nativeNVSTRendererWindow.ignoresMouseEvents = true
        nativeNVSTRendererWindow.isOpaque = false
        nativeNVSTRendererWindow.alphaValue = 0
        nativeNVSTRendererWindow.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        gamepadMonitor.onInputEvent = { [weak self] event in
            guard let self, self.remoteInputEnabled else { return }
            if case .gamepad(let state) = event { self.activeGamepadStates[state.playerIndex] = state }
            self.onInputEvent?(event)
        }
        gamepadMonitor.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        return self
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if nativeNVSTRendererEnabled { updateNativeNVSTRendererWindowParent() }
        restoreInputFocus()
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

    public func setStreamContentSize(width: Int, height: Int) {
        let contentSize = CGSize(width: max(1, width), height: max(1, height))
        guard streamContentSize != contentSize else { return }
        streamContentSize = contentSize
        needsLayout = true
    }

    public func nativeVideoView() -> NSView {
        videoSurface
    }

    public func nativeNVSTVideoWindow() -> NSWindow? {
        guard window != nil else { return nil }
        layoutSubtreeIfNeeded()
        guard videoSurface.bounds.width >= 1, videoSurface.bounds.height >= 1 else { return nil }
        nativeNVSTRendererEnabled = true
        nativeNVSTRendererPreparedForShutdown = false
        updateNativeNVSTRendererWindowParent()
        updateNativeNVSTRendererWindowFrame()
        return nativeNVSTRendererWindow
    }

    public func setNativeNVSTVideoVisible(_ visible: Bool) {
        nativeNVSTVideoVisible = visible
        if visible { nativeNVSTRendererPreparedForShutdown = false }
        if !nativeNVSTRendererPreparedForShutdown { _ = embedNativeNVSTMetalViewIfAvailable() }
        nativeNVSTMetalView?.isHidden = !visible
        nativeNVSTRendererWindow.alphaValue = 0
    }

    public func prepareNativeNVSTRendererForShutdown() {
        nativeNVSTVideoVisible = false
        nativeNVSTRendererPreparedForShutdown = true
        nativeNVSTRendererWindow.alphaValue = 0
        guard let metalView = nativeNVSTMetalView,
              let rendererContentView = nativeNVSTRendererWindow.contentView else { return }
        metalView.isHidden = true
        metalView.removeFromSuperview()
        metalView.frame = rendererContentView.bounds
        metalView.autoresizingMask = [.width, .height]
        rendererContentView.addSubview(metalView)
        nativeNVSTMetalView = nil
    }

    public func restoreInputFocus() {
        guard remoteInputEnabled, NSApplication.shared.isActive, window?.isKeyWindow == true else { return }
        window?.makeFirstResponder(self)
    }

    public override func layout() {
        super.layout()
        videoSurface.frame = videoContentFrame()
        nativeNVSTMetalView?.frame = videoSurface.bounds
        if nativeNVSTRendererEnabled {
            updateNativeNVSTRendererWindowFrame()
            if !nativeNVSTRendererPreparedForShutdown { _ = embedNativeNVSTMetalViewIfAvailable() }
        }
    }

    private func updateNativeNVSTRendererWindowParent() {
        guard nativeNVSTRendererParentWindow !== window else { return }
        if let nativeNVSTRendererParentWindow {
            nativeNVSTRendererParentWindow.removeChildWindow(nativeNVSTRendererWindow)
        }
        nativeNVSTRendererParentWindow = window
        guard let window else {
            nativeNVSTRendererWindow.orderOut(nil)
            return
        }
        window.addChildWindow(nativeNVSTRendererWindow, ordered: .above)
        nativeNVSTRendererWindow.orderFront(nil)
        updateNativeNVSTRendererWindowFrame()
    }

    private func updateNativeNVSTRendererWindowFrame() {
        guard let window else { return }
        let rendererFrameInWindow = videoSurface.convert(videoSurface.bounds, to: nil)
        nativeNVSTRendererWindow.setFrame(window.convertToScreen(rendererFrameInWindow), display: true)
    }

    @discardableResult
    private func embedNativeNVSTMetalViewIfAvailable() -> Bool {
        if let nativeNVSTMetalView {
            nativeNVSTMetalView.frame = videoSurface.bounds
            nativeNVSTMetalView.isHidden = !nativeNVSTVideoVisible
            updateNativeNVSTMetalDrawableSize(nativeNVSTMetalView)
            return true
        }
        guard nativeNVSTVideoVisible,
              let metalView = nativeNVSTRendererWindow.contentView?.subviews.first(where: { $0.layer is CAMetalLayer }) else { return false }
        metalView.removeFromSuperview()
        metalView.frame = videoSurface.bounds
        metalView.autoresizingMask = [.width, .height]
        metalView.isHidden = !nativeNVSTVideoVisible
        videoSurface.addSubview(metalView)
        nativeNVSTMetalView = metalView
        updateNativeNVSTMetalDrawableSize(metalView)
        return true
    }

    private func updateNativeNVSTMetalDrawableSize(_ metalView: NSView) {
        guard let metalLayer = metalView.layer as? CAMetalLayer else { return }
        let boundsSize = metalView.bounds.size
        guard boundsSize.width >= 1, boundsSize.height >= 1 else { return }
        let scale = max(1, metalView.window?.backingScaleFactor ?? window?.backingScaleFactor ?? 1)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: floor(boundsSize.width * scale), height: floor(boundsSize.height * scale))
    }

    public func setPointerLocked(_ locked: Bool) {
        if locked {
            guard !isPointerLocked else { return }
            enablePointerLock()
        } else {
            releasePressedMouseButtons()
            guard isPointerLocked else { return }
            disablePointerLock()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        trackingArea = area
        addTrackingArea(area)
    }

    public override func mouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        emitMouseButton(.left, isPressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseButton(.left, isPressed: false)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        emitMouseButton(.right, isPressed: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseButton(.right, isPressed: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        guard let button = mouseButton(event.buttonNumber) else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        emitMouseButton(button, isPressed: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        guard let button = mouseButton(event.buttonNumber) else { return }
        emitMouseButton(button, isPressed: false)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseMove(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseMove(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseMove(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitMouseMove(event)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitScrollWheel(event)
    }

    public override func keyDown(with event: NSEvent) {
        guard remoteInputEnabled else {
            if handleCommand(event) { return }
            super.keyDown(with: event)
            return
        }
        if handlePasteShortcut(event) { return }
        if handleCommand(event) { return }
        emitKey(event, isPressed: true)
    }

    public override func keyUp(with event: NSEvent) {
        guard remoteInputEnabled else {
            if handleCommand(event) { return }
            super.keyUp(with: event)
            return
        }
        if handlePasteShortcut(event) { return }
        if handleCommand(event) { return }
        emitKey(event, isPressed: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        guard remoteInputEnabled else {
            super.flagsChanged(with: event)
            return
        }
        let pressed: Bool
        switch event.keyCode {
        case 54, 55:
            pressed = event.modifierFlags.contains(.command)
        case 56, 60:
            pressed = event.modifierFlags.contains(.shift)
        case 57:
            pressed = event.modifierFlags.contains(.capsLock)
        case 58, 61:
            pressed = event.modifierFlags.contains(.option)
        case 59, 62:
            pressed = event.modifierFlags.contains(.control)
        default:
            return
        }
        emitKey(event, isPressed: pressed)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard remoteInputEnabled else { return handleCommand(event) || super.performKeyEquivalent(with: event) }
        return handlePasteShortcut(event) || handleCommand(event) || super.performKeyEquivalent(with: event)
    }

    private func emitMouseMove(_ event: NSEvent) {
        emitMouseMove(deltaX: Self.clampedInt16(Int(event.deltaX.rounded())), deltaY: Self.clampedInt16(Int(event.deltaY.rounded())))
    }

    private func emitMouseMove(deltaX: Int16, deltaY: Int16) {
        guard deltaX != 0 || deltaY != 0 else { return }
        onInputEvent?(.mouse(.moved(
            deviceID: "mouse",
            deltaX: deltaX,
            deltaY: deltaY,
            timestamp: Self.timestamp()
        )))
    }

    private func emitScrollWheel(_ event: NSEvent) {
        onInputEvent?(.mouse(.wheel(deviceID: "mouse", delta: Self.clampedInt16(Int((event.scrollingDeltaY * 120).rounded())), timestamp: Self.timestamp())))
    }

    private func enablePointerLock() {
        guard window != nil else { return }
        isPointerLocked = true
        pointerLockRestoreLocation = NSEvent.mouseLocation
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        updatePointerLockCursorVisibility()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(0))
        installPointerLockMonitor()
        installPointerLockNotifications()
        notifyPointerLockChanged(true)
    }

    private func disablePointerLock() {
        guard isPointerLocked else { return }
        isPointerLocked = false
        removePointerLockMonitor()
        removePointerLockNotifications()
        CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
        if let restoreLocation = pointerLockRestoreLocation {
            moveCursor(toScreenPoint: restoreLocation)
        }
        pointerLockRestoreLocation = nil
        if pointerLockCursorHidden {
            NSCursor.unhide()
            pointerLockCursorHidden = false
        }
        notifyPointerLockChanged(false)
    }

    private func notifyPointerLockChanged(_ locked: Bool) {
        onPointerLockChanged?(locked)
        WebRTCMediaTelemetry.capture("webrtc.input.pointer_lock", level: .info, message: locked ? "Pointer lock enabled." : "Pointer lock disabled.", attributes: ["locked": String(locked)])
    }

    private func updatePointerLockCursorVisibility() {
        if hidesCursorWhilePointerLocked {
            if !pointerLockCursorHidden {
                NSCursor.hide()
                pointerLockCursorHidden = true
            }
        } else if pointerLockCursorHidden {
            NSCursor.unhide()
            pointerLockCursorHidden = false
        }
    }

    private func installPointerLockMonitor() {
        guard pointerLockMonitor == nil else { return }
        pointerLockMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
            guard let self, self.isPointerLocked else { return event }
            guard NSApplication.shared.isActive, self.window?.isKeyWindow == true else {
                self.setPointerLocked(false)
                return event
            }
            switch event.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                self.emitMouseMove(event)
                return nil
            case .scrollWheel:
                self.emitScrollWheel(event)
                return nil
            default:
                return event
            }
        }
    }

    private func removePointerLockMonitor() {
        guard let pointerLockMonitor else { return }
        NSEvent.removeMonitor(pointerLockMonitor)
        self.pointerLockMonitor = nil
    }

    private func installPointerLockNotifications() {
        guard pointerLockNotificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let appToken = center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApplication.shared, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setPointerLocked(false) }
        }
        let windowToken = center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setPointerLocked(false) }
        }
        pointerLockNotificationTokens = [appToken, windowToken]
    }

    private func removePointerLockNotifications() {
        let center = NotificationCenter.default
        pointerLockNotificationTokens.forEach { center.removeObserver($0) }
        pointerLockNotificationTokens.removeAll()
    }

    private func moveCursor(toScreenPoint point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? window?.screen
        guard let screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            CGWarpMouseCursorPosition(point)
            return
        }
        let displayPoint = CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
        CGDisplayMoveCursorToPoint(CGDirectDisplayID(screenNumber.uint32Value), displayPoint)
    }

    private func capturePointerForMouseDown() -> Bool {
        guard remoteInputEnabled, directMouseInputEnabled, !isPointerLocked else { return false }
        setPointerLocked(true)
        return isPointerLocked
    }

    private func videoContentFrame() -> CGRect {
        guard bounds.width > 0, bounds.height > 0, streamContentSize.width > 0, streamContentSize.height > 0 else { return bounds }
        let viewAspect = bounds.width / bounds.height
        let contentAspect = streamContentSize.width / streamContentSize.height
        if contentAspect > viewAspect {
            let height = bounds.width / contentAspect
            return CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height).integral
        }
        let width = bounds.height * contentAspect
        return CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height).integral
    }

    private func emitMouseButton(_ button: MouseButton, isPressed: Bool) {
        if isPressed {
            guard pressedMouseButtons.insert(button).inserted else { return }
        } else {
            guard pressedMouseButtons.remove(button) != nil else { return }
        }
        onInputEvent?(.mouse(.button(deviceID: "mouse", button: button, isPressed: isPressed, timestamp: Self.timestamp())))
    }

    private func releasePressedInputs() {
        let timestamp = Self.timestamp()
        let keyboardEvents = pressedKeyboardEvents.values
        let mouseButtons = pressedMouseButtons
        let gamepadStates = activeGamepadStates.values
        pressedKeyboardEvents.removeAll()
        activeGamepadStates.removeAll()
        for event in keyboardEvents {
            onInputEvent?(.keyboard(KeyboardEvent(
                deviceID: event.deviceID,
                keyCode: event.keyCode,
                scanCode: event.scanCode,
                modifiers: [],
                isPressed: false,
                timestamp: timestamp
            )))
        }
        releasePressedMouseButtons(mouseButtons, timestamp: timestamp)
        for state in gamepadStates {
            onInputEvent?(.gamepad(GamepadState(deviceID: state.deviceID, playerIndex: state.playerIndex, timestamp: timestamp)))
        }
    }

    private func releasePressedMouseButtons() {
        releasePressedMouseButtons(pressedMouseButtons, timestamp: Self.timestamp())
    }

    private func releasePressedMouseButtons(_ buttons: Set<MouseButton>, timestamp: MediaTimestamp) {
        pressedMouseButtons.subtract(buttons)
        for button in buttons {
            onInputEvent?(.mouse(.button(deviceID: "mouse", button: button, isPressed: false, timestamp: timestamp)))
        }
    }

    private func handleCommand(_ event: NSEvent) -> Bool {
        guard let command = streamCommand(for: event) else { return false }
        guard shouldHandleCommand?(command) == true else { return false }
        if event.type == .keyDown { onCommand?(command) }
        return true
    }

    private func handlePasteShortcut(_ event: NSEvent) -> Bool {
        guard Self.isPasteShortcut(event), NSPasteboard.general.string(forType: .string) != nil else { return false }
        if event.type == .keyDown, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            onInputEvent?(.text(deviceID: "keyboard", value: text, timestamp: Self.timestamp()))
        }
        return true
    }

    private static func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == 9 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        return modifiers == .command
    }

    private func streamCommand(for event: NSEvent) -> WebRTCMediaStreamCommand? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return nil }
        guard modifiers.subtracting([.capsLock, .numericPad]) == .command else { return nil }
        switch event.keyCode {
        case 46: return .toggleMicrophone
        case 15: return .toggleRecording
        case 40: return .toggleAntiAFK
        case 45: return .toggleStatsHUD
        case 5: return .toggleUnifiedHUD
        case 12: return .showQuitMenu
        default: return nil
        }
    }

    private func installKeyEquivalentMonitor() {
        guard keyEquivalentMonitor == nil else { return }
        keyEquivalentMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            guard NSApplication.shared.isActive else { return event }
            guard self.remoteInputEnabled else { return self.handleCommand(event) ? nil : event }
            if self.handlePasteShortcut(event) { return nil }
            if self.handleCommand(event) { return nil }
            self.emitKey(event, isPressed: event.type == .keyDown)
            return nil
        }
    }

    private func removeKeyEquivalentMonitor() {
        guard let keyEquivalentMonitor else { return }
        NSEvent.removeMonitor(keyEquivalentMonitor)
        self.keyEquivalentMonitor = nil
    }

    private func emitKey(_ event: NSEvent, isPressed: Bool) {
        let keyboardEvent = KeyboardEvent(
            deviceID: "keyboard",
            keyCode: UInt16(event.keyCode),
            scanCode: UInt16(event.keyCode),
            modifiers: Self.modifiers(event.modifierFlags),
            isPressed: isPressed,
            timestamp: Self.timestamp()
        )
        if keyboardEvent.keyCode == 57 {
            pressedKeyboardEvents.removeValue(forKey: keyboardEvent.keyCode)
        } else if isPressed {
            pressedKeyboardEvents[keyboardEvent.keyCode] = keyboardEvent
        } else {
            pressedKeyboardEvents.removeValue(forKey: keyboardEvent.keyCode)
        }
        onInputEvent?(.keyboard(keyboardEvent))
    }

    private func mouseButton(_ buttonNumber: Int) -> MouseButton? {
        switch buttonNumber {
        case 2:
            .middle
        case 3:
            .back
        case 4:
            .forward
        default:
            nil
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
