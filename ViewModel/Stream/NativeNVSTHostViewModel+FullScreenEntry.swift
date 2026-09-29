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
            await self?.performNativeFullScreenEntry()
        }
    }

    private func performNativeFullScreenEntry() async {
        let startedAt = Date()
        var attemptCount = 0
        var lastDeferral: OPNStreamFullScreenEntry.DeferralReason?
        for attempt in 1...Self.sessionReadyFullScreenAttemptLimit {
            try? await Task.sleep(for: Self.sessionReadyFullScreenRetryDelay)
            guard !Task.isCancelled else { return }
            attemptCount = attempt
            switch nativeFullScreenEntryAttempt() {
            case .stop:
                return
            case .alreadyFullScreen:
                return
            case .enter:
                let activation = OPNStreamFullScreenEntry.activation(
                    bringsAppToFrontWhenReady: OPNSessionReadyAction.mode.bringsAppToFrontWhenReady,
                    isAppActive: NSApp.isActive
                )
                guard activation == .activateNow else {
                    await waitForAppActivation()
                    guard !Task.isCancelled else { return }
                    await performNativeFullScreenEntry()
                    return
                }
                guard let window = nativeView?.window else { return }
                isSessionReadyFullScreenEntryRequested = true
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.toggleFullScreen(nil)
                return
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
    }

    /// Waits for the next activation notification. The subscription is registered in the same
    /// main-actor turn as the caller's own `isActive` read, so an activation cannot land between the
    /// two and be missed; the loop re-checks after each notification because the task can also end
    /// by cancellation, in which case the sequence finishes with the app still in the background.
    private func waitForAppActivation() async {
        let notifications = NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification, object: nil)
        while !Task.isCancelled, !NSApp.isActive {
            for await _ in notifications { break }
        }
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
