//  The deadline on the seat's first cursor notification, and what happens when it passes.
//

import Foundation

extension NvstBifrostFreeTransport {
    /// How long the seat gets to publish its first cursor notification before the composited
    /// pointer is turned off regardless.
    ///
    /// The seat answers the tail of the activation chain — gamepad handling, cursor info — within
    /// one control round trip, and a round trip on this control plane measures ~5 ms (the RTSPS
    /// `GET_PARAMETER` keepalive's rtt). Three seconds is several hundred round trips, so this
    /// cannot pre-empt a seat that was ever going to publish; it is also short enough that the
    /// double pointer reads as a startup artefact rather than the whole session, which is the bug
    /// being fixed. The seat's own client-timeout budget on this channel is 10 s, so the deadline
    /// stays well inside a session that is still healthy.
    static let cursorCaptureWatchdogDelay: Duration = .seconds(3)

    /// Armed by the activation chain, right after capture is switched on.
    func startCursorCaptureWatchdog() {
        guard !isTornDown, cursorCaptureWatchdogTask == nil else { return }
        cursorCaptureWatchdogTask = Task { [weak self] in
            try? await Task.sleep(for: NvstBifrostFreeTransport.cursorCaptureWatchdogDelay)
            guard !Task.isCancelled else { return }
            await self?.disableCursorCaptureAfterSilentSeat()
        }
    }

    func cancelCursorCaptureWatchdog() {
        cursorCaptureWatchdogTask?.cancel()
        cursorCaptureWatchdogTask = nil
    }

    /// The seat never published a cursor notification, so it is compositing a pointer that nothing
    /// will ever tell us to stop drawing over. Turn its pointer off and let the client's own be the
    /// only one, which is what the first notification would have done.
    func disableCursorCaptureAfterSilentSeat() {
        // Fired from the watchdog's own body, so cancelling here only tidies the reference away —
        // the deadline has already passed and nothing after this point suspends.
        cancelCursorCaptureWatchdog()
        guard !isTornDown, !didDisableCursorCapture else { return }
        didDisableCursorCapture = true
        // The bundle is present whenever this is armed — the activation chain sent through it — and
        // can only go away with a teardown that cancels the watchdog first. Recording the decision
        // regardless keeps the log honest about a race that would otherwise vanish silently.
        let sent = bundle?.sendControl(NvstInputActivation.mouseCursorCapture(isEnabled: false)) ?? false
        // The seat has said nothing, so `remoteCursorVisible` stays nil forever and the visibility
        // handler will never fire. Without this the client keeps hiding its own pointer over a
        // picture that no longer has one composited into it: no pointer at all, for the rest of a
        // session whose whole interaction is aiming.
        notifySeatCompositesCursor(false)
        let seconds = NvstBifrostFreeTransport.cursorCaptureWatchdogDelay.components.seconds
        logger?("NVST no seat cursor notification in \(seconds)s; server-composited cursor disabled sent=\(sent)")
    }
}
