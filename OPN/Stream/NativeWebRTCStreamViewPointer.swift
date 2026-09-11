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
        startRawMouseCaptureIfNeeded()
        installPointerLockNotifications()
        applyLocalCursorPolicy()
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
        stopRawMouseCapture()
        if let restoreLocation = pointerLockRestoreLocation {
            moveCursor(toScreenPoint: restoreLocation)
        }
        pointerLockRestoreLocation = nil
        if pointerLockCursorHidden {
            NSCursor.unhide()
            pointerLockCursorHidden = false
        }
        // Every route that ends a capture comes through here — the toggle, a click outside, focus
        // loss, the HUD, an in-place reconnect dropping remote input, teardown — so this is the one
        // place the manual override has to be forgotten. Nothing releases the pointer without it.
        manualPointerCaptureOverride = false
        // The override swallowed every seat mode change while it was held, so the mode can be stale
        // in the direction that has no lock behind it: `.relative` with the pointer released is
        // where `routeInputEvent` drops every mouse event and the mouse is simply dead until the
        // seat next changes its mind. Only that direction is replayed — following the seat back
        // into mouselook here would retake the pointer the player just asked to get back.
        if remoteCursorWantsPointer == true, mouseInputMode != .absolute { mouseInputMode = .absolute }
        applyLocalCursorPolicy()
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
        lastEmittedAbsoluteMouseEvent = absoluteEvent
        onAbsoluteMouseMove?(absoluteEvent)
        return true
    }

    func notifyPointerLockChanged(_ locked: Bool) {
        onPointerLockChanged?(locked)
        onMouseInputModeChanged?(effectiveMouseMode)
        WebRTCMediaTelemetry.capture("webrtc.input.pointer_lock", level: .info, message: locked ? "Pointer lock enabled." : "Pointer lock disabled.", attributes: ["locked": String(locked)])
    }

    /// The player's own capture toggle: Cmd+P and the HUD tile. Distinct from `setPointerLocked`,
    /// which the seat's cursor notifications drive as well — a capture asked for by hand sticks
    /// until it is released by hand, and the next `setRemoteCursorVisible` must not undo it.
    public func setManualPointerCapture(_ captured: Bool) {
        setPointerLocked(captured)
        // Only a capture that actually took hold sticks. `enablePointerLock` gives up when there is
        // no window or macOS refuses the association, and an override with no lock behind it would
        // silence seat cursor notifications for the rest of the session.
        manualPointerCaptureOverride = captured && isPointerLocked
    }

    /// What the seat says about the game's own cursor, applied to this client's input mode.
    ///
    /// A hidden remote cursor means the game is in mouselook, where absolute coordinates address
    /// nothing, so the client follows it into relative mode whatever Direct Mouse Input says; that
    /// preference gates whether an ordinary click may take the pointer, which is a different
    /// question. A capture the player forced by hand outranks both.
    public func setRemoteCursorVisible(_ isVisible: Bool) {
        remoteCursorWantsPointer = isVisible
        guard !manualPointerCaptureOverride else { return }
        let mode: NativeStreamMouseInputMode = isVisible ? .absolute : .relative
        mouseInputMode = mode
        if mode == .relative {
            if remoteInputEnabled { setPointerLocked(true) }
        } else if isPointerLocked {
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
