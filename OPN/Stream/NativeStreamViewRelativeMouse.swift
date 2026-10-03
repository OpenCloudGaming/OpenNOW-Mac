//  Relative pointer motion: turning captured movement into the deltas the seat expects, and the
//  click that takes the pointer in the first place.
//

import AppKit

extension NativeStreamView {
    func emitMouseMove(_ event: NSEvent) {
        if !isPointerLocked, mouseInputMode == .absolute {
            emitAbsoluteMousePosition(event)
            return
        }
        switch rawMouseMotion() {
        case .counts(let counts):
            guard rawMouseMatchesMacPointerSpeed else {
                emitScaledMouseMove(deltaX: CGFloat(counts.x), deltaY: CGFloat(counts.y))
                return
            }
            macPointerScale.recordCounts(x: counts.x, y: counts.y)
            macPointerScale.recordPointer(deltaX: event.deltaX, deltaY: event.deltaY)
            emitMacSizedMove(counts, pointerDeltaX: event.deltaX, pointerDeltaY: event.deltaY)
        case .pending:
            guard rawMouseMatchesMacPointerSpeed else { return }
            let calibrated = macPointerScale.pointsPerCount != nil
            macPointerScale.recordPointer(deltaX: event.deltaX, deltaY: event.deltaY)
            // Until the scale is known the AppKit deltas carry the motion and pushed counts are only measured.
            if !calibrated { emitScaledMouseMove(deltaX: event.deltaX, deltaY: event.deltaY) }
        case .unavailable:
            emitScaledMouseMove(deltaX: event.deltaX, deltaY: event.deltaY)
        }
    }

    /// Raw counts pushed by the HID reader as each report lands, instead of waiting for the next
    /// AppKit motion event.
    private func emitPushedRawMotion(_ delta: OPNRawMouseDelta) {
        guard rawMouseInputEnabled, isPointerLocked else { return }
        guard rawMouseMatchesMacPointerSpeed else {
            emitScaledMouseMove(deltaX: CGFloat(delta.x), deltaY: CGFloat(delta.y))
            return
        }
        let pointsPerCount = macPointerScale.pointsPerCount
        macPointerScale.recordCounts(x: delta.x, y: delta.y)
        guard let pointsPerCount else { return }
        emitScaledMouseMove(deltaX: CGFloat(Double(delta.x) * pointsPerCount), deltaY: CGFloat(Double(delta.y) * pointsPerCount))
    }

    private func emitMacSizedMove(_ counts: OPNRawMouseDelta, pointerDeltaX: CGFloat, pointerDeltaY: CGFloat) {
        guard let pointsPerCount = macPointerScale.pointsPerCount else {
            emitScaledMouseMove(deltaX: pointerDeltaX, deltaY: pointerDeltaY)
            return
        }
        emitScaledMouseMove(deltaX: CGFloat(Double(counts.x) * pointsPerCount), deltaY: CGFloat(Double(counts.y) * pointsPerCount))
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
        guard remoteInputEnabled, allowsRelativeCapture, mouseInputMode == .relative,
              !isPointerLocked, !isPictureInPictureMode else { return false }
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
            OPNRawMouseHIDMonitor.shared.setPushHandler { [weak self] delta in
                self?.emitPushedRawMotion(delta)
            }
            OPNStreamTelemetry.capture("webrtc.input.raw_mouse", level: .info, message: "Reading unaccelerated mouse counts.", attributes: ["raw": "true"])
        case .failed(let reason):
            // Not an error: the stream keeps its mouse, it just keeps the accelerated one. The
            // reason is what tells a player why the setting looks like it did nothing.
            OPNStreamTelemetry.capture("webrtc.input.raw_mouse.unavailable", level: .warning, message: reason.message, attributes: ["reason": reason.rawValue])
        }
    }

    /// Unconditional, unlike the start: the preference can be switched off while the pointer is
    /// held, and the reader must not outlive the capture that asked for it — it reads every mouse
    /// on the system regardless of which app is frontmost.
    func stopRawMouseCapture() {
        OPNRawMouseHIDMonitor.shared.stop()
    }
}
