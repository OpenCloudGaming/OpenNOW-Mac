import AppKit
import QuartzCore

final class NativeWebRTCVideoSurfaceView: NSView {
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

final class NativeNVSTRendererWindow: NSWindow {
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
    case togglePointerCapture
    case showQuitMenu
    case toggleOnScreenKeyboard

    static let shortcutGuide = "⌘G HUD   ⌘N Stats   ⌘M Mic   ⌘R Rec   ⌘K AFK   ⌘P Capture   ⌘Q Quit"

    static func shortcutCommand(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> WebRTCMediaStreamCommand? {
        let modifiers = modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        guard modifiers == .command else { return nil }
        switch keyCode {
        case 46: return .toggleMicrophone
        case 15: return .toggleRecording
        case 40: return .toggleAntiAFK
        case 45: return .toggleStatsHUD
        case 5: return .toggleUnifiedHUD
        case 35: return .togglePointerCapture
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
    /// Always clamped to `markedText.length`, which only `setMarkedText` maintains.
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
    private var isPressed = false

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

public final class NativeWebRTCStreamView: NSView {
    public var onInputEvent: ((UserInputEvent) -> Void)?
    public var onAbsoluteMouseMove: ((NativeNVSTAbsoluteMouseEvent) -> Void)?
    public var onGamepadTopologyChanged: ((NativeWebRTCGamepadTopology) -> Void)?
    /// Fires whenever the mode input actually travels in changes — mode switches and pointer-lock
    /// changes both, because a manual capture sends relative deltas from an absolute mode.
    public var onMouseInputModeChanged: ((NativeStreamMouseInputMode) -> Void)?
    public var onPointerLockChanged: ((Bool) -> Void)?
    public var onCommand: ((WebRTCMediaStreamCommand) -> Void)?
    public var shouldHandleCommand: ((WebRTCMediaStreamCommand) -> Bool)?
    /// Gamepad states delivered while `remoteInputEnabled` is false, for local
    /// overlay navigation (unified HUD, quit menu).
    public var onLocalGamepadState: ((GamepadState) -> Void)?
    var cursorAssociationHandler: (Bool) -> CGError = {
        CGAssociateMouseAndMouseCursorPosition(boolean_t($0 ? 1 : 0))
    }
    // `internal(set)` rather than `private(set)`: the type's own extensions in the neighbouring
    // files write these, and the public contract is unchanged — nothing outside the module can.
    public internal(set) var isPointerLocked = false
    public internal(set) var isAbsoluteCursorConfined = false
    public internal(set) var isEmittingNeutralizingAbsolutePosition = false
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
            preciseHorizontalScrollRemainder = 0
        }
        didSet {
            guard oldValue != mouseInputMode else { return }
            if mouseInputMode == .absolute {
                disablePointerLock()
            } else {
                disableAbsoluteCursorConfinement()
                restoreInputFocus()
            }
            applyLocalCursorPolicy()
            onMouseInputModeChanged?(effectiveMouseMode)
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
            applyLocalCursorPolicy()
        }
    }
    public var directMouseInputEnabled = true {
        didSet {
            guard oldValue != directMouseInputEnabled else { return }
            // Turning the preference off gives back a pointer the client took by hand or off a
            // click. It deliberately does not end the seat's own mouselook: that is a property of
            // the game, not of this preference, and dropping the lock there would leave relative
            // mode running with a free pointer walking out of the window.
            if !directMouseInputEnabled, mouseInputMode == .absolute { setPointerLocked(false) }
            applyLocalCursorPolicy()
        }
    }
    /// Whether a click on the video may take the pointer for relative capture. Following the seat
    /// into mouselook is deliberately *not* gated on this: a seat that hides its cursor is a game
    /// with no pointer to aim, where absolute coordinates mean nothing, so the client has to follow
    /// it there whatever the preference says. Gating both on one flag is what made Direct Mouse
    /// Input off silently mean "absolute forever" and put mouselook out of reach.
    var allowsRelativeCapture: Bool { directMouseInputEnabled }
    /// The mode input is actually travelling in. A manual capture sends relative deltas even while
    /// `mouseInputMode` still reads `.absolute`, so anything reporting the mode must read this.
    public var effectiveMouseMode: NativeStreamMouseInputMode { isPointerLocked ? .relative : mouseInputMode }
    /// Feed relative motion from raw HID counts rather than the deltas macOS has already
    /// accelerated. Only consulted while the pointer is locked.
    public var rawMouseInputEnabled = false {
        didSet {
            guard oldValue != rawMouseInputEnabled, isPointerLocked else { return }
            if rawMouseInputEnabled {
                startRawMouseCaptureIfNeeded()
            } else {
                stopRawMouseCapture()
            }
        }
    }
    /// Whose pointer is drawn over the video while the game shows one of its own.
    public var cursorPolicy: OPNCursorPolicy = .auto {
        didSet {
            guard oldValue != cursorPolicy else { return }
            applyLocalCursorPolicy()
        }
    }
    /// A capture the player asked for by hand through `setManualPointerCapture`. Seat cursor
    /// notifications must not undo it: the games it exists for never hide their cursor, so every
    /// notification would otherwise hand the pointer back mid-fight.
    public internal(set) var manualPointerCaptureOverride = false
    /// The Steam guide chord is driving the real macOS pointer through
    /// `SteamControllerLocalCursorInjector` so the player can click their way back into the app.
    /// That pointer has to stay drawn over the picture or there is nothing to aim with.
    public var localCursorInjectionActive = false {
        didSet {
            guard oldValue != localCursorInjectionActive else { return }
            applyLocalCursorPolicy()
        }
    }
    /// What the seat last said about the game's own pointer. Nil until it has said anything, which
    /// is also while the seat is still compositing a cursor of its own into the video.
    public internal(set) var remoteCursorWantsPointer: Bool? {
        didSet {
            guard oldValue != remoteCursorWantsPointer else { return }
            applyLocalCursorPolicy()
        }
    }
    /// Whether the seat is still compositing a pointer of its own into the video. True until the
    /// transport says otherwise, because that is what the activation chain asks for: capture is on
    /// from the first frame and only switched off later. The seat can stop compositing without ever
    /// publishing a visibility — a bitmap-only notification, or the watchdog firing on a seat that
    /// publishes nothing — so this, not `remoteCursorWantsPointer`, is what says whether hiding the
    /// local pointer still leaves one on screen.
    public internal(set) var seatCompositesCursor = true {
        didSet {
            guard oldValue != seatCompositesCursor else { return }
            applyLocalCursorPolicy()
        }
    }
    /// Mirrors the host overlay's hit-testing state so the native Geronimo
    /// pump can stop draining the NSApp event queue while overlay buttons
    /// are waiting on those mouse events.
    public var localOverlayCapturesInput = false {
        didSet {
            guard oldValue != localOverlayCapturesInput else { return }
            applyLocalCursorPolicy()
        }
    }
    /// Passthrough to the gamepad monitor: while this returns true for a Steam
    /// Controller report, the raw snapshot goes to the on-screen keyboard instead
    /// of the binding engine. Set by the active stream host.
    public var onScreenKeyboardCapture: ((InputDeviceID, SteamControllerInputSnapshot) -> Bool)? {
        get { gamepadMonitor.onScreenKeyboardCapture }
        set { gamepadMonitor.onScreenKeyboardCapture = newValue }
    }
    public var hidesCursorWhilePointerLocked = true {
        didSet {
            guard isPointerLocked else { return }
            updatePointerLockCursorVisibility()
        }
    }
    var trackingArea: NSTrackingArea?
    var keyEquivalentMonitor: Any?
    var pointerLockMonitor: Any?
    var absoluteCursorGlobalMonitor: Any?
    var pointerLockNotificationTokens: [NSObjectProtocol] = []
    var pointerLockRestoreLocation: CGPoint?
    var pointerLockCursorHidden = false
    var cursorAssociationGeneration: UInt = 0
    var preciseScrollRemainder = 0.0
    /// The sideways carry, kept apart from the vertical one: a diagonal trackpad swipe feeds both
    /// axes at once, and a shared carry would spend the sideways fraction on a vertical notch.
    var preciseHorizontalScrollRemainder = 0.0
    /// Which axis the gesture in progress is allowed to move. A scroll gesture is delivered to one
    /// view for its whole life, so the latch lives with the carries it gates.
    var scrollAxisFilter = NativeWebRTCScrollAxisFilter()
    /// Multiplier on relative mouse deltas before they go to the seat. Fractions carry over between
    /// events so slow movements are not lost to rounding at low settings.
    public var mouseSensitivity = 1.0
    var mouseDeltaRemainder = CGPoint.zero
    var pressedKeyboardEvents: [UInt16: KeyboardEvent] = [:]
    var textInputState = NativeNVSTTextInputState()
    var textInputKeyCodes: Set<UInt16> = []
    var pushToTalkState: NativeNVSTPushToTalkState?
    var pressedMouseButtons: Set<MouseButton> = []
    var lastEmittedAbsoluteMouseEvent: NativeNVSTAbsoluteMouseEvent?
    var hidesLocalCursorOverVideo = false
    var activeGamepadStates: [Int: GamepadState] = [:]
    var streamContentSize = CGSize.zero
    let videoSurface = NativeWebRTCVideoSurfaceView(frame: .zero)
    var pillarboxFillMode: OPNPillarboxFillMode = .black
    private var pillarboxFillDim: Int = 55
    private var upscalingMode: Int = 0
    private var upscalingSharpness: Int = 0
    private var upscalingDenoise: Int = 0
    private var upscalingTargetHeight: Int = 2160
    let nativeNVSTRendererWindow = NativeNVSTRendererWindow(
        contentRect: .zero,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    weak var nativeNVSTRendererParentWindow: NSWindow?
    weak var nativeNVSTMetalView: NSView?
    var nativeNVSTDisplayNotificationTokens: [NSObjectProtocol] = []
    var nativeNVSTRendererEnabled = false
    var nativeNVSTRendererPreparedForShutdown = false
    var nativeNVSTVideoVisible = false
    private let gamepadMonitor = NativeWebRTCGamepadMonitor()
    var nvstBifrostFreeRenderer: NvstBifrostFreeVideoRenderer?
    var presentationMode = 0

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(videoSurface)
        // Clip the video layer when crop/stretch grows it past the surface edges so
        // the pushed-out bars are cropped instead of drawn beyond the picture.
        videoSurface.layer?.masksToBounds = true
        nativeNVSTRendererWindow.backgroundColor = .clear
        nativeNVSTRendererWindow.contentView = NativeWebRTCVideoSurfaceView(frame: .zero)
        nativeNVSTRendererWindow.hasShadow = false
        nativeNVSTRendererWindow.ignoresMouseEvents = true
        nativeNVSTRendererWindow.isOpaque = false
        nativeNVSTRendererWindow.alphaValue = 0
        nativeNVSTRendererWindow.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        gamepadMonitor.onInputEvent = { [weak self] event in self?.handleGamepadEvent(event) }
        gamepadMonitor.onLocalCursorInjectionChanged = { [weak self] active in self?.localCursorInjectionActive = active }
        gamepadMonitor.onChordCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .toggleUnifiedHUD: self.onCommand?(.toggleUnifiedHUD)
            case .toggleOnScreenKeyboard: self.onCommand?(.toggleOnScreenKeyboard)
            }
        }
        gamepadMonitor.onTopologyChanged = { [weak self] topology in
            guard let self else { return }
            self.activeGamepadStates = self.activeGamepadStates.filter { topology.playerIndices.contains($0.key) }
            self.onGamepadTopologyChanged?(topology)
        }
        gamepadMonitor.start()
    }

