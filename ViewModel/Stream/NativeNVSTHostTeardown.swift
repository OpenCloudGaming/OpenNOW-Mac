//  Ending a native NVST session. Teardown order is load-bearing — see the note in
//  NativeNVSTHostViewModel.swift — and `didEnd` is a once-guard that must not be reset while a
//  session can still end.
//
//  AppKit is imported for the same reason NativeNVSTHostViewModel.swift does: the stream surface is
//  an AppKit view and tearing a session down acts on it directly.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import AVFoundation
import Combine
import Foundation
import GameController

extension NativeNVSTHostViewModel {
    func stopStream() {
        StreamSessionLifecycle.deactivate(configuration.id)
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        startTask?.cancel()
        startTask = nil
        endEventTask?.cancel()
        endEventTask = nil
        nativeStatsTask?.cancel()
        nativeStatsTask = nil
        resetSessionObservations()
        sessionLimit = nil
        networkGovernor = nil
        networkPathTask?.cancel()
        networkPathTask = nil
        networkPathAvailable = true
        cancelNativeShortcutTasks()
        sessionReadyFullScreenTask?.cancel()
        sessionReadyFullScreenTask = nil
        removeNativeFullScreenObservers()
        endStreamingPerformanceMode()
        nativeView?.remoteInputEnabled = false
        let inputDispatcher = self.inputDispatcher
        self.inputDispatcher = nil
        resetSessionUIState()
        nativeView?.stopHaptics()
        // Visibility is dropped by the transport's shutdown hook once the native session
        // is gone; hiding the Metal layer before `path.stop` wedges Geronimo's render loop.
        guard !didEnd else {
            Task { @MainActor in _ = await stopRemoteCoOpSession() }
            inputDispatcher?.cancel()
            return
        }
        didEnd = true
        nativeView?.onInputEvent = nil
        nativeView?.onAbsoluteMouseMove = nil
        nativeView?.onGamepadTopologyChanged = nil
        nativeView?.onPointerLockChanged = nil
        nativeView?.onCommand = nil
        nativeView?.shouldHandleCommand = nil
        nativeView?.onScreenKeyboardCapture = nil
        reportUnreportedEnd(path: path, inputDispatcher: inputDispatcher)
    }

    /// Ends the session locally, then tells the app it ended. Reaching this means the surface went
    /// away before anything reported the end, so nothing else would free the one-stream slot it
    /// holds; the report comes last, because the teardown is what still needs the credentials.
    private func reportUnreportedEnd(path: NativeNVSTStreamingPath?, inputDispatcher: NativeNVSTInputDispatcher?) {
        let report = StreamReport(
            title: configuration.title,
            success: true,
            reason: .userRequested,
            message: "",
            durationSeconds: 0,
            metadata: ["applicationID": configuration.applicationID, "transport": "nvst"]
        )
        guard let path else {
            Task { @MainActor in
                _ = await stopRemoteCoOpSession()
                inputDispatcher?.cancel()
                onEnd(true, report.message, report)
            }
            return
        }
        Task {
            // Ends the guests' peers and hands back the neutral pad states they were holding.
            // Delivered through the dispatcher before it is drained, because after `finish()`
            // there is nothing left to carry them and whatever a guest had pressed would stay
            // pressed in the game for as long as the seat keeps the session.
            let neutralEvents = await stopRemoteCoOpSession()
            for event in neutralEvents { inputDispatcher?.enqueue(event) }
            await inputDispatcher?.finish()
            try? await path.setMicrophoneEnabled(false)
            _ = try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed.")
            onEnd(true, report.message, report)
        }
    }

    /// Forgets what the ended session taught us about itself; the next session starts blank.
    private func resetSessionObservations() {
        stats.reset()
        bitrateStarvation.reset()
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
    }

    private func resetSessionUIState() {
        isConnected = false
        pointerLocked = false
        streamWindowIsFullScreen = false
        // The window is thrown away with the session, so this only stops a stale mode from
        // disabling the full-screen tile while the teardown still runs.
        isPictureInPicture = false
        nativeView?.isPictureInPictureMode = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        microphoneAvailable = false
        microphoneEnabled = false
        microphoneDesiredEnabled = false
        microphoneMode = "disabled"
        isMicrophoneSectionNegotiated = false
        microphonePendingStates.removeAll()
        antiAFKMouseMovementEnabled = false
        batteryAlertTracker.reset()
    }

