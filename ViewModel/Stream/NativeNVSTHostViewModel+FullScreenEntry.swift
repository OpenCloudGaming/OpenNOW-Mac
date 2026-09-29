//  Entering native full screen when a session becomes ready.
//
//  Only the Session Ready mode "Full Screen" asks for this. Bring to Front stays a bring-to-front,
//  and Off / Notification do nothing: the launch is not taken over, and the stream stays windowed
//  until the user puts it full screen themselves.
//
//  Full screen is also what macOS gates Game Mode on, so this path is what makes Game Mode engage
//  automatically for users who asked for full screen. For everyone else it engages on their own
//  full-screen action, because the bundle declares LSSupportsGameMode and the manual entry is native
//  full screen. See `OPNSessionReadyAction` and `OpenNOW-Info.plist`.
//
//  AppKit is imported for the same reason the sibling files are: the request acts on the window. See
//  `NativeNVSTHostViewModel.swift`.
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
    func enterNativeFullScreenWhenSessionReady() {
        guard OPNSessionReadyAction.isFullScreenRequestedWhenReady else { return }
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
                guard let window = nativeView?.window else { return }
                isSessionReadyFullScreenEntryRequested = true
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