    /// The `...` quick-access HUD toggle and the Steam+X on-screen keyboard chord
    /// are resolved in the gamepad monitor ahead of the binding engine, so
    /// quickAccess never reaches this point. Remote input disabled means a local
    /// overlay owns the pad: hand gamepad state to the host instead of the stream.
    private func handleGamepadEvent(_ event: UserInputEvent) {
        guard case .gamepad(let state) = event else {
            guard remoteInputEnabled else { return }
            onInputEvent?(event)
            return
        }
        routeGamepadState(state)
    }

    /// Remote input disabled means a local overlay owns the pad: hand the
    /// state to the host for HUD/quit-menu navigation instead of the stream.
    private func routeGamepadState(_ state: GamepadState) {
        if remoteInputEnabled {
            receiveGamepadState(state)
        } else {
            onLocalGamepadState?(state)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// `NSCursor.hide()` is a process-wide counter, and this view is its only owner. Every ordinary
    /// route out of a pointer lock unhides first; a view torn down while one is still raised would
    /// take the pointer with it for the life of the process, with nothing left to balance it.
    deinit {
        let unhidesCursor = pointerLockCursorHidden
        // The raw reader is a process-wide singleton listening to every mouse on the system, and
        // only `disablePointerLock` stops it: a view released while the pointer is still locked
        // (teardown that drops the host before it unlocks) would leave it reading for the rest of
        // the app's life.
        let stopsRawMouseCapture = isPointerLocked
        guard unhidesCursor || stopsRawMouseCapture else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if unhidesCursor { NSCursor.unhide() }
                if stopsRawMouseCapture { OPNRawMouseHIDMonitor.shared.stop() }
            }
        }
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
        // The window is a policy input (cursor rects only apply to the key window of the active
        // app) and moving between windows produces no crossing to notice it by.
        applyLocalCursorPolicy()
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
        window?.invalidateCursorRects(for: self)
    }

