//  Entering native full screen when a session becomes ready.
//
//  macOS only offers Game Mode to a game that is already in native full screen and frontmost, so a
//  session that lands while the user is in the app enters full screen and activates. The Session
//  Ready preference keeps its say over a launch that became ready in the background: Off and
//  Notification wait for the user rather than pulling them back, Bring to Front and Full Screen
//  activate as they always did. See `OPNSessionReadyAction`.
//
//  AppKit is imported for the same reason the sibling files are: the request acts on the window and
//  on the application's activation state. See `NativeNVSTHostViewModel.swift`.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import Foundation

extension NativeNVSTHostViewModel {
    /// The geometry gate's own ceiling: 200 attempts at 50 ms, about ten seconds, which is long
    /// enough for a nested run loop or a live resize to end before the transition is given up on.
    static let sessionReadyFullScreenRetryDelay = Duration.milliseconds(50)
    static let sessionReadyFullScreenAttemptLimit = 200

    /// The window is only reachable once the view is in a hierarchy and the aspect coordinator has
    /// settled the first frame, so the transition retries on the geometry gate's ceiling.
    ///
    /// Activation follows the Session Ready preference rather than overriding it. Off and
    /// Notification mean a launch that became ready while the user was elsewhere must not pull them
    /// back, so the transition waits for the next activation and lands then - which is also when
    /// Game Mode can engage. Bring to Front and Full Screen activate as they always have.
    func enterNativeFullScreenWhenSessionReady() {
        sessionReadyFullScreenTask?.cancel()
        sessionReadyFullScreenTask = Task { @MainActor [weak self] in
            await self?.driveNativeFullScreenEntry()
        }
    }

    /// A deferred activation resumes the attempt loop rather than nesting a second driver, so a user
    /// who comes and goes repeatedly grows no stack and no second budget.
    private func driveNativeFullScreenEntry() async {
        while !Task.isCancelled {
            guard await runNativeFullScreenEntryAttempts() else { return }
            guard await waitForAppActivation() else { return }
        }
    }

    /// Spends one geometry budget. `true` means the entry is waiting on activation and the caller
    /// should resume it; `false` means it was issued, was already done, or the session went away.
    private func runNativeFullScreenEntryAttempts() async -> Bool {
        let startedAt = Date()
        var attemptCount = 0
        var lastDeferral: OPNStreamFullScreenEntry.DeferralReason?
        for attempt in 1...Self.sessionReadyFullScreenAttemptLimit {
            try? await Task.sleep(for: Self.sessionReadyFullScreenRetryDelay)
            guard !Task.isCancelled else { return false }
            attemptCount = attempt
            switch nativeFullScreenEntryAttempt() {
            case .stop, .alreadyFullScreen:
                return false
            case .enter:
                let activation = OPNStreamFullScreenEntry.activation(
                    bringsAppToFrontWhenReady: OPNSessionReadyAction.mode.bringsAppToFrontWhenReady,
                    isAppActive: NSApp.isActive
                )
                guard activation == .activateNow else { return true }
                guard let window = nativeView?.window else { return false }
                isSessionReadyFullScreenEntryRequested = true
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.toggleFullScreen(nil)
                return false
            case .wait(let reason):
                lastDeferral = reason
            }
        }
        OPNStreamFullScreenTelemetry.captureFailure(
            applicationID: configuration.applicationID,
            reason: OPNStreamFullScreenEntry.FailureReason(deferral: lastDeferral),
            attemptCount: attemptCount,
            elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
        return false
    }

    /// Waits for the next activation notification. The subscription is registered in the same
    /// main-actor turn as the caller's own `isActive` read, so an activation cannot land between the
    /// two and be missed; the loop re-checks after each notification because the sequence can also
    /// finish by cancellation, with the app still in the background. `false` means cancelled.
    private func waitForAppActivation() async -> Bool {
        let notifications = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification, object: nil)
        while !Task.isCancelled, !NSApp.isActive {
            for await _ in notifications { break }
        }
        return !Task.isCancelled
    }

    private func nativeFullScreenEntryAttempt() -> OPNStreamFullScreenEntry.Attempt {
        let window = nativeView?.window
        return OPNStreamFullScreenEntry.attempt(
            isLive: isConnected && !isEnding && !didEnd,
            hasWindow: window != nil,
            isFullScreenTransitioning: isFullScreenTransitioning,
            windowIsFullScreen: window?.styleMask.contains(.fullScreen) ?? false,
            geometryDeferred: window.map { StreamWindowGeometryGate.shouldDeferGeometryMutation(for: $0) } ?? false
        )
    }
}
