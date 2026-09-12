import AppKit
import Testing
@testable import OpenNOW

@MainActor private func makeCursorCaptureWindow() -> (NSWindow, NativeWebRTCStreamView) {
    let location = NSEvent.mouseLocation
    let window = NSWindow(
        contentRect: NSRect(x: location.x - 640, y: location.y - 360, width: 1280, height: 720),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    let view = NativeWebRTCStreamView(frame: window.contentView?.bounds ?? .zero)
    view.mouseInputMode = .absolute
    view.confinesCursorToWindowInAbsoluteMode = true
    view.cursorAssociationHandler = { _ in .success }
    view.hidesCursorWhilePointerLocked = false
    window.contentView = view
    return (window, view)
}

@Test @MainActor func visibleCursorUpdatesPreserveAbsoluteCaptureAndHeldButtons() throws {
    let (window, view) = makeCursorCaptureWindow()
    defer {
        view.setPointerLocked(false)
        window.contentView = nil
    }
    view.captureAbsoluteCursorIfNeeded()
    try #require(view.isAbsoluteCursorConfined)
    view.emitMouseButton(.left, isPressed: true)
    var releases = 0
    view.onInputEvent = { event in
        if case .mouse(.button(_, .left, false, _)) = event { releases += 1 }
    }

    for _ in 0..<3 { view.setRemoteCursorVisible(true) }

    #expect(view.isAbsoluteCursorConfined)
    #expect(!view.isPointerLocked)
    #expect(view.pressedMouseButtons.contains(.left))
    #expect(releases == 0)

    view.remoteInputEnabled = false

    #expect(!view.isCursorCaptured)
    #expect(view.pressedMouseButtons.isEmpty)
    #expect(releases == 1)
}

@Test @MainActor func visibleCursorUpdatesDoNotCancelUnconfinedMouseDrags() {
    let view = NativeWebRTCStreamView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.mouseInputMode = .absolute
    view.directMouseInputEnabled = false
    view.emitMouseButton(.left, isPressed: true)
    defer { view.releasePressedInputs() }

    view.setRemoteCursorVisible(true)

    #expect(view.pressedMouseButtons.contains(.left))
    #expect(!view.isCursorCaptured)
}

@Test @MainActor func remoteCursorModeTransitionsStillReleasePreviousCapture() throws {
    let (window, view) = makeCursorCaptureWindow()
    defer {
        view.setPointerLocked(false)
        window.contentView = nil
    }
    view.captureAbsoluteCursorIfNeeded()
    try #require(view.isAbsoluteCursorConfined)
    view.emitMouseButton(.left, isPressed: true)

    view.setRemoteCursorVisible(false)

    #expect(view.mouseInputMode == .relative)
    #expect(view.isPointerLocked)
    #expect(!view.isAbsoluteCursorConfined)
    #expect(view.pressedMouseButtons.isEmpty)
    view.emitMouseButton(.right, isPressed: true)

    view.setRemoteCursorVisible(true)

    #expect(view.mouseInputMode == .absolute)
    #expect(!view.isCursorCaptured)
    #expect(view.pressedMouseButtons.isEmpty)
}

@Test @MainActor func focusLossStillReleasesAbsoluteCaptureAfterCursorUpdates() throws {
    let (window, view) = makeCursorCaptureWindow()
    defer {
        view.setPointerLocked(false)
        window.contentView = nil
    }
    view.captureAbsoluteCursorIfNeeded()
    view.setRemoteCursorVisible(true)
    try #require(view.isAbsoluteCursorConfined)

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

    #expect(!view.isCursorCaptured)
}

@Test @MainActor func focusNotificationsDoNotCaptureWhileRemoteInputIsDisabled() {
    let (window, view) = makeCursorCaptureWindow()
    defer {
        view.setPointerLocked(false)
        window.contentView = nil
    }
    view.remoteInputEnabled = false
    view.locksPointerWhenRelativeModeSelected = true
    view.mouseInputMode = .relative

    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

    #expect(!view.isCursorCaptured)
}

@Test @MainActor func focusNotificationsDoNotCaptureForANonKeyWindow() throws {
    let (window, view) = makeCursorCaptureWindow()
    defer {
        view.setPointerLocked(false)
        window.contentView = nil
    }
    try #require(!window.isKeyWindow)
    view.locksPointerWhenRelativeModeSelected = true
    view.mouseInputMode = .relative

    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)

    #expect(!view.isCursorCaptured)
}

@Test @MainActor func focusNotificationsLeaveTheOnScreenKeyboardInControl() {
    let (window, view) = makeCursorCaptureWindow()
    defer {
        view.setPointerLocked(false)
        window.contentView = nil
    }
    view.localOverlayCapturesInput = true
    view.locksPointerWhenRelativeModeSelected = true
    view.mouseInputMode = .relative

    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApplication.shared)
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

    #expect(!view.isCursorCaptured)
}
