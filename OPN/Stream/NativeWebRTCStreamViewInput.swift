//  Turning AppKit events into stream input: mouse, wheel, keyboard, text input and the
//  shortcuts the client keeps for itself. Split out of NativeWebRTCStreamView.swift.
//

import AppKit
import QuartzCore

extension NativeWebRTCStreamView {
    /// Forwards a Command-key shortcut to the remote as the equivalent Control chord — Cmd+C
    /// becomes Ctrl+C — because macOS consumes Command shortcuts before they reach `keyDown`.
    func forwardCommandShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        // Command must be held, and only Shift/Option may accompany it — a chord that also holds
        // Control is already a Control chord and reaches the stream by the ordinary path.
        guard modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        for stroke in Self.commandShortcutStrokes(keyCode: UInt16(event.keyCode),
                                                   shift: modifiers.contains(.shift),
                                                   option: modifiers.contains(.option)) {
            onInputEvent?(.keyboard(KeyboardEvent(deviceID: "keyboard",
                                                  keyCode: stroke.keyCode,
                                                  scanCode: stroke.keyCode,
                                                  isPressed: stroke.isPressed,
                                                  timestamp: Self.timestamp())))
        }
        return true
    }

    /// The press/release sequence for a Command shortcut, expressed in mac key codes so the
    /// transport's own table maps them (55 -> Control). Control wraps the whole chord; any extra
    /// Shift/Option sits inside it, in a strict nesting so nothing is left held.
    nonisolated static func commandShortcutStrokes(keyCode: UInt16, shift: Bool, option: Bool) -> [(keyCode: UInt16, isPressed: Bool)] {
        var strokes: [(keyCode: UInt16, isPressed: Bool)] = [(55, true)]   // Command -> Control down
        if shift { strokes.append((56, true)) }
        if option { strokes.append((58, true)) }
        strokes.append((keyCode, true))
        strokes.append((keyCode, false))
        if option { strokes.append((58, false)) }
        if shift { strokes.append((56, false)) }
        strokes.append((55, false))                                        // Control up
        return strokes
    }

    func emitMouseMove(_ event: NSEvent) {
        if !isPointerLocked, mouseInputMode == .absolute {
            emitAbsoluteMousePosition(event)
            return
        }
        emitMouseMove(deltaX: Self.clampedInt16(Int(event.deltaX.rounded())), deltaY: Self.clampedInt16(Int(event.deltaY.rounded())))
    }

    func emitMouseMove(deltaX: Int16, deltaY: Int16) {
        guard deltaX != 0 || deltaY != 0 else { return }
        onInputEvent?(.mouse(.moved(
            deviceID: "mouse",
            deltaX: deltaX,
            deltaY: deltaY,
            timestamp: Self.timestamp()
        )))
    }

    func emitScrollWheel(_ event: NSEvent) {
        let delta = Self.accumulatedWheelDelta(
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            remainder: &preciseScrollRemainder
        )
        guard delta != 0 else { return }
        onInputEvent?(.mouse(.wheel(deviceID: "mouse", delta: delta, timestamp: Self.timestamp())))
    }

    func installPointerLockMonitor() {
        guard pointerLockMonitor == nil else { return }
        pointerLockMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]) { [weak self] event in
            guard let self, self.isCursorCaptured else { return event }
            guard NSApplication.shared.isActive, self.window?.isKeyWindow == true else {
                self.handleFocusLoss()
                return event
            }
            if self.isAbsoluteCursorConfined {
                switch event.type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    let point = self.convert(event.locationInWindow, from: nil)
                    if !self.bounds.contains(point) { self.disableAbsoluteCursorConfinement() }
                    return event
                case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                    return self.constrainAssociatedAbsoluteCursor() ? nil : event
                case .scrollWheel:
                    return event
                default:
                    return event
                }
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

    func removePointerLockMonitor() {
        guard let pointerLockMonitor else { return }
        NSEvent.removeMonitor(pointerLockMonitor)
        self.pointerLockMonitor = nil
    }

    func installAbsoluteCursorGlobalMonitor() {
        guard absoluteCursorGlobalMonitor == nil else { return }
        absoluteCursorGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isAbsoluteCursorConfined, NSApplication.shared.isActive, self.window?.isKeyWindow == true else { return }
                self.constrainAssociatedAbsoluteCursor()
            }
        }
    }

    func removeAbsoluteCursorGlobalMonitor() {
        guard let absoluteCursorGlobalMonitor else { return }
        NSEvent.removeMonitor(absoluteCursorGlobalMonitor)
        self.absoluteCursorGlobalMonitor = nil
    }

    func installPointerLockNotifications() {
        guard pointerLockNotificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let appToken = center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApplication.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFocusLoss() }
        }
        let windowToken = center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleFocusLoss() }
        }
        pointerLockNotificationTokens = [appToken, windowToken]
    }

    func removePointerLockNotifications() {
        let center = NotificationCenter.default
        pointerLockNotificationTokens.forEach { center.removeObserver($0) }
        pointerLockNotificationTokens.removeAll()
    }

    func moveCursor(toScreenPoint point: CGPoint) {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? window?.screen
        guard let screen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            CGWarpMouseCursorPosition(point)
            return
        }
        let displayPoint = CGPoint(x: point.x - screen.frame.minX, y: screen.frame.maxY - point.y)
        CGDisplayMoveCursorToPoint(CGDirectDisplayID(screenNumber.uint32Value), displayPoint)
    }

    func capturePointerForMouseDown() -> Bool {
        guard remoteInputEnabled, directMouseInputEnabled, mouseInputMode == .relative, !isPointerLocked else { return false }
        setPointerLocked(true)
        return isPointerLocked
    }

    static func confinedCursorPoint(_ point: CGPoint, to windowFrame: CGRect) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, windowFrame.origin.x.isFinite, windowFrame.origin.y.isFinite,
              windowFrame.width.isFinite, windowFrame.height.isFinite, windowFrame.width >= 2, windowFrame.height >= 2 else { return nil }
        return CGPoint(
            x: min(max(point.x, windowFrame.minX + 1), windowFrame.maxX - 1),
            y: min(max(point.y, windowFrame.minY + 1), windowFrame.maxY - 1)
        )
    }

    static func accumulatedWheelDelta(scrollingDeltaY: Double,
                                      hasPreciseScrollingDeltas: Bool,
                                      remainder: inout Double) -> Int16 {
        guard scrollingDeltaY.isFinite else { return 0 }
        if !hasPreciseScrollingDeltas {
            remainder = 0
            let scaled = min(max((scrollingDeltaY * 120).rounded(), Double(Int16.min)), Double(Int16.max))
            return Int16(scaled)
        }
        remainder += scrollingDeltaY
        let completeDetents = remainder.rounded(.towardZero)
        guard completeDetents != 0 else { return 0 }
        let packetLimit = Double(Int16.max / 120)
        let packetDetents = min(max(completeDetents, -packetLimit), packetLimit)
        remainder -= packetDetents
        return Int16(packetDetents * 120)
    }

    func emitAbsoluteMousePosition(_ event: NSEvent) {
        guard !isPointerLocked, mouseInputMode == .absolute else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let absoluteEvent = absoluteMouseEvent(at: point, timestamp: Self.timestamp()) else { return }
        onAbsoluteMouseMove?(absoluteEvent)
    }

    func absoluteMouseEvent(at point: CGPoint, timestamp: MediaTimestamp) -> NativeNVSTAbsoluteMouseEvent? {
        let contentFrame = videoContentFrame()
        guard contentFrame.width > 0, contentFrame.height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let x = floor(point.x - contentFrame.minX)
        let y = floor(contentFrame.maxY - point.y)
        return NativeNVSTAbsoluteMouseEvent(
            x: Int32(clamping: Int(min(max(0, x), contentFrame.width - 1))),
            y: Int32(clamping: Int(min(max(0, y), contentFrame.height - 1))),
            viewportWidth: Int32(clamping: Int(contentFrame.width)),
            viewportHeight: Int32(clamping: Int(contentFrame.height)),
            timestamp: timestamp
        )
    }

    func videoContentFrame() -> CGRect {
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

    func emitMouseButton(_ button: MouseButton, isPressed: Bool) {
        if isPressed {
            guard pressedMouseButtons.insert(button).inserted else { return }
        } else {
            guard pressedMouseButtons.remove(button) != nil else { return }
        }
        onInputEvent?(.mouse(.button(deviceID: "mouse", button: button, isPressed: isPressed, timestamp: Self.timestamp())))
    }

    func releasePressedInputs() {
        let timestamp = Self.timestamp()
        let keyboardEvents = pressedKeyboardEvents.values
        let mouseButtons = pressedMouseButtons
        let gamepadStates = activeGamepadStates.values
        pressedKeyboardEvents.removeAll()
        textInputKeyCodes.removeAll()
        pushToTalkState?.release()
        textInputState.cancel()
        activeGamepadStates.removeAll()
        preciseScrollRemainder = 0
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

    func emitCurrentAbsoluteMousePosition(timestamp: MediaTimestamp) {
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let viewPoint = convert(windowPoint, from: nil)
        guard let event = absoluteMouseEvent(at: viewPoint, timestamp: timestamp) else { return }
        isEmittingNeutralizingAbsolutePosition = true
        defer { isEmittingNeutralizingAbsolutePosition = false }
        onAbsoluteMouseMove?(event)
    }

    func handleFocusLoss() {
        releasePressedInputs()
        setPointerLocked(false)
    }

    func receiveGamepadState(_ state: GamepadState) {
        activeGamepadStates[state.playerIndex] = state
        onInputEvent?(.gamepad(state))
    }

    func releasePressedMouseButtons() {
        releasePressedMouseButtons(pressedMouseButtons, timestamp: Self.timestamp())
    }

    func releasePressedMouseButtons(_ buttons: Set<MouseButton>, timestamp: MediaTimestamp) {
        pressedMouseButtons.subtract(buttons)
        for button in buttons.sorted(by: { Self.mouseButtonOrder($0) < Self.mouseButtonOrder($1) }) {
            if mouseInputMode == .absolute { emitCurrentAbsoluteMousePosition(timestamp: timestamp) }
            onInputEvent?(.mouse(.button(deviceID: "mouse", button: button, isPressed: false, timestamp: timestamp)))
        }
    }

    static func mouseButtonOrder(_ button: MouseButton) -> Int {
        switch button {
        case .left: 0
        case .middle: 1
        case .right: 2
        case .back: 3
        case .forward: 4
        }
    }

    func handleCommand(_ event: NSEvent) -> Bool {
        guard let command = streamCommand(for: event) else { return false }
        guard shouldHandleCommand?(command) == true else { return false }
        if event.type == .keyDown { onCommand?(command) }
        return true
    }

    func handlePasteShortcut(_ event: NSEvent) -> Bool {
        guard Self.isPasteShortcut(event), NSPasteboard.general.string(forType: .string) != nil else { return false }
        if event.type == .keyDown, let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            onInputEvent?(.text(deviceID: "keyboard", value: text, timestamp: Self.timestamp()))
        }
        return true
    }

    static func isPasteShortcut(_ event: NSEvent) -> Bool {
        guard event.keyCode == 9 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        return modifiers == .command
    }

    func streamCommand(for event: NSEvent) -> WebRTCMediaStreamCommand? {
        WebRTCMediaStreamCommand.shortcutCommand(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags)
    }

    func installKeyEquivalentMonitor() {
        guard keyEquivalentMonitor == nil else { return }
        keyEquivalentMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            return self.routeKeyEquivalent(event)
        }
    }

    /// Decides who sees a key event: the stream, the app's own menu, or nobody. Returning `nil`
    /// swallows the event, which is what forwarding it to the seat means.
    func routeKeyEquivalent(_ event: NSEvent) -> NSEvent? {
        guard window?.isKeyWindow == true,
              Self.isStreamWindowKeyEvent(event.window, streamWindow: window),
              NSApplication.shared.isActive else {
            releaseRemotelyPressedKeyIfNeeded(event)
            return event
        }
        guard remoteInputEnabled else { return handleCommand(event) ? nil : event }
        if handlePushToTalk(event, isPressed: event.type == .keyDown) { return nil }
        let routesToApplication = Self.reservesApplicationMenuKeyEquivalent(event.modifierFlags)
        if routesToApplication { releaseRemotelyPressedKeyIfNeeded(event) }
        if handlePasteShortcut(event) { return nil }
        if handleCommand(event) { return nil }
        if routesToApplication { return event }
        forwardKeyEvent(event)
        return nil
    }

    /// A key the seat should see. Key-down first goes through text input, which claims the codes it
    /// consumed so the matching key-up is not sent twice.
    func forwardKeyEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if !handleTextInput(event) { emitKey(event, isPressed: true) }
        } else if textInputKeyCodes.remove(UInt16(event.keyCode)) == nil {
            emitKey(event, isPressed: false)
        }
    }

    static func reservesApplicationMenuKeyEquivalent(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    static func isStreamWindowKeyEvent(_ eventWindow: NSWindow?, streamWindow: NSWindow?) -> Bool {
        guard let eventWindow, let streamWindow else { return false }
        return eventWindow === streamWindow
    }

    func removeKeyEquivalentMonitor() {
        guard let keyEquivalentMonitor else { return }
        NSEvent.removeMonitor(keyEquivalentMonitor)
        self.keyEquivalentMonitor = nil
    }

    func emitKey(_ event: NSEvent, isPressed: Bool) {
        let keyboardEvent = Self.keyboardEvent(from: event, isPressed: isPressed)
        if pushToTalkState?.handle(keyboardEvent) == true { return }
        if keyboardEvent.keyCode == 57 {
            pressedKeyboardEvents.removeValue(forKey: keyboardEvent.keyCode)
        } else if isPressed {
            pressedKeyboardEvents[keyboardEvent.keyCode] = keyboardEvent
        } else {
            pressedKeyboardEvents.removeValue(forKey: keyboardEvent.keyCode)
        }
        onInputEvent?(.keyboard(keyboardEvent))
    }

    func handleTextInput(_ event: NSEvent) -> Bool {
        guard Self.shouldInterpretAsText(event, hasMarkedText: hasMarkedText(), inputSourceID: inputContext?.selectedKeyboardInputSource) else { return false }
        textInputKeyCodes.insert(UInt16(event.keyCode))
        interpretKeyEvents([event])
        return true
    }

    static func shouldInterpretAsText(_ event: NSEvent, hasMarkedText: Bool, inputSourceID: String?) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return false }
        if hasMarkedText || modifiers.contains(.option) { return true }
        if inputSourceID?.localizedCaseInsensitiveContains("inputmethod") == true { return true }
        guard let characters = event.characters, !characters.isEmpty else { return true }
        // Special keys (arrows, Home, Page Up/Down, Delete, F1-F12, etc.) use Unicode
        // private-use-area characters. They must be forwarded as key events, not text.
        if characters.unicodeScalars.contains(where: { $0.value >= 0xF700 && $0.value <= 0xF8FF }) { return false }
        return !characters.unicodeScalars.allSatisfy(\.isASCII)
    }

    func handlePushToTalk(_ event: NSEvent, isPressed: Bool) -> Bool {
        pushToTalkState?.handle(Self.keyboardEvent(from: event, isPressed: isPressed)) == true
    }

    static func keyboardEvent(from event: NSEvent, isPressed: Bool) -> KeyboardEvent {
        KeyboardEvent(
            deviceID: "keyboard",
            keyCode: UInt16(event.keyCode),
            scanCode: UInt16(event.keyCode),
            modifiers: modifiers(event.modifierFlags),
            isPressed: isPressed,
            timestamp: timestamp()
        )
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let value = Self.string(from: string)
        guard let committed = textInputState.commit(value) else { return }
        onInputEvent?(.text(deviceID: "keyboard", value: committed, timestamp: Self.timestamp()))
    }

    public override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)) { cancelOperation(nil) }
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        textInputState.setMarkedText(Self.attributedString(from: string), selectedRange: selectedRange, replacementRange: replacementRange)
    }

    public func unmarkText() {
        guard let committed = textInputState.unmark() else { return }
        onInputEvent?(.text(deviceID: "keyboard", value: committed, timestamp: Self.timestamp()))
    }

    public func selectedRange() -> NSRange { textInputState.selection }
    public func markedRange() -> NSRange { textInputState.markedRange }
    public func hasMarkedText() -> Bool { textInputState.hasMarkedText }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let (substring, resolvedRange) = textInputState.attributedSubstring(for: range) else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        actualRange?.pointee = resolvedRange
        return substring
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.markedClauseSegment, .replacementIndex, .underlineStyle, .underlineColor, .foregroundColor, .backgroundColor]
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let length = textInputState.markedText.length
        let location = range.location == NSNotFound ? textInputState.selection.location : min(range.location, length)
        actualRange?.pointee = NSRange(location: location, length: min(range.length, length - location))
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let prefixRange = NSRange(location: 0, length: location)
        let prefix = textInputState.markedText.attributedSubstring(from: prefixRange).string as NSString
        let offset = prefix.size(withAttributes: [.font: font]).width
        let localRect = NSRect(x: min(bounds.maxX, bounds.minX + offset), y: bounds.minY, width: 1, height: font.ascender - font.descender)
        guard let window else { return localRect }
        return window.convertToScreen(convert(localRect, to: nil))
    }

    public func characterIndex(for point: NSPoint) -> Int {
        guard let window else { return 0 }
        let localPoint = convert(window.convertPoint(fromScreen: point), from: nil)
        let text = textInputState.markedText.string as NSString
        guard text.length > 0 else { return 0 }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var width: CGFloat = 0
        for index in 0..<text.length {
            let characterWidth = text.substring(with: NSRange(location: index, length: 1)).size(withAttributes: [.font: font]).width
            if localPoint.x < bounds.minX + width + characterWidth / 2 { return index }
            width += characterWidth
        }
        return text.length
    }

    public override func cancelOperation(_ sender: Any?) {
        textInputState.cancel()
    }

    static func string(from value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    static func attributedString(from value: Any) -> NSAttributedString {
        if let attributed = value as? NSAttributedString { return attributed }
        return NSAttributedString(string: value as? String ?? "")
    }

    func releaseRemotelyPressedKeyIfNeeded(_ event: NSEvent) {
        guard event.type == .keyUp, pressedKeyboardEvents[UInt16(event.keyCode)] != nil else { return }
        emitKey(event, isPressed: false)
    }

    func mouseButton(_ buttonNumber: Int) -> MouseButton? {
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

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> KeyboardModifiers {
        var modifiers: KeyboardModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.numericPad) { modifiers.insert(.numericPad) }
        return modifiers
    }

    static func clampedInt16(_ value: Int) -> Int16 {
        Int16(max(Int(Int16.min), min(Int(Int16.max), value)))
    }

    static func timestamp() -> MediaTimestamp {
        MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}
