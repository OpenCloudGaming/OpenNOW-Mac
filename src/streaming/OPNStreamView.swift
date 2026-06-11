import AppKit
import ApplicationServices
import AudioToolbox
import CoreVideo
import GameController
import QuartzCore

typealias OPNStreamInputReadyProvider = @convention(block) () -> Bool
typealias OPNStreamBooleanHandler = @convention(block) (Bool) -> Void
typealias OPNStreamIntegerHandler = @convention(block) (Int) -> Void
typealias OPNStreamDoubleHandler = @convention(block) (Double) -> Void
typealias OPNStreamTextHandler = @convention(block) (String) -> Void
typealias OPNStreamKeyEventHandler = @convention(block) (UInt16, UInt16, UInt16, Bool) -> Void
typealias OPNStreamMouseMoveHandler = @convention(block) (Int16, Int16) -> Void
typealias OPNStreamMouseButtonHandler = @convention(block) (UInt8, Bool) -> Void
typealias OPNStreamMouseWheelHandler = @convention(block) (Int16) -> Void
typealias OPNStreamGamepadStateHandler = @convention(block) (UInt16, UInt16, UInt8, UInt8, Int16, Int16, Int16, Int16, Bool, UInt16, UInt64) -> Void
typealias OPNStreamVideoEnhancementHandler = @convention(block) (Int, Int, Int, Int) -> Void

private struct OPNStreamKeyMapping { let vk: UInt16; let scancode: UInt16 }
private struct OPNStreamGamepadState: Equatable {
    var controllerId: UInt16 = 0
    var buttons: UInt16 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
    var leftStickX: Int16 = 0
    var leftStickY: Int16 = 0
    var rightStickX: Int16 = 0
    var rightStickY: Int16 = 0
    var connected = false
    var timestampUs: UInt64 = 0
}
private struct OPNPadSnapshot { var known = false; var state = OPNStreamGamepadState() }

@objcMembers
@objc(OPNStreamView)
final class OPNStreamView: NSView {
    private static let mouseLeft: UInt8 = 1
    private static let mouseMiddle: UInt8 = 2
    private static let mouseRight: UInt8 = 3
    private static let mouseBack: UInt8 = 4
    private static let mouseForward: UInt8 = 5
    private static let gamepadMaxControllers = 4
    private static let gamepadDeadzone = 0.15
    private static let keyMap: [UInt16: OPNStreamKeyMapping] = [
        0: .init(vk: 0x41, scancode: 0x001e), 1: .init(vk: 0x53, scancode: 0x001f), 2: .init(vk: 0x44, scancode: 0x0020), 3: .init(vk: 0x46, scancode: 0x0021), 4: .init(vk: 0x48, scancode: 0x0023), 5: .init(vk: 0x47, scancode: 0x0022), 6: .init(vk: 0x5a, scancode: 0x002c), 7: .init(vk: 0x58, scancode: 0x002d), 8: .init(vk: 0x43, scancode: 0x002e), 9: .init(vk: 0x56, scancode: 0x002f), 11: .init(vk: 0x42, scancode: 0x0030), 12: .init(vk: 0x51, scancode: 0x0010), 13: .init(vk: 0x57, scancode: 0x0011), 14: .init(vk: 0x45, scancode: 0x0012), 15: .init(vk: 0x52, scancode: 0x0013), 16: .init(vk: 0x59, scancode: 0x0015), 17: .init(vk: 0x54, scancode: 0x0014), 18: .init(vk: 0x31, scancode: 0x0002), 19: .init(vk: 0x32, scancode: 0x0003), 20: .init(vk: 0x33, scancode: 0x0004), 21: .init(vk: 0x34, scancode: 0x0005), 22: .init(vk: 0x36, scancode: 0x0007), 23: .init(vk: 0x35, scancode: 0x0006), 24: .init(vk: 0xbb, scancode: 0x000d), 25: .init(vk: 0x39, scancode: 0x000a), 26: .init(vk: 0x37, scancode: 0x0008), 27: .init(vk: 0xbd, scancode: 0x000c), 28: .init(vk: 0x38, scancode: 0x0009), 29: .init(vk: 0x30, scancode: 0x000b), 30: .init(vk: 0xdd, scancode: 0x001b), 31: .init(vk: 0x4f, scancode: 0x0018), 32: .init(vk: 0x55, scancode: 0x0016), 33: .init(vk: 0xdb, scancode: 0x001a), 34: .init(vk: 0x49, scancode: 0x0017), 35: .init(vk: 0x50, scancode: 0x0019), 36: .init(vk: 0x0d, scancode: 0x001c), 37: .init(vk: 0x4c, scancode: 0x0026), 38: .init(vk: 0x4a, scancode: 0x0024), 39: .init(vk: 0xde, scancode: 0x0028), 40: .init(vk: 0x4b, scancode: 0x0025), 41: .init(vk: 0xba, scancode: 0x0027), 42: .init(vk: 0xdc, scancode: 0x002b), 43: .init(vk: 0xbc, scancode: 0x0033), 44: .init(vk: 0xbf, scancode: 0x0035), 45: .init(vk: 0x4e, scancode: 0x0031), 46: .init(vk: 0x4d, scancode: 0x0032), 47: .init(vk: 0xbe, scancode: 0x0034), 48: .init(vk: 0x09, scancode: 0x000f), 49: .init(vk: 0x20, scancode: 0x0039), 50: .init(vk: 0xc0, scancode: 0x0029), 51: .init(vk: 0x08, scancode: 0x000e), 53: .init(vk: 0x1b, scancode: 0x0001), 55: .init(vk: 0x5b, scancode: 0xe05b), 56: .init(vk: 0xa0, scancode: 0x002a), 57: .init(vk: 0x14, scancode: 0x003a), 58: .init(vk: 0xa4, scancode: 0x0038), 59: .init(vk: 0xa2, scancode: 0x001d), 60: .init(vk: 0xa1, scancode: 0x0036), 61: .init(vk: 0xa5, scancode: 0xe038), 62: .init(vk: 0xa3, scancode: 0xe01d), 65: .init(vk: 0x6e, scancode: 0x0053), 67: .init(vk: 0x6a, scancode: 0x0037), 69: .init(vk: 0x6b, scancode: 0x004e), 71: .init(vk: 0x90, scancode: 0xe045), 75: .init(vk: 0x6f, scancode: 0xe035), 76: .init(vk: 0x0d, scancode: 0xe01c), 78: .init(vk: 0x6d, scancode: 0x004a), 81: .init(vk: 0xbb, scancode: 0x0059), 82: .init(vk: 0x60, scancode: 0x0052), 83: .init(vk: 0x61, scancode: 0x004f), 84: .init(vk: 0x62, scancode: 0x0050), 85: .init(vk: 0x63, scancode: 0x0051), 86: .init(vk: 0x64, scancode: 0x004b), 87: .init(vk: 0x65, scancode: 0x004c), 88: .init(vk: 0x66, scancode: 0x004d), 89: .init(vk: 0x67, scancode: 0x0047), 91: .init(vk: 0x68, scancode: 0x0048), 92: .init(vk: 0x69, scancode: 0x0049), 96: .init(vk: 0x74, scancode: 0x003f), 97: .init(vk: 0x75, scancode: 0x0040), 98: .init(vk: 0x76, scancode: 0x0041), 99: .init(vk: 0x72, scancode: 0x003d), 100: .init(vk: 0x77, scancode: 0x0042), 101: .init(vk: 0x78, scancode: 0x0043), 103: .init(vk: 0x7a, scancode: 0x0057), 105: .init(vk: 0x7c, scancode: 0x0064), 106: .init(vk: 0x7f, scancode: 0x0067), 107: .init(vk: 0x7d, scancode: 0x0065), 109: .init(vk: 0x79, scancode: 0x0044), 111: .init(vk: 0x7b, scancode: 0x0058), 113: .init(vk: 0x7e, scancode: 0x0066), 114: .init(vk: 0x2d, scancode: 0xe052), 115: .init(vk: 0x24, scancode: 0xe047), 116: .init(vk: 0x21, scancode: 0xe049), 117: .init(vk: 0x2e, scancode: 0xe053), 118: .init(vk: 0x73, scancode: 0x003e), 119: .init(vk: 0x23, scancode: 0xe04f), 120: .init(vk: 0x71, scancode: 0x003c), 121: .init(vk: 0x22, scancode: 0xe051), 122: .init(vk: 0x70, scancode: 0x003b), 123: .init(vk: 0x25, scancode: 0xe04b), 124: .init(vk: 0x27, scancode: 0xe04d), 125: .init(vk: 0x28, scancode: 0xe050), 126: .init(vk: 0x26, scancode: 0xe048)
    ]

