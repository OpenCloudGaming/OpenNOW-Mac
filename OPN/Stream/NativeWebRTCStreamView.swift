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
    var hdrPresentationRequested = false
    var codecSupportsHDR = false

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

public enum WebRTCMediaStreamCommand: Equatable, Sendable {
    case toggleStatsHUD
    case toggleUnifiedHUD
    case toggleMicrophone
    case toggleRecording
    case toggleAntiAFK
    case showQuitMenu

    static let shortcutGuide = "⌘G HUD   ⌘N Stats   ⌘M Mic   ⌘R Rec   ⌘K AFK   ⌘Q Quit"

    static func shortcutCommand(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> WebRTCMediaStreamCommand? {
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        guard modifiers == .command else { return nil }
        switch keyCode {
        case 46: return .toggleMicrophone
        case 15: return .toggleRecording
        case 40: return .toggleAntiAFK
        case 45: return .toggleStatsHUD
        case 5: return .toggleUnifiedHUD
        case 12: return .showQuitMenu
        default: return nil
        }
    }
}

public enum NativeStreamMouseInputMode: Equatable, Sendable {
    case absolute
    case relative
}

struct NativeNVSTTextInputState {
    private(set) var markedText = NSAttributedString()
    private(set) var selection = NSRange(location: 0, length: 0)

    var hasMarkedText: Bool { markedText.length > 0 }
    var markedRange: NSRange { hasMarkedText ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }

    mutating func setMarkedText(_ text: NSAttributedString, selectedRange: NSRange, replacementRange: NSRange) {
        if replacementRange.location != NSNotFound,
           NSMaxRange(replacementRange) <= markedText.length {
            let mutableText = NSMutableAttributedString(attributedString: markedText)
            mutableText.replaceCharacters(in: replacementRange, with: text)
            markedText = mutableText
        } else {
            markedText = text
        }
        selection = Self.clamped(selectedRange, length: markedText.length)
    }

    mutating func commit(_ text: String) -> String? {
        markedText = NSAttributedString()
        selection = NSRange(location: 0, length: 0)
        return text.isEmpty ? nil : text
    }

    mutating func unmark() -> String? {
        commit(markedText.string)
    }

    mutating func cancel() {
        markedText = NSAttributedString()
        selection = NSRange(location: 0, length: 0)
    }

    func attributedSubstring(for range: NSRange) -> (NSAttributedString, NSRange)? {
        guard hasMarkedText, range.location != NSNotFound else { return nil }
        let intersection = NSIntersectionRange(range, markedRange)
        guard intersection.length > 0 else { return nil }
        return (markedText.attributedSubstring(from: intersection), intersection)
    }