    /// Selects the NVST pillarbox fill.
    ///
    /// Bifrost-free NVST decodes in-process and draws through the same `OPNMetalVideoView` as
    /// WebRTC, so every mode is the shared fill shader now: the enhancement renderer's detector
    /// measures the baked bars off the luma plane and the shader paints (mirror/zoom) or
    /// reprojects (stretch/crop) them. The Geronimo-era overlay and layer-geometry paths are gone
    /// with the vendored libraries — they depended on a decoded-frame tap that no longer exists,
    /// which is why all four modes had silently stopped working.
    public func setPillarboxFill(mode: Int, dim: Int) {
        pillarboxFillMode = OPNPillarboxFillMode.from(mode)
        pillarboxFillDim = dim
        pushBifrostFreeVideoSettings()
    }

    /// Sets the MetalFX upscaling tier and target resolution for the Bifrost-free NVST path.
    /// `targetHeight` caps the render drawable's height; the window still governs everything
    /// below that cap, so this never forces supersampling past what the window would draw anyway.
    public func setVideoEnhancement(mode: Int, sharpness: Int, denoise: Int, targetHeight: Int) {
        upscalingMode = mode
        upscalingSharpness = sharpness
        upscalingDenoise = denoise
        upscalingTargetHeight = targetHeight
        pushBifrostFreeVideoSettings()
    }

