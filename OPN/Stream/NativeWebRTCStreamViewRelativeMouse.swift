//  Relative pointer motion: turning captured movement into the deltas the seat expects, and the
//  click that takes the pointer in the first place.
//

import AppKit

extension NativeWebRTCStreamView {
    func emitMouseMove(_ event: NSEvent) {
        if !isPointerLocked, mouseInputMode == .absolute {
            emitAbsoluteMousePosition(event)
            return
        }
        switch rawMouseMotion() {
        case .counts(let counts):
            emitScaledMouseMove(deltaX: CGFloat(counts.x), deltaY: CGFloat(counts.y))
        case .pending:
            return
        case .unavailable:
            emitScaledMouseMove(deltaX: event.deltaX, deltaY: event.deltaY)
        }
    }

    /// What the raw HID reader has for this motion event. `.unavailable` whenever raw capture is
    /// off, unusable or has nothing to do with this movement — that is the whole fallback, and it
    /// is why a missing Input Monitoring grant costs acceleration rather than the mouse.
    private func rawMouseMotion() -> OPNRawMouseMotion {
        guard rawMouseInputEnabled, isPointerLocked else { return .unavailable }
        return OPNRawMouseHIDMonitor.shared.takeMotion()
    }

    /// The one scaling path, shared by both sources so Mouse Sensitivity and its carried remainder
    /// behave identically on raw counts and on AppKit deltas.
    func emitScaledMouseMove(deltaX: CGFloat, deltaY: CGFloat) {
        let scaled = Self.scaledMouseDelta(deltaX: deltaX, deltaY: deltaY, sensitivity: mouseSensitivity, remainder: &mouseDeltaRemainder)
        emitMouseMove(deltaX: scaled.x, deltaY: scaled.y)
    }

    /// Applies the sensitivity multiplier to one motion event. Whole counts go out now; the
    /// fractional rest is carried into the next event, so the sum over a movement equals the
    /// scaled input exactly and a 25% setting still registers single-count nudges over time.
    static func scaledMouseDelta(deltaX: CGFloat, deltaY: CGFloat, sensitivity: Double, remainder: inout CGPoint) -> (x: Int16, y: Int16) {
        let scaledX = deltaX * CGFloat(sensitivity) + remainder.x
        let scaledY = deltaY * CGFloat(sensitivity) + remainder.y
        let wholeX = scaledX.rounded(.towardZero)
        let wholeY = scaledY.rounded(.towardZero)
        remainder = CGPoint(x: scaledX - wholeX, y: scaledY - wholeY)
        return (clampedInt16(Int(wholeX)), clampedInt16(Int(wholeY)))
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

    func capturePointerForMouseDown() -> Bool {
        guard remoteInputEnabled, allowsRelativeCapture, mouseInputMode == .relative, !isPointerLocked else { return false }
        setPointerLocked(true)
        return isPointerLocked
    }

    /// Starts feeding relative motion from the raw HID source instead of AppKit's accelerated
    /// deltas. A no-op while the preference is off, and harmless when it fails: no eligible mouse
    /// and no Input Monitoring grant both land the stream back on the AppKit deltas.
    func startRawMouseCaptureIfNeeded() {
        guard rawMouseInputEnabled else { return }
        switch OPNRawMouseHIDMonitor.shared.start() {
        case .started, .alreadyRunning:
            WebRTCMediaTelemetry.capture("webrtc.input.raw_mouse", level: .info, message: "Reading unaccelerated mouse counts.", attributes: ["raw": "true"])
        case .failed(let reason):
            // Not an error: the stream keeps its mouse, it just keeps the accelerated one. The
            // reason is what tells a player why the setting looks like it did nothing.
            WebRTCMediaTelemetry.capture("webrtc.input.raw_mouse.unavailable", level: .warning, message: reason.message, attributes: ["reason": reason.rawValue])
        }
    }

    /// Unconditional, unlike the start: the preference can be switched off while the pointer is
    /// held, and the reader must not outlive the capture that asked for it — it reads every mouse
    /// on the system regardless of which app is frontmost.
    func stopRawMouseCapture() {
        OPNRawMouseHIDMonitor.shared.stop()
    }
}