    private static func clamped(_ range: NSRange, length: Int) -> NSRange {
        guard range.location != NSNotFound else { return NSRange(location: length, length: 0) }
        let location = min(range.location, length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
}

final class NativeNVSTPushToTalkState {
    private let keyCode: UInt16
    private let modifierMask: UInt16
    private var onChange: (Bool) -> Void
    private(set) var isPressed = false

    init(keyCode: Int, modifierMask: Int, onChange: @escaping (Bool) -> Void) {
        self.keyCode = UInt16(clamping: keyCode)
        self.modifierMask = UInt16(truncatingIfNeeded: modifierMask) & Self.supportedModifiers
        self.onChange = onChange
    }

    func handle(_ event: KeyboardEvent) -> Bool {
        guard event.keyCode == keyCode else { return false }
        if event.isPressed {
            guard event.modifiers.rawValue & Self.supportedModifiers == modifierMask else { return false }
            guard !isPressed else { return true }
            isPressed = true
            onChange(true)
            return true
        }
        guard isPressed else { return false }
        isPressed = false
        onChange(false)
        return true
    }

    func release() {
        guard isPressed else { return }
        isPressed = false
        onChange(false)
    }

    func update(keyCode: Int, modifierMask: Int, onChange: @escaping (Bool) -> Void) -> Bool {
        let normalizedKeyCode = UInt16(clamping: keyCode)
        let normalizedModifierMask = UInt16(truncatingIfNeeded: modifierMask) & Self.supportedModifiers
        guard self.keyCode == normalizedKeyCode, self.modifierMask == normalizedModifierMask else { return false }
        self.onChange = onChange
        return true
    }

    private static let supportedModifiers = KeyboardModifiers.shift.rawValue |
        KeyboardModifiers.control.rawValue | KeyboardModifiers.option.rawValue |
        KeyboardModifiers.command.rawValue | KeyboardModifiers.capsLock.rawValue
}

public final class NativeWebRTCStreamView: NSView, NSTextInputClient {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    public var onAbsoluteMouseMove: ((NativeNVSTAbsoluteMouseEvent) -> Void)?
    public var onGamepadTopologyChanged: ((NativeWebRTCGamepadTopology) -> Void)?
    public var onPointerLockChanged: ((Bool) -> Void)?
    public var onCommand: ((WebRTCMediaStreamCommand) -> Void)?
    public var shouldHandleCommand: ((WebRTCMediaStreamCommand) -> Bool)?
    var cursorAssociationHandler: (Bool) -> CGError = {
        CGAssociateMouseAndMouseCursorPosition(boolean_t($0 ? 1 : 0))
    }
    public private(set) var isPointerLocked = false
    public private(set) var isAbsoluteCursorConfined = false
    public private(set) var isEmittingNeutralizingAbsolutePosition = false
    public var isCursorCaptured: Bool { isPointerLocked || isAbsoluteCursorConfined }
    public var locksPointerWhenRelativeModeSelected = false
    public var confinesCursorToWindowInAbsoluteMode = false {
        didSet {
            if !confinesCursorToWindowInAbsoluteMode { disableAbsoluteCursorConfinement() }
        }
    }
    public var mouseInputMode: NativeStreamMouseInputMode = .relative {
        willSet {
            guard newValue != mouseInputMode else { return }
            if mouseInputMode == .absolute, !pressedMouseButtons.isEmpty {
                emitCurrentAbsoluteMousePosition(timestamp: Self.timestamp())
            }
            releasePressedMouseButtons()
            preciseScrollRemainder = 0
        }
        didSet {
            guard oldValue != mouseInputMode else { return }
            if mouseInputMode == .absolute {
                disablePointerLock()
            } else if directMouseInputEnabled {
                disableAbsoluteCursorConfinement()
                restoreInputFocus()
            }
        }
    }
    public var remoteInputEnabled = true {
        willSet {
            if remoteInputEnabled && !newValue {
                releasePressedInputs()
                setPointerLocked(false)
            }
        }
        didSet {
            if !oldValue && remoteInputEnabled {
                gamepadMonitor.refreshInputState()
                restoreInputFocus()
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
    private var absoluteCursorPosition: CGPoint?
    private var cursorAssociationGeneration: UInt = 0
    private var preciseScrollRemainder = 0.0
    private var pressedKeyboardEvents: [UInt16: KeyboardEvent] = [:]
    private var textInputState = NativeNVSTTextInputState()
    private var textInputKeyCodes: Set<UInt16> = []
    private var pushToTalkState: NativeNVSTPushToTalkState?
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
    private var nativeNVSTDisplayNotificationTokens: [NSObjectProtocol] = []
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
        nativeNVSTRendererWindow.contentView = NativeWebRTCVideoSurfaceView(frame: .zero)
        nativeNVSTRendererWindow.hasShadow = false
        nativeNVSTRendererWindow.ignoresMouseEvents = true
        nativeNVSTRendererWindow.isOpaque = false
        nativeNVSTRendererWindow.alphaValue = 0
        nativeNVSTRendererWindow.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        gamepadMonitor.onInputEvent = { [weak self] event in
            guard let self, self.remoteInputEnabled else { return }
            guard case .gamepad(let state) = event else { return }
            self.receiveGamepadState(state)
        }
        gamepadMonitor.onTopologyChanged = { [weak self] topology in
            guard let self else { return }
            self.activeGamepadStates = self.activeGamepadStates.filter { topology.playerIndices.contains($0.key) }
            self.onGamepadTopologyChanged?(topology)
        }
        gamepadMonitor.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    public override var acceptsFirstResponder: Bool { true }

    public func configurePushToTalk(keyCode: Int?, modifierMask: Int = 0, onChange: @escaping (Bool) -> Void) {
        if let keyCode, pushToTalkState?.update(keyCode: keyCode, modifierMask: modifierMask, onChange: onChange) == true { return }
        pushToTalkState?.release()
        pushToTalkState = keyCode.map { NativeNVSTPushToTalkState(keyCode: $0, modifierMask: modifierMask, onChange: onChange) }
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, bounds.contains(point) else { return nil }
        return self
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if nativeNVSTRendererEnabled {
            updateNativeNVSTRendererWindowParent()
            updateNativeNVSTPresentation()
        }
        installNativeNVSTDisplayNotifications()
        restoreInputFocus()
        window?.acceptsMouseMovedEvents = true
        if window == nil {
            removeKeyEquivalentMonitor()
            gamepadMonitor.stop()
            handleFocusLoss()
            removePointerLockNotifications()
        } else {
            installKeyEquivalentMonitor()
            installPointerLockNotifications()
            gamepadMonitor.start()
        }
    }

    public func setStreamContentSize(width: Int, height: Int) {
        let contentSize = CGSize(width: max(1, width), height: max(1, height))
        guard streamContentSize != contentSize else { return }
        streamContentSize = contentSize
        needsLayout = true
    }

    public var gamepadTopology: NativeWebRTCGamepadTopology {
        gamepadMonitor.topology
    }

    public func playHaptic(_ command: NativeNVSTHapticCommand) {
        gamepadMonitor.playHaptic(command)
    }

    public func stopHaptics() {
        gamepadMonitor.stopHaptics()
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
        updateNativeNVSTPresentation()
        return nativeNVSTRendererWindow
    }

    static func configureNativeNVSTPresentation(window: NSWindow, requestedHDR: Bool, codecSupportsHDR: Bool) {
        guard let rendererWindow = window as? NativeNVSTRendererWindow else { return }
        rendererWindow.hdrPresentationRequested = requestedHDR
        rendererWindow.codecSupportsHDR = codecSupportsHDR
        let screenSupportsEDR = rendererWindow.parent?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? rendererWindow.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let usesEDR = nativeNVSTPresentationUsesEDR(requestedHDR: requestedHDR, codecSupportsHDR: codecSupportsHDR, screenSupportsEDR: screenSupportsEDR > 1)
        rendererWindow.colorSpace = usesEDR ? nil : .sRGB
        rendererWindow.contentView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
    }

    static func nativeNVSTPresentationUsesEDR(requestedHDR: Bool, codecSupportsHDR: Bool, screenSupportsEDR: Bool) -> Bool {
        requestedHDR && codecSupportsHDR && screenSupportsEDR
    }

    public func setNativeNVSTVideoVisible(_ visible: Bool) {
        nativeNVSTVideoVisible = visible
        if visible { nativeNVSTRendererPreparedForShutdown = false }
        if !nativeNVSTRendererPreparedForShutdown { _ = embedNativeNVSTMetalViewIfAvailable() }
        nativeNVSTMetalView?.isHidden = !visible
        nativeNVSTRendererWindow.alphaValue = 0
    }

    public var nativeNVSTRendererSurfaceReady: Bool {
        guard nativeNVSTRendererEnabled, nativeNVSTVideoVisible, !nativeNVSTRendererPreparedForShutdown,
              let metalView = nativeNVSTMetalView, metalView.superview === videoSurface,
              let metalLayer = metalView.layer as? CAMetalLayer else { return false }
        return metalLayer.drawableSize.width >= 1 && metalLayer.drawableSize.height >= 1
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
        if locksPointerWhenRelativeModeSelected, mouseInputMode == .relative, directMouseInputEnabled { setPointerLocked(true) }
    }

    public override func layout() {
        super.layout()
        videoSurface.frame = videoContentFrame()
        nativeNVSTMetalView?.frame = videoSurface.bounds
        if nativeNVSTRendererEnabled {
            updateNativeNVSTRendererWindowFrame()
            updateNativeNVSTPresentation()
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

    private func installNativeNVSTDisplayNotifications() {
        removeNativeNVSTDisplayNotifications()
        guard let window else { return }
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNativeNVSTDisplayState() }
        }
        for observedWindow in [window, nativeNVSTRendererWindow] {
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeScreenNotification, object: observedWindow, queue: .main, using: refresh))
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: observedWindow, queue: .main, using: refresh))
            nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSWindow.didChangeScreenProfileNotification, object: observedWindow, queue: .main, using: refresh))
        }
        nativeNVSTDisplayNotificationTokens.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared, queue: .main, using: refresh))
    }

    private func removeNativeNVSTDisplayNotifications() {
        let center = NotificationCenter.default
        nativeNVSTDisplayNotificationTokens.forEach { center.removeObserver($0) }
        nativeNVSTDisplayNotificationTokens.removeAll()
    }

    private func refreshNativeNVSTDisplayState() {
        guard nativeNVSTRendererEnabled else { return }
        updateNativeNVSTRendererWindowFrame()
        if let nativeNVSTMetalView { updateNativeNVSTMetalDrawableSize(nativeNVSTMetalView) }
        updateNativeNVSTPresentation()
    }

    private func updateNativeNVSTPresentation() {
        let screenSupportsEDR = window?.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        let usesEDR = Self.nativeNVSTPresentationUsesEDR(
            requestedHDR: nativeNVSTRendererWindow.hdrPresentationRequested,
            codecSupportsHDR: nativeNVSTRendererWindow.codecSupportsHDR,
            screenSupportsEDR: screenSupportsEDR > 1
        )
        nativeNVSTRendererWindow.colorSpace = usesEDR ? nil : .sRGB
        nativeNVSTRendererWindow.contentView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
        videoSurface.layer?.wantsExtendedDynamicRangeContent = usesEDR
        nativeNVSTMetalView?.layer?.wantsExtendedDynamicRangeContent = usesEDR
    }

    @discardableResult
    private func embedNativeNVSTMetalViewIfAvailable() -> Bool {
        if let nativeNVSTMetalView {
            nativeNVSTMetalView.frame = videoSurface.bounds
            nativeNVSTMetalView.isHidden = !nativeNVSTVideoVisible
            updateNativeNVSTMetalDrawableSize(nativeNVSTMetalView)
            updateNativeNVSTPresentation()
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
        updateNativeNVSTPresentation()
        return true
    }

    private func updateNativeNVSTMetalDrawableSize(_ metalView: NSView) {
        guard let metalLayer = metalView.layer as? CAMetalLayer else { return }
        let scale = max(1, metalView.window?.backingScaleFactor ?? window?.backingScaleFactor ?? 1)
        guard let drawableSize = Self.nativeNVSTDrawableSize(boundsSize: metalView.bounds.size, backingScaleFactor: scale) else { return }
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = drawableSize
    }

    static func nativeNVSTDrawableSize(boundsSize: CGSize, backingScaleFactor: CGFloat) -> CGSize? {
        guard boundsSize.width.isFinite, boundsSize.height.isFinite, backingScaleFactor.isFinite,
              boundsSize.width >= 1, boundsSize.height >= 1, backingScaleFactor > 0 else { return nil }
        return CGSize(width: floor(boundsSize.width * backingScaleFactor), height: floor(boundsSize.height * backingScaleFactor))
    }

    public func setPointerLocked(_ locked: Bool) {
        if locked {
            guard !isPointerLocked else { return }
            enablePointerLock()
        } else {
            releasePressedMouseButtons()
            disablePointerLock()
            disableAbsoluteCursorConfinement()
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
        captureAbsoluteCursorIfNeeded()
        emitAbsoluteMousePosition(event)
        emitMouseButton(.left, isPressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(.left, isPressed: false)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        captureAbsoluteCursorIfNeeded()
        emitAbsoluteMousePosition(event)
        emitMouseButton(.right, isPressed: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        emitAbsoluteMousePosition(event)
        emitMouseButton(.right, isPressed: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        guard let button = mouseButton(event.buttonNumber) else { return }
        window?.makeFirstResponder(self)
        if capturePointerForMouseDown() { return }
        captureAbsoluteCursorIfNeeded()
        emitAbsoluteMousePosition(event)
        emitMouseButton(button, isPressed: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard remoteInputEnabled else { return }
        guard let button = mouseButton(event.buttonNumber) else { return }
        emitAbsoluteMousePosition(event)
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

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
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
        if handlePushToTalk(event, isPressed: true) { return }
        if handlePasteShortcut(event) { return }
        if handleCommand(event) { return }
        if handleTextInput(event) { return }
        emitKey(event, isPressed: true)
    }

    public override func keyUp(with event: NSEvent) {
        guard remoteInputEnabled else {
            if handleCommand(event) { return }
            super.keyUp(with: event)
            return
        }
        if handlePushToTalk(event, isPressed: false) { return }
        if handlePasteShortcut(event) { return }
        if handleCommand(event) { return }
        if textInputKeyCodes.remove(UInt16(event.keyCode)) != nil { return }
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
        if !isPointerLocked, mouseInputMode == .absolute {
            emitAbsoluteMousePosition(event)
            return
        }
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
        let delta = Self.accumulatedWheelDelta(
            scrollingDeltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            remainder: &preciseScrollRemainder
        )
        guard delta != 0 else { return }
        onInputEvent?(.mouse(.wheel(deviceID: "mouse", delta: delta, timestamp: Self.timestamp())))
    }

    private func enablePointerLock() {
        guard window != nil else { return }
        disableAbsoluteCursorConfinement()
        guard !isAbsoluteCursorConfined else { return }
        guard cursorAssociationHandler(false) == .success else {
            WebRTCMediaTelemetry.capture("webrtc.input.pointer_lock.failed", level: .error, message: "macOS rejected relative pointer capture.", attributes: ["locked": "false"])
            return
        }
        cursorAssociationGeneration &+= 1
        isPointerLocked = true
        pointerLockRestoreLocation = NSEvent.mouseLocation
        window?.acceptsMouseMovedEvents = true
        window?.makeFirstResponder(self)
        updatePointerLockCursorVisibility()
        installPointerLockMonitor()
        installPointerLockNotifications()
        notifyPointerLockChanged(true)
    }

    private func disablePointerLock() {
        guard isPointerLocked else { return }
        let associationResult = cursorAssociationHandler(true)
        cursorAssociationGeneration &+= 1
        let releaseGeneration = cursorAssociationGeneration
        if associationResult != .success {
            WebRTCMediaTelemetry.capture("webrtc.input.pointer_unlock.failed", level: .error, message: "macOS rejected relative pointer release.", attributes: ["locked": "true"])
            retryCursorAssociation(generation: releaseGeneration)
        }
        isPointerLocked = false
        removePointerLockMonitor()
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

    private func captureAbsoluteCursorIfNeeded() {
        guard remoteInputEnabled, directMouseInputEnabled, confinesCursorToWindowInAbsoluteMode,
              mouseInputMode == .absolute, !isPointerLocked, !isAbsoluteCursorConfined, window != nil else { return }
        guard let position = Self.confinedCursorPoint(NSEvent.mouseLocation, to: window?.frame ?? .zero) else { return }
        guard cursorAssociationHandler(false) == .success else {
            WebRTCMediaTelemetry.capture("webrtc.input.absolute_cursor_confinement.failed", level: .error, message: "macOS rejected absolute cursor confinement.", attributes: ["confined": "false"])
            return
        }
        cursorAssociationGeneration &+= 1
        isAbsoluteCursorConfined = true
        absoluteCursorPosition = position
        window?.acceptsMouseMovedEvents = true
        installPointerLockMonitor()
        installPointerLockNotifications()
        if let absoluteCursorPosition { moveCursor(toScreenPoint: absoluteCursorPosition) }
        WebRTCMediaTelemetry.capture("webrtc.input.absolute_cursor_confined", level: .info, message: "Absolute stream cursor confined to the window.", attributes: ["confined": "true"])
    }

    private func disableAbsoluteCursorConfinement() {
        guard isAbsoluteCursorConfined else { return }
        let associationResult = cursorAssociationHandler(true)
        cursorAssociationGeneration &+= 1
        let releaseGeneration = cursorAssociationGeneration
        if associationResult != .success {
            WebRTCMediaTelemetry.capture("webrtc.input.absolute_cursor_release.failed", level: .error, message: "macOS rejected absolute cursor release.", attributes: ["confined": "true"])
            retryCursorAssociation(generation: releaseGeneration)
        }
        isAbsoluteCursorConfined = false
        absoluteCursorPosition = nil
        if !isPointerLocked { removePointerLockMonitor() }
        WebRTCMediaTelemetry.capture("webrtc.input.absolute_cursor_confined", level: .info, message: "Absolute stream cursor confinement released.", attributes: ["confined": "false"])
    }

    private func retryCursorAssociation(generation: UInt, delay: TimeInterval = 0.01) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard cursorAssociationGeneration == generation, !isCursorCaptured else { return }
            if cursorAssociationHandler(true) != .success {
                retryCursorAssociation(generation: generation, delay: min(delay * 2, 1))
            }
        }
    }

    private func advanceAbsoluteCursor(with event: NSEvent) {
        guard isAbsoluteCursorConfined, let frame = window?.frame,
              let current = absoluteCursorPosition ?? Self.confinedCursorPoint(NSEvent.mouseLocation, to: frame),
              let next = Self.advancedAbsoluteCursorPoint(current, deltaX: event.deltaX, deltaY: event.deltaY, in: frame) else { return }
        absoluteCursorPosition = next
        moveCursor(toScreenPoint: next)
        let windowPoint = window?.convertPoint(fromScreen: next) ?? .zero
        let viewPoint = convert(windowPoint, from: nil)
        guard let absoluteEvent = absoluteMouseEvent(at: viewPoint, timestamp: Self.timestamp()) else { return }
        onAbsoluteMouseMove?(absoluteEvent)
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
                    self.advanceAbsoluteCursor(with: event)
                    return nil
                case .scrollWheel:
                    self.emitScrollWheel(event)
                    return nil
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

    private func removePointerLockMonitor() {
        guard let pointerLockMonitor else { return }
        NSEvent.removeMonitor(pointerLockMonitor)
        self.pointerLockMonitor = nil
    }

    private func installPointerLockNotifications() {
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

    static func advancedAbsoluteCursorPoint(_ point: CGPoint,
                                            deltaX: Double,
                                            deltaY: Double,
                                            in windowFrame: CGRect) -> CGPoint? {
        guard deltaX.isFinite, deltaY.isFinite else { return nil }
        return confinedCursorPoint(CGPoint(x: point.x + deltaX, y: point.y - deltaY), to: windowFrame)
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

    private func emitAbsoluteMousePosition(_ event: NSEvent) {
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
            timestamp: timestamp
        )
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

    private func emitCurrentAbsoluteMousePosition(timestamp: MediaTimestamp) {
        guard let window else { return }
        let screenPoint = absoluteCursorPosition ?? NSEvent.mouseLocation
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

    private func releasePressedMouseButtons() {
        releasePressedMouseButtons(pressedMouseButtons, timestamp: Self.timestamp())
    }

    private func releasePressedMouseButtons(_ buttons: Set<MouseButton>, timestamp: MediaTimestamp) {
        pressedMouseButtons.subtract(buttons)
        for button in buttons.sorted(by: { Self.mouseButtonOrder($0) < Self.mouseButtonOrder($1) }) {
            if mouseInputMode == .absolute { emitCurrentAbsoluteMousePosition(timestamp: timestamp) }
            onInputEvent?(.mouse(.button(deviceID: "mouse", button: button, isPressed: false, timestamp: timestamp)))
        }
    }

    private static func mouseButtonOrder(_ button: MouseButton) -> Int {
        switch button {
        case .left: 0
        case .middle: 1
        case .right: 2
        case .back: 3
        case .forward: 4
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
        WebRTCMediaStreamCommand.shortcutCommand(keyCode: UInt16(event.keyCode), modifierFlags: event.modifierFlags)
    }

    private func installKeyEquivalentMonitor() {
        guard keyEquivalentMonitor == nil else { return }
        keyEquivalentMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            guard self.window?.isKeyWindow == true,
                  Self.isStreamWindowKeyEvent(event.window, streamWindow: self.window) else {
                self.releaseRemotelyPressedKeyIfNeeded(event)
                return event
            }
            guard NSApplication.shared.isActive else {
                self.releaseRemotelyPressedKeyIfNeeded(event)
                return event
            }
            guard self.remoteInputEnabled else { return self.handleCommand(event) ? nil : event }
            if self.handlePushToTalk(event, isPressed: event.type == .keyDown) { return nil }
            let routesToApplication = Self.reservesApplicationMenuKeyEquivalent(event.modifierFlags)
            if routesToApplication { self.releaseRemotelyPressedKeyIfNeeded(event) }
            if self.handlePasteShortcut(event) { return nil }
            if self.handleCommand(event) { return nil }
            if routesToApplication { return event }
            if event.type == .keyDown {
                if !self.handleTextInput(event) { self.emitKey(event, isPressed: true) }
            } else if self.textInputKeyCodes.remove(UInt16(event.keyCode)) == nil {
                self.emitKey(event, isPressed: false)
            }
            return nil
        }
    }

    static func reservesApplicationMenuKeyEquivalent(_ modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
    }

    static func isStreamWindowKeyEvent(_ eventWindow: NSWindow?, streamWindow: NSWindow?) -> Bool {
        guard let eventWindow, let streamWindow else { return false }
        return eventWindow === streamWindow
    }

    private func removeKeyEquivalentMonitor() {
        guard let keyEquivalentMonitor else { return }
        NSEvent.removeMonitor(keyEquivalentMonitor)
        self.keyEquivalentMonitor = nil
    }

    private func emitKey(_ event: NSEvent, isPressed: Bool) {
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

    private func handleTextInput(_ event: NSEvent) -> Bool {
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
        return !characters.unicodeScalars.allSatisfy(\.isASCII)
    }

    private func handlePushToTalk(_ event: NSEvent, isPressed: Bool) -> Bool {
        pushToTalkState?.handle(Self.keyboardEvent(from: event, isPressed: isPressed)) == true
    }

    private static func keyboardEvent(from event: NSEvent, isPressed: Bool) -> KeyboardEvent {
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

    private static func string(from value: Any) -> String {
        if let attributed = value as? NSAttributedString { return attributed.string }
        return value as? String ?? ""
    }

    private static func attributedString(from value: Any) -> NSAttributedString {
        if let attributed = value as? NSAttributedString { return attributed }
        return NSAttributedString(string: value as? String ?? "")
    }

    private func releaseRemotelyPressedKeyIfNeeded(_ event: NSEvent) {
        guard event.type == .keyUp, pressedKeyboardEvents[UInt16(event.keyCode)] != nil else { return }
        emitKey(event, isPressed: false)
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