    /// How decoded frames meet the display on the Bifrost-free NVST path. See
    /// `OPNVideoPresentationMode`.
    public func setPresentationMode(_ mode: Int) {
        presentationMode = mode
        pushBifrostFreeVideoSettings()
    }

    /// Pushes the enhancement and fill settings into the Bifrost-free renderer, which has no
    /// libwebrtc session to pull them from. Also called on attach so settings chosen before the
    /// stream starts apply.
    private func pushBifrostFreeVideoSettings() {
        OpenNOWLog.info(.stream, "Video enhancement pushed mode=\(upscalingMode) target=\(upscalingTargetHeight) pillarbox=\(pillarboxFillMode.label) dim=\(pillarboxFillDim) renderer=\(nvstBifrostFreeRenderer != nil)")
        nvstBifrostFreeRenderer?.setVideoEnhancement(mode: upscalingMode,
                                                     sharpness: upscalingSharpness,
                                                     denoise: upscalingDenoise,
                                                     targetHeight: upscalingTargetHeight,
                                                     pillarboxFillMode: pillarboxFillMode.rawValue,
                                                     pillarboxFillDim: pillarboxFillDim,
                                                     pillarboxFillColor: 0)
        nvstBifrostFreeRenderer?.setPresentationMode(OPNVideoPresentationMode(rawValue: presentationMode) ?? .balanced)
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

    /// Attaches the Bifrost-free NVST renderer to the shared video surface. Unlike the Geronimo
    /// path, this transport decodes in-process and draws through the same Metal view the WebRTC
    /// path uses, so it needs no borderless renderer window.
    public func attachNvstBifrostFreeRenderer(targetFps: Int32) -> NvstBifrostFreeVideoRenderer {
        nvstBifrostFreeRenderer?.detach()
        // The seat's cursor state is per-session: it stops publishing notifications between
        // sessions and starts the next one compositing a cursor of its own again, so a stale
        // "the game shows a pointer" from the last game would draw a second one over this one.
        remoteCursorWantsPointer = nil
        seatCompositesCursor = true
        let renderer = NvstBifrostFreeVideoRenderer(parentView: videoSurface, targetFps: targetFps)
        renderer.onDecodedSizeChanged = { [weak self] width, height in
            self?.setStreamContentSize(width: width, height: height)
        }
        nvstBifrostFreeRenderer = renderer
        pushBifrostFreeVideoSettings()
        return renderer
    }

    public func detachNvstBifrostFreeRenderer() {
        nvstBifrostFreeRenderer?.detach()
        nvstBifrostFreeRenderer = nil
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

}

extension NativeWebRTCStreamView: @preconcurrency NSTextInputClient {}