    var onUserActivity: (() -> Void)?
    var onDashboardToggleRequested: (() -> Void)?
    var onSidebarHUDVisibilityChanged: ((Bool) -> Void)?
    var streamInputReadyProvider: OPNStreamInputReadyProvider?
    var streamMicrophoneEnabledHandler: OPNStreamBooleanHandler?
    var streamGameVolumeHandler: OPNStreamDoubleHandler?
    var streamMicrophoneVolumeHandler: OPNStreamDoubleHandler?
    var streamMaxBitrateHandler: OPNStreamIntegerHandler?
    var streamEnhancedVideoCaptureHandler: OPNStreamBooleanHandler?
    var streamVideoEnhancementHandler: OPNStreamVideoEnhancementHandler?
    var streamUtf8TextHandler: OPNStreamTextHandler?
    var streamKeyEventHandler: OPNStreamKeyEventHandler?
    var streamMouseMoveHandler: OPNStreamMouseMoveHandler?
    var streamMouseButtonHandler: OPNStreamMouseButtonHandler?
    var streamMouseWheelHandler: OPNStreamMouseWheelHandler?
    var streamGamepadStateHandler: OPNStreamGamepadStateHandler?

    private var attachedPipeline: UnsafeMutableRawPointer?
    private var streamActive = false
    private var gamepadTimer: DispatchSourceTimer?
    private var escapeHoldTimer: DispatchSourceTimer?
    private var cursorCaptured = false
    private var cursorHidden = false
    private var mouseButtonsDown: UInt8 = 0
    private var gamepadBitmap: UInt16 = 0
    private var modifierDown = Array(repeating: false, count: 128)
    private var microphoneMode = "disabled"
    private var pushToTalkKeyCode: UInt16 = 9
    private var pushToTalkModifierMask: UInt16 = 0
    private var pushToTalkPrimaryKeyDown = false
    private var pushToTalkMicEnabled = false
    private var microphoneShortcutEnabled = true
    private var suppressInputWhenWindowInactive = true
    private var streamInputSuppressed = false
    private var directMouseInputEnabled = true
    private var sidebarOpen = false
    private var gameVolume = 1.0
    private var microphoneVolumeLevel = 1.0
    private var microphoneLevel = 0.0
    private var pendingMouseDx = 0.0
    private var pendingMouseDy = 0.0
    private var maxBitrateMbps = 50
    private var videoUpscalingMode = 0
    private var videoUpscalingTargetHeight = 2160
    private var videoUpscalingSharpness = 4
    private var videoUpscalingDenoise = 0
    private var videoStreamWidth = 0
    private var videoStreamHeight = 0
    private var recordingEnhancedVideoEnabled = false
    private var remainingPlaytimeBaseSeconds = 0.0
    private var remainingPlaytimeStartTime = 0.0
    private var remainingPlaytimeUnlimited = false
    private var remainingPlaytimeAvailable = false
    private var previousPads = Array(repeating: OPNPadSnapshot(), count: gamepadMaxControllers)
    private var startButtonHoldBegan = Array(repeating: 0.0, count: gamepadMaxControllers)
    private var startButtonHoldConsumed = Array(repeating: false, count: gamepadMaxControllers)
    private var lastGamepadSend = Array(repeating: 0.0, count: gamepadMaxControllers)
    private var videoSurface: OPNVideoSurfaceView!
    private var microphoneActiveOverlay: NSView!
    private var sidebarHUD: NSView?
    private var sidebarMicStatusValue: NSTextField?
    private var sidebarPlaytimeValue: NSTextField?
    private var sidebarRecordingStatusValue: NSTextField?
    private var playtimeTimer: Timer?
    private var upscalingModePopup: NSPopUpButton?
    private var upscalingSharpnessSlider: NSSlider?
    private var upscalingDenoiseSlider: NSSlider?
    private var gameVolumeSlider: NSSlider?
    private var microphoneVolumeSlider: NSSlider?
    private var microphoneMeterTrack: NSView?
    private var microphoneMeterFill: CALayer?
    private var recordingButton: NSButton?
    private(set) var recordingManager = OPNStreamRecordingManager()
    private var recordingGameTitle = "Stream"
    private var videoAspectRatio: CGFloat = 16.0 / 9.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        initialize()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        initialize()
    }

    deinit {
        MainActor.assumeIsolated {
            playtimeTimer?.invalidate()
            stopRecordingIfNeeded()
            stopGamepadPolling()
            cancelEscapeHoldTimer()
            releaseCursorCapture()
            NotificationCenter.default.removeObserver(self)
        }
    }

    private func initialize() {
        let profile = OPNStreamViewPreferences.loadViewPreferenceSnapshot()
        directMouseInputEnabled = profile.directMouseInput
        microphoneShortcutEnabled = profile.microphoneShortcutEnabled
        gameVolume = profile.gameVolume
        microphoneVolumeLevel = profile.microphoneVolume
        maxBitrateMbps = Int(profile.maxBitrateMbps)
        videoUpscalingMode = profile.lowLatencyMode ? 0 : Int(profile.upscalingMode)
        videoUpscalingTargetHeight = Int(profile.upscalingTargetHeight)
        videoUpscalingSharpness = Int(profile.upscalingSharpness)
        videoUpscalingDenoise = Int(profile.upscalingDenoise)
        videoStreamWidth = Int(profile.streamWidth)
        videoStreamHeight = Int(profile.streamHeight)
        recordingEnhancedVideoEnabled = profile.lowLatencyMode ? false : profile.recordingEnhancedVideoEnabled
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoSurface = OPNVideoSurfaceView(frame: bounds)
        applyVideoUpscalingFilters(to: videoSurface)
        addSubview(videoSurface)
        createMicrophoneActiveOverlay()
        createSidebarHUD(profile: profile)
        registerForControllerNotifications()
        recordingManager.onStateChanged = { [weak self] in
            self?.updateEnhancedVideoRecordingPreference()
            self?.updateRecordingControls()
        }
    }

    func setStreamActive(_ active: Bool) {
        streamActive = active
        if active {
            streamGameVolumeHandler?(gameVolume)
            streamMicrophoneVolumeHandler?(microphoneVolumeLevel)
            streamMaxBitrateHandler?(maxBitrateMbps)
            streamVideoEnhancementHandler?(videoUpscalingMode, videoUpscalingSharpness, videoUpscalingDenoise, videoUpscalingTargetHeight)
            updateEnhancedVideoRecordingPreference()
            startGamepadPolling()
            applyMicrophoneShortcutState()
        } else {
            stopGamepadPolling()
            pendingMouseDx = 0
            pendingMouseDy = 0
            pushToTalkPrimaryKeyDown = false
            pushToTalkMicEnabled = false
            setMicrophoneLevel(0)
            setMicrophoneActive(false)
            cancelEscapeHoldTimer()
            releaseCursorCapture()
        }
    }

    func clearStreamCallbacks() {
        streamInputReadyProvider = nil
        streamMicrophoneEnabledHandler = nil
        streamGameVolumeHandler = nil
        streamMicrophoneVolumeHandler = nil
        streamMaxBitrateHandler = nil
        streamEnhancedVideoCaptureHandler = nil
        streamVideoEnhancementHandler = nil
        streamUtf8TextHandler = nil
        streamKeyEventHandler = nil
        streamMouseMoveHandler = nil
        streamMouseButtonHandler = nil
        streamMouseWheelHandler = nil
        streamGamepadStateHandler = nil
    }

    func receiveMicrophoneLevel(_ level: Double) { DispatchQueue.main.async { self.setMicrophoneLevel(level) } }
    func receiveVideoFrame(_ frame: UnsafeMutableRawPointer?) { recordingManager.appendWebRTCVideoFrame(frame) }
    func receiveEnhancedVideoFrame(_ pixelBuffer: UnsafeMutableRawPointer?) {
        guard let pixelBuffer else { return }
        recordingManager.appendEnhancedPixelBuffer(Unmanaged<CVPixelBuffer>.fromOpaque(pixelBuffer).takeUnretainedValue())
    }
    func receiveClipboardText(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        log("[StreamView] Remote clipboard copied to macOS pasteboard (\(text.count) chars)")
    }

    func setMaxBitrateMbps(_ mbps: Int) {
        maxBitrateMbps = max(1, min(mbps, 250))
        streamMaxBitrateHandler?(maxBitrateMbps)
    }

    func setMicrophoneMode(_ mode: String, pushToTalkKeyCode keyCode: UInt16, modifierMask: UInt16) {
        microphoneMode = mode.isEmpty ? "disabled" : mode
        pushToTalkKeyCode = keyCode
        pushToTalkModifierMask = normalizedPushToTalkModifierMask(keyCode: keyCode, modifierMask: modifierMask)
        pushToTalkPrimaryKeyDown = false
        pushToTalkMicEnabled = false
        applyMicrophoneShortcutState()
    }

    func toggleMicrophoneEnabledShortcut() -> Bool {
        guard microphoneMode != "disabled" else {
            log("[StreamView] Command-M ignored because microphone is disabled in settings")
            return false
        }
        microphoneShortcutEnabled.toggle()
        if microphoneShortcutEnabled { applyMicrophoneShortcutState() } else { pushToTalkMicEnabled = false; setMicrophoneActive(false) }
        OPNStreamViewPreferences.saveMicrophoneShortcutEnabled(microphoneShortcutEnabled)
        log("[StreamView] Microphone shortcut toggled \(microphoneShortcutEnabled ? "on" : "off")")
        return true
    }

    func setRecordingGameTitle(_ gameTitle: String) { recordingGameTitle = gameTitle.isEmpty ? "Stream" : gameTitle }
    func toggleRecordingShortcut() -> Bool { recordingManager.toggleRecording(forGameTitle: recordingGameTitle, window: window); updateEnhancedVideoRecordingPreference(); updateRecordingControls(); return true }
    func stopRecordingIfNeeded() { recordingManager.stopRecording() }
    func attachToPipeline(_ pipeline: UnsafeMutableRawPointer?) { attachedPipeline = pipeline }
    func detachFromPipeline() { attachedPipeline = nil; setStreamActive(false) }
    func nativeVideoView() -> NSView { videoSurface ?? self }
    func setVideoAspectRatio(_ aspectRatio: CGFloat) { videoAspectRatio = aspectRatio > 0.1 && aspectRatio.isFinite ? aspectRatio : 16.0 / 9.0; needsLayout = true }
    func setVideoUpscalingMode(_ mode: Int, sharpness: Int, denoise: Int, streamWidth: Int, streamHeight: Int) {
        videoUpscalingMode = max(0, min(mode, 4))
        videoUpscalingSharpness = max(0, min(sharpness, 40))
        videoUpscalingDenoise = max(0, min(denoise, 20))
        videoStreamWidth = max(0, streamWidth)
        videoStreamHeight = max(0, streamHeight)
        streamVideoEnhancementHandler?(videoUpscalingMode, videoUpscalingSharpness, videoUpscalingDenoise, videoUpscalingTargetHeight)
        updateEnhancedVideoRecordingPreference()
        applyVideoUpscalingFilters(to: videoSurface)
        needsLayout = true
    }

    func setRemainingPlaytimeHours(_ hours: Double, unlimited: Bool) {
        remainingPlaytimeUnlimited = unlimited
        remainingPlaytimeAvailable = unlimited || (hours.isFinite && hours >= 0)
        remainingPlaytimeBaseSeconds = remainingPlaytimeAvailable && !unlimited ? max(0, hours * 3600) : 0
        remainingPlaytimeStartTime = 0
        updateSidebarPlaytimeStatus()
    }

    func startRemainingPlaytimeCountdown() {
        guard remainingPlaytimeAvailable, !remainingPlaytimeUnlimited else { updateSidebarPlaytimeStatus(); return }
        if remainingPlaytimeStartTime <= 0 { remainingPlaytimeStartTime = CACurrentMediaTime() }
        if playtimeTimer == nil { playtimeTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(playtimeTimerFired(_:)), userInfo: nil, repeats: true) }
        updateSidebarPlaytimeStatus()
    }

    func setSuppressInputWhenWindowInactive(_ suppress: Bool) { suppressInputWhenWindowInactive = suppress }
    func setDirectMouseInputEnabled(_ enabled: Bool) { directMouseInputEnabled = enabled; if !enabled { releaseCursorCapture() } }
    func setStreamInputSuppressed(_ suppressed: Bool) { if streamInputSuppressed != suppressed { streamInputSuppressed = suppressed; if suppressed { resetInputStateAfterSuppression(); releaseCursorCapture() } } }
    func takeFocus() { window?.makeFirstResponder(self); window?.acceptsMouseMovedEvents = true }
    func releasePointerLock() { releaseCursorCapture() }
    func isSidebarHUDVisible() -> Bool { sidebarOpen && sidebarHUD?.isHidden == false }

    func toggleSidebarHUD() {
        sidebarOpen.toggle()
        sidebarHUD?.isHidden = !sidebarOpen
        if sidebarOpen { resetInputStateAfterSuppression(); releaseCursorCapture(); updateSidebarMicStatus(); updateSidebarPlaytimeStatus(); window?.makeFirstResponder(sidebarHUD) } else { takeFocus() }
        needsLayout = true
        onSidebarHUDVisibilityChanged?(sidebarOpen)
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true; NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil); if let window { NotificationCenter.default.addObserver(self, selector: #selector(streamWindowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window) }; NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: nil); NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive(_:)), name: NSApplication.didResignActiveNotification, object: NSApp) }
    override func viewWillMove(toWindow newWindow: NSWindow?) { if newWindow == nil { releaseCursorCapture(); NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window); NotificationCenter.default.removeObserver(self, name: NSApplication.didResignActiveNotification, object: NSApp) }; super.viewWillMove(toWindow: newWindow) }
    override func layout() { super.layout(); layoutVideoAndOverlays() }
    override func keyDown(with event: NSEvent) { handleKeyEvent(event) }
    override func keyUp(with event: NSEvent) { handleKeyEvent(event) }
    override func mouseMoved(with event: NSEvent) { handleMouseEvent(event) }
    override func mouseDown(with event: NSEvent) { handleMouseEvent(event) }
    override func mouseUp(with event: NSEvent) { handleMouseEvent(event) }
    override func rightMouseDown(with event: NSEvent) { handleMouseEvent(event) }
    override func rightMouseUp(with event: NSEvent) { handleMouseEvent(event) }
    override func otherMouseDown(with event: NSEvent) { handleMouseEvent(event) }
    override func otherMouseUp(with event: NSEvent) { handleMouseEvent(event) }
    override func mouseDragged(with event: NSEvent) { handleMouseEvent(event) }
    override func rightMouseDragged(with event: NSEvent) { handleMouseEvent(event) }
    override func otherMouseDragged(with event: NSEvent) { handleMouseEvent(event) }
    override func scrollWheel(with event: NSEvent) { handleMouseEvent(event) }
    override func flagsChanged(with event: NSEvent) { handleFlagsChanged(event) }

    private func streamInputReady() -> Bool { streamActive && (streamInputReadyProvider?() ?? true) }
    private func log(_ message: String) { if !message.isEmpty { OPNLogCapture.appendEvent(message) } }
    private func timestampUs() -> UInt64 { OPNInputProtocolEncoder.timestampUs() }
    private func notifyUserActivity() { onUserActivity?() }
    private func streamWindowAcceptsInput() -> Bool { !streamInputSuppressed && !sidebarOpen && (!suppressInputWhenWindowInactive || (NSApp.isActive && (window?.isKeyWindow == true || window?.isMainWindow == true))) }
    private func clampI16(_ value: Double) -> Int16 { Int16(max(-32768, min(32767, value.rounded()))) }
    private func normalizeAxis(_ value: Double) -> Int16 { Int16(max(-32768, min(32767, (max(-1, min(1, value)) * 32767).rounded()))) }
    private func normalizeTrigger(_ value: Double) -> UInt8 { UInt8(max(0, min(255, (max(0, min(1, value)) * 255).rounded()))) }
    private func radialDeadzone(_ x: Double, _ y: Double) -> (Double, Double) { let magnitude = sqrt(x * x + y * y); if magnitude < Self.gamepadDeadzone { return (0, 0) }; let scaled = min(1, (magnitude - Self.gamepadDeadzone) / (1 - Self.gamepadDeadzone)); return ((x / magnitude) * scaled, (y / magnitude) * scaled) }
    private func modifierFlags(_ event: NSEvent, includeNumericPad: Bool = true) -> UInt16 { var out: UInt16 = 0; let flags = event.modifierFlags; if flags.contains(.shift) { out |= 0x01 }; if flags.contains(.control) { out |= 0x02 }; if flags.contains(.option) { out |= 0x04 }; if flags.contains(.command) { out |= 0x08 }; if flags.contains(.capsLock) { out |= 0x10 }; if includeNumericPad && flags.contains(.numericPad) { out |= 0x20 }; return out }
    private func pushToTalkModifierBit(keyCode: UInt16) -> UInt16 { switch keyCode { case 55: return 0x08; case 56, 60: return 0x01; case 57: return 0x10; case 58, 61: return 0x04; case 59, 62: return 0x02; default: return 0 } }
    private func normalizedPushToTalkModifierMask(keyCode: UInt16, modifierMask: UInt16) -> UInt16 { (modifierMask & 0x1f) | pushToTalkModifierBit(keyCode: keyCode) }

    private func createMicrophoneActiveOverlay() {
        let overlay = NSView(frame: NSRect(x: 0, y: 0, width: 46, height: 46))
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 15
        overlay.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.68).cgColor
        overlay.alphaValue = 0.5
        overlay.isHidden = true
        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Microphone active") {
            let icon = NSImageView(frame: NSRect(x: 11, y: 10, width: 24, height: 26))
            icon.image = image
            icon.contentTintColor = .white
            icon.imageScaling = .scaleProportionallyUpOrDown
            overlay.addSubview(icon)
        }
        microphoneActiveOverlay = overlay
        addSubview(overlay, positioned: .above, relativeTo: videoSurface)
    }

    private func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, _ alignment: NSTextAlignment = .left) -> NSTextField { let field = NSTextField(frame: .zero); field.stringValue = text; field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color; field.alignment = alignment; field.drawsBackground = false; field.isBordered = false; field.isEditable = false; field.isSelectable = false; field.lineBreakMode = .byTruncatingTail; return field }
    private func section(_ frame: NSRect, _ alpha: CGFloat) -> NSView { let view = NSView(frame: frame); view.wantsLayer = true; view.layer?.cornerRadius = 14; view.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: alpha).cgColor; view.layer?.borderWidth = 1; view.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.08).cgColor; return view }
    private func separator(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> NSView { let view = NSView(frame: NSRect(x: x, y: y, width: width, height: 1)); view.wantsLayer = true; view.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.10).cgColor; return view }
    private func addSidebarRow(to panel: NSView, title: String, value: NSTextField, y: CGFloat) { let titleLabel = label(title, 11, .medium, NSColor(calibratedWhite: 0.72, alpha: 1)); titleLabel.frame = NSRect(x: 20, y: y, width: 120, height: 18); value.frame = NSRect(x: 128, y: y, width: panel.frame.width - 148, height: 18); panel.addSubview(titleLabel); panel.addSubview(value) }
    private func sidebarSlider(value: Double, action: Selector, y: CGFloat, panel: NSView) -> NSSlider { let slider = NSSlider(frame: NSRect(x: 20, y: y, width: panel.frame.width - 40, height: 22)); slider.minValue = 0; slider.maxValue = 100; slider.doubleValue = max(0, min(value, 1)) * 100; slider.target = self; slider.action = action; slider.isContinuous = true; panel.addSubview(slider); return slider }

    private func createSidebarHUD(profile: OPNStreamViewPreferenceSnapshot) {
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: 332, height: 660))
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 18
        panel.layer?.backgroundColor = NSColor(calibratedWhite: 0.03, alpha: 0.88).cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        panel.isHidden = true
        let close = NSButton(frame: NSRect(x: panel.frame.width - 48, y: 14, width: 30, height: 30))
        close.title = "x"; close.isBordered = false; close.target = self; close.action = #selector(closeSidebarHUDClicked(_:)); close.contentTintColor = .white; panel.addSubview(close)
        panel.addSubview(section(NSRect(x: 12, y: 56, width: panel.frame.width - 24, height: 76), 0.045))
        panel.addSubview(section(NSRect(x: 12, y: 144, width: panel.frame.width - 24, height: 200), 0.060))
        panel.addSubview(section(NSRect(x: 12, y: 356, width: panel.frame.width - 24, height: 152), 0.045))
        panel.addSubview(section(NSRect(x: 12, y: 520, width: panel.frame.width - 24, height: 120), 0.060))
        sidebarPlaytimeValue = label("--", 12, .semibold, .white, .right); addSidebarRow(to: panel, title: "Playtime", value: sidebarPlaytimeValue!, y: 66)
        panel.addSubview(separator(20, 94, panel.frame.width - 40))
        sidebarMicStatusValue = label("--", 12, .semibold, .white, .right); addSidebarRow(to: panel, title: "Mic", value: sidebarMicStatusValue!, y: 104)
        let upscalingTitle = label("Resolution Upscaling", 12, .medium, NSColor(calibratedWhite: 0.82, alpha: 1)); upscalingTitle.frame = NSRect(x: 20, y: 150, width: 190, height: 18); panel.addSubview(upscalingTitle)
        upscalingModePopup = NSPopUpButton(frame: NSRect(x: 20, y: 176, width: panel.frame.width - 40, height: 30), pullsDown: false)
        let labels = OPNStreamViewPreferences.upscalingModeLabels()
        labels.forEach { upscalingModePopup?.addItem(withTitle: $0) }
        upscalingModePopup?.selectItem(at: max(0, min(Int(profile.upscalingModeIndex), labels.count - 1)))
        upscalingModePopup?.target = self; upscalingModePopup?.action = #selector(upscalingModePopupChanged(_:)); panel.addSubview(upscalingModePopup!)
        panel.addSubview(separator(20, 216, panel.frame.width - 40))
        let sharpnessTitle = label("Local Sharpness", 12, .medium, NSColor(calibratedWhite: 0.82, alpha: 1)); sharpnessTitle.frame = NSRect(x: 20, y: 228, width: 190, height: 18); panel.addSubview(sharpnessTitle)
        upscalingSharpnessSlider = NSSlider(frame: NSRect(x: 20, y: 252, width: panel.frame.width - 40, height: 22)); upscalingSharpnessSlider?.minValue = 0; upscalingSharpnessSlider?.maxValue = 40; upscalingSharpnessSlider?.doubleValue = Double(profile.upscalingSharpness); upscalingSharpnessSlider?.numberOfTickMarks = 41; upscalingSharpnessSlider?.allowsTickMarkValuesOnly = true; upscalingSharpnessSlider?.target = self; upscalingSharpnessSlider?.action = #selector(upscalingSharpnessSliderChanged(_:)); upscalingSharpnessSlider?.isContinuous = true; panel.addSubview(upscalingSharpnessSlider!)
        panel.addSubview(separator(20, 282, panel.frame.width - 40))
        let denoiseTitle = label("Denoise", 12, .medium, NSColor(calibratedWhite: 0.82, alpha: 1)); denoiseTitle.frame = NSRect(x: 20, y: 294, width: 190, height: 18); panel.addSubview(denoiseTitle)
        upscalingDenoiseSlider = NSSlider(frame: NSRect(x: 20, y: 318, width: panel.frame.width - 40, height: 22)); upscalingDenoiseSlider?.minValue = 0; upscalingDenoiseSlider?.maxValue = 20; upscalingDenoiseSlider?.doubleValue = Double(profile.upscalingDenoise); upscalingDenoiseSlider?.numberOfTickMarks = 21; upscalingDenoiseSlider?.allowsTickMarkValuesOnly = true; upscalingDenoiseSlider?.target = self; upscalingDenoiseSlider?.action = #selector(upscalingDenoiseSliderChanged(_:)); upscalingDenoiseSlider?.isContinuous = true; panel.addSubview(upscalingDenoiseSlider!)
        let audioTitle = label("Audio", 14, .semibold, .white); audioTitle.frame = NSRect(x: 20, y: 364, width: 180, height: 20); panel.addSubview(audioTitle)
        let gameTitle = label("Game Volume", 12, .medium, NSColor(calibratedWhite: 0.82, alpha: 1)); gameTitle.frame = NSRect(x: 20, y: 394, width: 180, height: 18); panel.addSubview(gameTitle); gameVolumeSlider = sidebarSlider(value: profile.gameVolume, action: #selector(gameVolumeSliderChanged(_:)), y: 418, panel: panel)
        panel.addSubview(separator(20, 450, panel.frame.width - 40))
        let micTitle = label("Mic Volume", 12, .medium, NSColor(calibratedWhite: 0.82, alpha: 1)); micTitle.frame = NSRect(x: 20, y: 460, width: 180, height: 18); panel.addSubview(micTitle); microphoneVolumeSlider = sidebarSlider(value: profile.microphoneVolume, action: #selector(microphoneVolumeSliderChanged(_:)), y: 484, panel: panel)
        let recordingTitle = label("Recording", 14, .semibold, .white); recordingTitle.frame = NSRect(x: 20, y: 530, width: 180, height: 20); panel.addSubview(recordingTitle)
        let meterTrack = NSView(frame: NSRect(x: 20, y: 560, width: panel.frame.width - 40, height: 14)); meterTrack.wantsLayer = true; meterTrack.layer?.cornerRadius = 7; meterTrack.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        let fill = CALayer(); fill.frame = NSRect(x: 0, y: 0, width: 0, height: 14); fill.cornerRadius = 7; fill.backgroundColor = NSColor(calibratedRed: 0.28, green: 0.88, blue: 0.54, alpha: 1).cgColor; meterTrack.layer?.addSublayer(fill); microphoneMeterTrack = meterTrack; microphoneMeterFill = fill; panel.addSubview(meterTrack)
        sidebarRecordingStatusValue = label("", 12, .medium, NSColor(calibratedWhite: 0.82, alpha: 1)); sidebarRecordingStatusValue?.frame = NSRect(x: 20, y: 558, width: panel.frame.width - 40, height: 18); sidebarRecordingStatusValue?.isHidden = true; panel.addSubview(sidebarRecordingStatusValue!)
        recordingButton = NSButton(title: "Start Recording", target: self, action: #selector(recordingButtonClicked(_:))); recordingButton?.frame = NSRect(x: 20, y: 590, width: panel.frame.width - 40, height: 38); recordingButton?.bezelStyle = .regularSquare; recordingButton?.isBordered = false; recordingButton?.wantsLayer = true; recordingButton?.layer?.cornerRadius = 12; recordingButton?.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.48, blue: 1, alpha: 1).cgColor; panel.addSubview(recordingButton!)
        sidebarHUD = panel
        addSubview(panel, positioned: .above, relativeTo: microphoneActiveOverlay)
        updateSidebarMicStatus(); updateSidebarPlaytimeStatus(); updateRecordingControls()
    }

    private func layoutVideoAndOverlays() { let width = bounds.width; let height = bounds.height; guard width > 0, height > 0 else { return }; let targetAspect = videoAspectRatio > 0.1 ? videoAspectRatio : 16.0 / 9.0; var fittedWidth = width; var fittedHeight = floor(width / targetAspect); if fittedHeight > height { fittedHeight = height; fittedWidth = floor(height * targetAspect) }; let x = floor((width - fittedWidth) / 2); let y = floor((height - fittedHeight) / 2); videoSurface.frame = NSRect(x: x, y: y, width: fittedWidth, height: fittedHeight); applyVideoUpscalingFilters(to: videoSurface); microphoneActiveOverlay.frame = NSRect(x: videoSurface.frame.maxX - 64, y: videoSurface.frame.minY + 18, width: 46, height: 46); if let sidebarHUD { let panelHeight = min(660, max(580, height - 36)); sidebarHUD.frame = NSRect(x: 18, y: floor((height - panelHeight) / 2), width: sidebarHUD.frame.width, height: panelHeight) } }
    private func applyVideoUpscalingFilters(to view: NSView?) { guard let view else { return }; view.wantsLayer = true; if let layer = view.layer { layer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1; layer.filters = nil; if videoUpscalingMode <= 0 { layer.magnificationFilter = .nearest; layer.minificationFilter = .linear; layer.minificationFilterBias = 0; layer.allowsEdgeAntialiasing = false } else { layer.magnificationFilter = .linear; layer.minificationFilter = .linear; layer.minificationFilterBias = 0; layer.allowsEdgeAntialiasing = true } }; view.subviews.forEach { applyVideoUpscalingFilters(to: $0) } }
    private func updateEnhancedVideoRecordingPreference() { let active = recordingManager.isRecording || recordingManager.isStarting; let prefers = active && recordingEnhancedVideoEnabled && videoUpscalingMode > 0; recordingManager.setPrefersEnhancedVideoCapture(prefers); streamEnhancedVideoCaptureHandler?(prefers) }
    private func setMicrophoneLevel(_ level: Double) { microphoneLevel = max(0, min(level, 1)); guard let track = microphoneMeterTrack, let fill = microphoneMeterFill else { return }; CATransaction.begin(); CATransaction.setDisableActions(true); fill.frame = NSRect(x: 0, y: 0, width: track.bounds.width * microphoneLevel, height: track.bounds.height); fill.backgroundColor = (microphoneLevel > 0.72 ? NSColor(calibratedRed: 1, green: 0.48, blue: 0.24, alpha: 1) : microphoneLevel > 0.45 ? NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.28, alpha: 1) : NSColor(calibratedRed: 0.28, green: 0.88, blue: 0.54, alpha: 1)).cgColor; CATransaction.commit() }
    private func updateRecordingControls() { var title = "Start Recording"; var color = NSColor(calibratedRed: 0, green: 0.48, blue: 1, alpha: 1); if recordingManager.isRecording { title = "Stop Recording"; color = NSColor(calibratedRed: 0.92, green: 0.18, blue: 0.22, alpha: 1) } else if recordingManager.isStarting { title = "Starting..."; color = NSColor(calibratedRed: 0.56, green: 0.42, blue: 0.12, alpha: 1) }; recordingButton?.title = title; recordingButton?.layer?.backgroundColor = color.cgColor; let status = recordingManager.statusText ?? ""; let show = !status.isEmpty && status != "Ready"; sidebarRecordingStatusValue?.stringValue = show ? status : ""; sidebarRecordingStatusValue?.isHidden = !show; microphoneMeterTrack?.isHidden = show }
    private func updateSidebarPlaytimeStatus() { guard let label = sidebarPlaytimeValue else { return }; if !remainingPlaytimeAvailable { label.stringValue = "--" } else if remainingPlaytimeUnlimited { label.stringValue = "Unlimited" } else { let elapsed = remainingPlaytimeStartTime > 0 ? CACurrentMediaTime() - remainingPlaytimeStartTime : 0; label.stringValue = formatPlaytime(max(0, remainingPlaytimeBaseSeconds - elapsed)) } }
    private func formatPlaytime(_ seconds: TimeInterval) -> String { let total = max(0, Int(ceil(seconds))); let hours = total / 3600; let minutes = (total % 3600) / 60; let secs = total % 60; return hours > 0 ? "\(hours)h \(String(format: "%02d", minutes))m" : "\(minutes)m \(String(format: "%02d", secs))s" }
    private func updateSidebarMicStatus() { var mode = "Disabled"; if microphoneMode == "push-to-talk" { mode = microphoneActiveOverlay.isHidden ? "PTT muted" : "PTT live" } else if microphoneMode == "voice-activity" { mode = microphoneShortcutEnabled ? "Open mic live" : "Open mic muted" }; sidebarMicStatusValue?.stringValue = mode }
    private func setMicrophoneActive(_ active: Bool) { microphoneActiveOverlay?.isHidden = !active; streamMicrophoneEnabledHandler?(active); if !active { setMicrophoneLevel(0) }; updateSidebarMicStatus() }
    private func applyMicrophoneShortcutState() { if microphoneMode == "disabled" { pushToTalkMicEnabled = false; setMicrophoneActive(false); updateSidebarMicStatus() } else if microphoneMode == "push-to-talk" { updatePushToTalkMic(modifierMask: NSApp.currentEvent.map { modifierFlags($0, includeNumericPad: false) } ?? 0) } else { setMicrophoneActive(microphoneShortcutEnabled) } }

    @objc private func closeSidebarHUDClicked(_ sender: Any) { if sidebarOpen { toggleSidebarHUD() } }
    @objc private func recordingButtonClicked(_ sender: Any) { _ = toggleRecordingShortcut() }
    @objc private func gameVolumeSliderChanged(_ slider: NSSlider) { gameVolume = max(0, min(slider.doubleValue / 100, 1)); streamGameVolumeHandler?(gameVolume); OPNStreamViewPreferences.saveGameVolume(gameVolume) }
    @objc private func microphoneVolumeSliderChanged(_ slider: NSSlider) { microphoneVolumeLevel = max(0, min(slider.doubleValue / 100, 1)); streamMicrophoneVolumeHandler?(microphoneVolumeLevel); OPNStreamViewPreferences.saveMicrophoneVolume(microphoneVolumeLevel) }
    @objc private func upscalingModePopupChanged(_ popup: NSPopUpButton) { let index = max(0, popup.indexOfSelectedItem); let mode = OPNStreamViewPreferences.upscalingModeValue(at: index); OPNStreamViewPreferences.saveUpscalingModeIndex(index); setVideoUpscalingMode(mode, sharpness: videoUpscalingSharpness, denoise: videoUpscalingDenoise, streamWidth: videoStreamWidth, streamHeight: videoStreamHeight) }
    @objc private func upscalingSharpnessSliderChanged(_ slider: NSSlider) { let sharpness = max(0, min(Int(slider.doubleValue.rounded()), 40)); slider.doubleValue = Double(sharpness); OPNStreamViewPreferences.saveUpscalingSharpness(sharpness); setVideoUpscalingMode(videoUpscalingMode, sharpness: sharpness, denoise: videoUpscalingDenoise, streamWidth: videoStreamWidth, streamHeight: videoStreamHeight) }
    @objc private func upscalingDenoiseSliderChanged(_ slider: NSSlider) { let denoise = max(0, min(Int(slider.doubleValue.rounded()), 20)); slider.doubleValue = Double(denoise); OPNStreamViewPreferences.saveUpscalingDenoise(denoise); setVideoUpscalingMode(videoUpscalingMode, sharpness: videoUpscalingSharpness, denoise: denoise, streamWidth: videoStreamWidth, streamHeight: videoStreamHeight) }
    @objc private func playtimeTimerFired(_ timer: Timer) { updateSidebarPlaytimeStatus() }
    @objc private func streamWindowDidResignKey(_ notification: Notification) { releaseCursorCapture() }
    @objc private func applicationDidResignActive(_ notification: Notification) { releaseCursorCapture() }

    private func resetInputStateAfterSuppression() { cancelEscapeHoldTimer(); pendingMouseDx = 0; pendingMouseDy = 0; pushToTalkPrimaryKeyDown = false; if pushToTalkMicEnabled && streamActive && microphoneMode == "push-to-talk" { pushToTalkMicEnabled = false; setMicrophoneActive(false) } else { pushToTalkMicEnabled = false } }
    private func updatePushToTalkMic(modifierMask: UInt16) { guard streamActive, microphoneMode == "push-to-talk" else { return }; let shouldEnable = microphoneShortcutEnabled && pushToTalkPrimaryKeyDown && ((modifierMask & 0x1f) == pushToTalkModifierMask); guard pushToTalkMicEnabled != shouldEnable else { return }; pushToTalkMicEnabled = shouldEnable; setMicrophoneActive(shouldEnable) }
    private func handlePushToTalkKeyEvent(_ event: NSEvent, down: Bool) -> Bool { guard microphoneMode == "push-to-talk", event.keyCode == pushToTalkKeyCode else { return false }; if down && event.isARepeat { return true }; pushToTalkPrimaryKeyDown = down; updatePushToTalkMic(modifierMask: modifierFlags(event, includeNumericPad: false)); return true }
    private func handlePushToTalkFlagsChanged(_ event: NSEvent) -> Bool { guard microphoneMode == "push-to-talk" else { return false }; let changed = pushToTalkModifierBit(keyCode: UInt16(event.keyCode)); guard changed != 0 else { return false }; let current = modifierFlags(event, includeNumericPad: false); let isPrimary = event.keyCode == pushToTalkKeyCode; let isConfigured = (pushToTalkModifierMask & changed) != 0; if !isPrimary && !isConfigured && !pushToTalkMicEnabled { return false }; if isPrimary { pushToTalkPrimaryKeyDown = (current & changed) != 0 }; updatePushToTalkMic(modifierMask: current); return isPrimary || isConfigured || pushToTalkMicEnabled }
    func handleKeyEvent(_ event: NSEvent) { guard streamActive else { return }; guard streamWindowAcceptsInput() else { resetInputStateAfterSuppression(); return }; notifyUserActivity(); let down = event.type == .keyDown; if handlePushToTalkKeyEvent(event, down: down) { return }; guard streamInputReady() else { return }; let characters = event.charactersIgnoringModifiers ?? ""; if down && !event.isARepeat && commandClipboardShortcut(event, characters) { handleCommandClipboardShortcut(event, characters); return }; guard let mapping = Self.keyMap[UInt16(event.keyCode)] else { log("[StreamView] No OPN key mapping for mac keyCode=\(event.keyCode)"); return }; if event.keyCode == 53 { if down && !event.isARepeat { startEscapeHoldTimer() } else if !down { cancelEscapeHoldTimer() } }; streamKeyEventHandler?(mapping.vk, mapping.scancode, modifierFlags(event), down) }
    private func commandClipboardShortcut(_ event: NSEvent, _ characters: String) -> Bool { let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask); return flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) && ["a", "c", "v", "x"].contains(characters.lowercased()) }
    private func handleCommandClipboardShortcut(_ event: NSEvent, _ characters: String) { let shortcut = characters.lowercased(); if shortcut == "v", let clipboard = NSPasteboard.general.string(forType: .string), !clipboard.isEmpty { streamUtf8TextHandler?(clipboard); log("[StreamView] macOS clipboard sent to stream (\(clipboard.count) chars)"); return }; let keycode = UInt16((shortcut.unicodeScalars.first?.value ?? 97) - 97 + 0x41); let scancode = Self.keyMap[UInt16(event.keyCode)]?.scancode ?? 0; streamKeyEventHandler?(0xa2, 0x001d, 0x02, true); streamKeyEventHandler?(keycode, scancode, 0x02, true); streamKeyEventHandler?(keycode, scancode, 0x02, false); streamKeyEventHandler?(0xa2, 0x001d, 0, false) }
    func handleMouseEvent(_ event: NSEvent) { guard streamInputReady() else { return }; guard streamWindowAcceptsInput() else { resetInputStateAfterSuppression(); return }; notifyUserActivity(); switch event.type { case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: if directMouseInputEnabled && cursorCaptured { accumulateMouse(dx: event.deltaX, dy: event.deltaY); flushPendingMouseMove() }; case .leftMouseDown, .rightMouseDown, .otherMouseDown: takeFocus(); if !directMouseInputEnabled { sendMouseButton(event, down: true); return }; if !cursorCaptured { captureCursorIfNeeded(); return }; flushPendingMouseMove(); sendMouseButton(event, down: true); case .leftMouseUp, .rightMouseUp, .otherMouseUp: if cursorCaptured { flushPendingMouseMove() }; sendMouseButton(event, down: false); case .scrollWheel: if cursorCaptured { flushPendingMouseMove() }; let precise = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 120; streamMouseWheelHandler?(clampI16(-precise)); default: break } }
    private func mouseButton(for event: NSEvent) -> UInt8 { switch event.type { case .leftMouseDown, .leftMouseUp, .leftMouseDragged: return Self.mouseLeft; case .rightMouseDown, .rightMouseUp, .rightMouseDragged: return Self.mouseRight; case .otherMouseDown, .otherMouseUp, .otherMouseDragged: if event.buttonNumber == 2 { return Self.mouseMiddle }; if event.buttonNumber == 3 { return Self.mouseBack }; if event.buttonNumber == 4 { return Self.mouseForward }; return UInt8(min(5, max(1, event.buttonNumber + 1))); default: return 0 } }
    private func mouseButtonMask(_ button: UInt8) -> UInt8 { button == 0 || button > 7 ? 0 : UInt8(1 << (button - 1)) }
    private func sendMouseButton(_ event: NSEvent, down: Bool) { let button = mouseButton(for: event); let mask = mouseButtonMask(button); if mask != 0 { if down { mouseButtonsDown |= mask } else { mouseButtonsDown &= ~mask } }; streamMouseButtonHandler?(button, down) }
    private func handleFlagsChanged(_ event: NSEvent) { guard streamActive else { return }; guard streamWindowAcceptsInput() else { resetInputStateAfterSuppression(); return }; guard let mapping = Self.keyMap[UInt16(event.keyCode)], event.keyCode < 128 else { return }; let flags = event.modifierFlags; let down: Bool; switch event.keyCode { case 55: down = flags.contains(.command); case 56, 60: down = flags.contains(.shift); case 57: down = flags.contains(.capsLock); case 58, 61: down = flags.contains(.option); case 59, 62: down = flags.contains(.control); default: return }; if modifierDown[Int(event.keyCode)] == down { return }; modifierDown[Int(event.keyCode)] = down; notifyUserActivity(); if handlePushToTalkFlagsChanged(event) { return }; guard streamInputReady() else { return }; streamKeyEventHandler?(mapping.vk, mapping.scancode, modifierFlags(event), down) }
    private func captureCursorIfNeeded() { guard !cursorCaptured, directMouseInputEnabled else { return }; CGAssociateMouseAndMouseCursorPosition(0); if !cursorHidden { NSCursor.hide(); cursorHidden = true }; cursorCaptured = true; log("[StreamView] Stream pointer locker active") }
    private func releaseCursorCapture() { guard cursorCaptured else { return }; releasePressedMouseButtons(); pendingMouseDx = 0; pendingMouseDy = 0; CGAssociateMouseAndMouseCursorPosition(1); if cursorHidden { NSCursor.unhide(); cursorHidden = false }; cursorCaptured = false; log("[StreamView] Stream pointer locker armed") }
    private func releasePressedMouseButtons() { guard mouseButtonsDown != 0 else { return }; if streamInputReady() { [Self.mouseLeft, Self.mouseMiddle, Self.mouseRight, Self.mouseBack, Self.mouseForward].forEach { button in if mouseButtonsDown & mouseButtonMask(button) != 0 { streamMouseButtonHandler?(button, false) } } }; mouseButtonsDown = 0 }
    private func startEscapeHoldTimer() { guard escapeHoldTimer == nil else { return }; let timer = DispatchSource.makeTimerSource(queue: .main); timer.schedule(deadline: .now() + 3, leeway: .milliseconds(50)); timer.setEventHandler { [weak self] in self?.releaseCursorCapture(); self?.cancelEscapeHoldTimer(); self?.log("[StreamView] ESC held for 3s; pointer capture released") }; escapeHoldTimer = timer; timer.resume() }
    private func cancelEscapeHoldTimer() { escapeHoldTimer?.cancel(); escapeHoldTimer = nil }
    private func accumulateMouse(dx: Double, dy: Double) { pendingMouseDx += dx; pendingMouseDy += dy }
    private func flushPendingMouseMove() { guard streamInputReady(), streamWindowAcceptsInput() else { pendingMouseDx = 0; pendingMouseDy = 0; return }; guard abs(pendingMouseDx) >= 0.5 || abs(pendingMouseDy) >= 0.5 else { return }; let sendDx = pendingMouseDx.rounded(); let sendDy = pendingMouseDy.rounded(); guard sendDx != 0 || sendDy != 0 else { return }; pendingMouseDx -= sendDx; pendingMouseDy -= sendDy; streamMouseMoveHandler?(clampI16(sendDx), clampI16(sendDy)) }

    private func registerForControllerNotifications() { NotificationCenter.default.addObserver(self, selector: #selector(controllerDidConnect(_:)), name: .GCControllerDidConnect, object: nil); NotificationCenter.default.addObserver(self, selector: #selector(controllerDidDisconnect(_:)), name: .GCControllerDidDisconnect, object: nil) }
    @objc private func controllerDidConnect(_ notification: Notification) { log("[StreamView] GameController connected"); startGamepadPolling() }
    @objc private func controllerDidDisconnect(_ notification: Notification) { log("[StreamView] GameController disconnected"); pollGamepads(); if GCController.controllers().isEmpty { stopGamepadPolling() } }
    private func startGamepadPolling() { guard gamepadTimer == nil, streamActive, !GCController.controllers().isEmpty else { return }; let timer = DispatchSource.makeTimerSource(queue: .main); timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1)); timer.setEventHandler { [weak self] in self?.pollGamepads() }; gamepadTimer = timer; timer.resume() }
    private func stopGamepadPolling() { gamepadTimer?.cancel(); gamepadTimer = nil }
    private func handleStartButtonHeld(index: Int, now: CFTimeInterval, down: Bool) { guard index < Self.gamepadMaxControllers else { return }; if !down { startButtonHoldBegan[index] = 0; startButtonHoldConsumed[index] = false; return }; if startButtonHoldBegan[index] <= 0 { startButtonHoldBegan[index] = now; return }; guard !startButtonHoldConsumed[index], now - startButtonHoldBegan[index] >= 3 else { return }; startButtonHoldConsumed[index] = true; onDashboardToggleRequested?(); notifyUserActivity() }
    private func pollGamepads() { guard streamInputReady() else { return }; let accepts = streamWindowAcceptsInput(); let controllers = GCController.controllers(); if controllers.isEmpty { stopGamepadPolling() }; var seen = Array(repeating: false, count: Self.gamepadMaxControllers); for i in 0..<min(Self.gamepadMaxControllers, controllers.count) { guard let pad = controllers[i].extendedGamepad else { continue }; seen[i] = true; gamepadBitmap |= UInt16(1 << i); gamepadBitmap |= UInt16(1 << (i + 8)); let (dlx, dly) = radialDeadzone(Double(pad.leftThumbstick.xAxis.value), Double(pad.leftThumbstick.yAxis.value)); let (drx, dry) = radialDeadzone(Double(pad.rightThumbstick.xAxis.value), Double(pad.rightThumbstick.yAxis.value)); var buttons: UInt16 = 0; if pad.buttonA.value > 0 { buttons |= 0x1000 }; if pad.buttonB.value > 0 { buttons |= 0x2000 }; if pad.buttonX.value > 0 { buttons |= 0x4000 }; if pad.buttonY.value > 0 { buttons |= 0x8000 }; if pad.leftShoulder.value > 0 { buttons |= 0x0100 }; if pad.rightShoulder.value > 0 { buttons |= 0x0200 }; if pad.dpad.up.value > 0 { buttons |= 0x0001 }; if pad.dpad.down.value > 0 { buttons |= 0x0002 }; if pad.dpad.left.value > 0 { buttons |= 0x0004 }; if pad.dpad.right.value > 0 { buttons |= 0x0008 }; if #available(macOS 10.15, *) { if pad.buttonOptions?.value ?? 0 > 0 { buttons |= 0x0020 }; if pad.buttonMenu.value > 0 { buttons |= 0x0010 }; if pad.leftThumbstickButton?.value ?? 0 > 0 { buttons |= 0x0040 }; if pad.rightThumbstickButton?.value ?? 0 > 0 { buttons |= 0x0080 } }; let now = CACurrentMediaTime(); handleStartButtonHeld(index: i, now: now, down: (buttons & 0x0010) != 0); guard accepts else { continue }; let state = OPNStreamGamepadState(controllerId: UInt16(i), buttons: buttons, leftTrigger: normalizeTrigger(Double(pad.leftTrigger.value)), rightTrigger: normalizeTrigger(Double(pad.rightTrigger.value)), leftStickX: normalizeAxis(dlx), leftStickY: normalizeAxis(dly), rightStickX: normalizeAxis(drx), rightStickY: normalizeAxis(dry), connected: true, timestampUs: timestampUs()); let changed = !previousPads[i].known || previousPads[i].state != state; let keepalive = now - lastGamepadSend[i] >= 1; if changed || keepalive { streamGamepadStateHandler?(state.controllerId, state.buttons, state.leftTrigger, state.rightTrigger, state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY, state.connected, gamepadBitmap, state.timestampUs); if changed { notifyUserActivity() }; previousPads[i].known = true; previousPads[i].state = state; lastGamepadSend[i] = now } }; for i in 0..<Self.gamepadMaxControllers { guard !seen[i], previousPads[i].known, previousPads[i].state.connected else { continue }; gamepadBitmap &= ~UInt16(1 << i); gamepadBitmap &= ~UInt16(1 << (i + 8)); let state = OPNStreamGamepadState(controllerId: UInt16(i), connected: false, timestampUs: timestampUs()); streamGamepadStateHandler?(state.controllerId, state.buttons, state.leftTrigger, state.rightTrigger, state.leftStickX, state.leftStickY, state.rightStickX, state.rightStickY, state.connected, gamepadBitmap, state.timestampUs); startButtonHoldBegan[i] = 0; startButtonHoldConsumed[i] = false; previousPads[i].state = state; lastGamepadSend[i] = CACurrentMediaTime() } }
}
