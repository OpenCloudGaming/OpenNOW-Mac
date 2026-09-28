//  Entering native full screen when a session becomes ready.
//
//  macOS only offers Game Mode to a game that is already in native full screen and frontmost, so
//  the stream enters full screen on every connect regardless of the Session Ready preference: a
//  setting would leave Game Mode off for every default install. The preference keeps its remaining
//  job - bringing a backgrounded app forward - in `OPNSessionReadyAction`.
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
    /// settled the first frame, so the transition retries on the geometry gate's ceiling. Activation
    /// is part of the request: the presenter orders a launched window front **without** activating
    /// when OpenNOW is not frontmost, and a full-screen window that is not frontmost cannot reach
    /// Game Mode.
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
