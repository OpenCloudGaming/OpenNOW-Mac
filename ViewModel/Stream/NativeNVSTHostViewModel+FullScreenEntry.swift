//  Entering native full screen when a session becomes ready.
//
//  macOS only offers Game Mode to a game that is already in native full screen and frontmost, so a
//  session that lands while the user is in the app enters full screen and activates. A launch that
//  became ready in the background is never taken over: Off and Notification leave the window
//  windowed for the user, and only Bring to Front / Full Screen fetch it. Nothing here re-enters
//  full screen on a later activation. See `OPNSessionReadyAction`.
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
    /// The entry is issued once, for this connect. A background launch that the Session Ready mode
    /// leaves alone is not resumed later: the stream stays windowed until the user takes full
    /// screen, so regaining focus never changes a window's mode underneath them.
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
            case .stop, .alreadyFullScreen:
                return
            case .enter:
                guard OPNStreamFullScreenEntry.shouldEnterNow(
                    bringsAppToFrontWhenReady: OPNSessionReadyAction.mode.bringsAppToFrontWhenReady,
                    isAppActive: NSApp.isActive
                ) else { return }
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
