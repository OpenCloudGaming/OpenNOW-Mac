//  Pointer lock and absolute-cursor confinement: taking the cursor for a stream and giving it back.
//

import AppKit
import QuartzCore

extension NativeWebRTCStreamView {
    func enablePointerLock() {
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

    func disablePointerLock() {
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

    func captureAbsoluteCursorIfNeeded() {
        guard remoteInputEnabled, directMouseInputEnabled, confinesCursorToWindowInAbsoluteMode,
              mouseInputMode == .absolute, !isPointerLocked, !isAbsoluteCursorConfined, window != nil else { return }
        guard Self.confinedCursorPoint(NSEvent.mouseLocation, to: window?.frame ?? .zero) != nil else { return }
        isAbsoluteCursorConfined = true
        window?.acceptsMouseMovedEvents = true
        installPointerLockMonitor()
        installAbsoluteCursorGlobalMonitor()
        installPointerLockNotifications()
        WebRTCMediaTelemetry.capture("webrtc.input.absolute_cursor_confined", level: .info, message: "Absolute stream cursor confined to the window.", attributes: ["confined": "true"])
    }

    func disableAbsoluteCursorConfinement() {
        guard isAbsoluteCursorConfined else { return }
        isAbsoluteCursorConfined = false
        removeAbsoluteCursorGlobalMonitor()
        if !isPointerLocked { removePointerLockMonitor() }
        WebRTCMediaTelemetry.capture("webrtc.input.absolute_cursor_confined", level: .info, message: "Absolute stream cursor confinement released.", attributes: ["confined": "false"])
    }

    func retryCursorAssociation(generation: UInt, delay: TimeInterval = 0.01) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            guard cursorAssociationGeneration == generation, !isCursorCaptured else { return }
            if cursorAssociationHandler(true) != .success {
                retryCursorAssociation(generation: generation, delay: min(delay * 2, 1))
            }
        }
    }

    @discardableResult
    func constrainAssociatedAbsoluteCursor() -> Bool {
        let cursor = NSEvent.mouseLocation
        guard isAbsoluteCursorConfined, let window, let confined = Self.confinedCursorPoint(cursor, to: window.frame), confined != cursor else { return false }
        moveCursor(toScreenPoint: confined)
        let windowPoint = window.convertPoint(fromScreen: confined)
        let viewPoint = convert(windowPoint, from: nil)
        guard let absoluteEvent = absoluteMouseEvent(at: viewPoint, timestamp: Self.timestamp()) else { return true }
        onAbsoluteMouseMove?(absoluteEvent)
        return true
    }

    func notifyPointerLockChanged(_ locked: Bool) {
        onPointerLockChanged?(locked)
        WebRTCMediaTelemetry.capture("webrtc.input.pointer_lock", level: .info, message: locked ? "Pointer lock enabled." : "Pointer lock disabled.", attributes: ["locked": String(locked)])
    }

    public func setRemoteCursorVisible(_ isVisible: Bool) {
        let mode: NativeStreamMouseInputMode = isVisible || !directMouseInputEnabled ? .absolute : .relative
        mouseInputMode = mode
        if mode == .relative {
            if remoteInputEnabled { setPointerLocked(true) }
        } else {
            setPointerLocked(false)
        }
    }

    func updatePointerLockCursorVisibility() {
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
}