    func finish(reason: StreamEndReason, message: String) async -> Bool {
        guard !isEnding else { return false }
        // The Geronimo-owned Metal layer stays visible until the native session is torn
        // down. Hiding it here stalls the render loop's in-flight presents, and Geronimo's
        // shutdown then deadlocks the main thread waiting on that render loop. Visibility
        // is cleared in `finishOnce`, after `path.stop` has returned.
        let inputDispatcher = await MainActor.run {
            nativeView?.remoteInputEnabled = false
            let dispatcher = self.inputDispatcher
            self.inputDispatcher = nil
            isEnding = true
            return dispatcher
        }
        let remoteCoOpNeutralEvents = await stopRemoteCoOpSession()
        for event in remoteCoOpNeutralEvents { inputDispatcher?.enqueue(event) }
        await inputDispatcher?.finish()
        guard let path else {
            await MainActor.run {
                isEnding = false
                showStreamControls()
            }
            return false
        }
        do {
            do {
                try await path.setMicrophoneEnabled(false)
            } catch {
                OPNStreamTelemetry.capture(
                    "nvst.microphone.shutdown.failed",
                    level: .warning,
                    message: Self.message(for: error),
                    attributes: ["applicationID": configuration.applicationID, "reason": reason.rawValue]
                )
            }
            let report = try await path.stop(reason: reason, message: message)
            await MainActor.run { finishOnce(report: report) }
            return true
        } catch {
            let failureMessage = Self.message(for: error)
            if reason == .paused {
                await MainActor.run {
                    isEnding = false
                    self.inputDispatcher = NativeNVSTInputDispatcher { input in
                        switch input {
                        case .event(let event):
                            try? await path.send(event)
                        case .absoluteMove(let event):
                            try? await path.sendAbsoluteMouseMove(event)
                        }
                    }
                    streamControlsVisible = true
                    OPNStreamTelemetry.capture("nvst.ui.pause.failed", level: .error, message: failureMessage, attributes: ["applicationID": configuration.applicationID])
                }
                return false
            }
            let report = StreamReport(title: configuration.title, success: false, reason: .failed, message: failureMessage, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID, "transport": "nvst"])
            await MainActor.run { finishOnce(report: report) }
            return false
        }
    }

    func finishOnce(report: StreamReport) {
        guard !didEnd else { return }
        recordDecodeMeasurementWhenLongEnough()
        nativeView?.remoteInputEnabled = false
        // Idempotent, and the backstop for the paths that reach `finishOnce` without going through
        // `finish` - a transport-side termination, for instance.
        Task { @MainActor in _ = await stopRemoteCoOpSession() }
        inputDispatcher?.cancel()
        inputDispatcher = nil
        didEnd = true
        isConnected = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        onScreenKeyboardVisible = false
        restorePointerLockOnKeyboardHide = false
        nativeView?.localOverlayCapturesInput = false
        nativeStatsVisible = false
        microphoneAvailable = false
        microphoneEnabled = false
        microphoneDesiredEnabled = false
        microphoneMode = "disabled"
        isMicrophoneSectionNegotiated = false
        microphonePendingStates.removeAll()
        antiAFKMouseMovementEnabled = false
        nativeStatsTask?.cancel()
        nativeStatsTask = nil
        stats.reset()
        bitrateStarvation.reset()
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        sessionLimit = nil
        networkGovernor = nil
        networkPathTask?.cancel()
        networkPathTask = nil
        networkPathAvailable = true
        cancelNativeShortcutTasks()
        sessionReadyFullScreenTask?.cancel()
        sessionReadyFullScreenTask = nil
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        nativeView?.setPointerLocked(false)
        nativeView?.setNativeNVSTVideoVisible(false)
        endEventTask?.cancel()
        endEventTask = nil
        nativeView?.onInputEvent = nil
        nativeView?.onAbsoluteMouseMove = nil
        nativeView?.onPointerLockChanged = nil
        nativeView?.onCommand = nil
        nativeView?.shouldHandleCommand = nil
        StreamSessionLifecycle.deactivate(configuration.id)
        onEnd(report.success, report.message, report)
    }
}
