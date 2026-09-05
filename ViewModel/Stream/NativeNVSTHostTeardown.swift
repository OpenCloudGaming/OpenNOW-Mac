//  Ending a native NVST session. Teardown order is load-bearing — see the note in
//  NativeNVSTHostViewModel.swift — and `didEnd` is a once-guard that must not be reset while a
//  session can still end. Split out of NativeNVSTHostViewModel.swift.
//
//  AppKit is imported for the same reason NativeNVSTHostViewModel.swift does: the stream surface
//  is an AppKit view and tearing a session down acts on it directly.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import AVFoundation
import Combine
import Foundation
import GameController

extension NativeNVSTHostViewModel {
    func stopStream() {
        WebRTCMediaStreamLifecycle.deactivate(configuration.id)
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        startTask?.cancel()
        startTask = nil
        endEventTask?.cancel()
        endEventTask = nil
        nativeStatsTask?.cancel()
        nativeStatsTask = nil
        latestNativeStats = nil
        latestRenderDiagnostics = nil
        nativeRigName = ""
        nativeRigRawName = ""
        nativeBitrateStarved = false
        bitrateStarvation.reset()
        sixteenNineTracker = NativeNVSTSixteenNineTitle.Tracker()
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        sessionLimit = nil
        networkGovernor = nil
        networkPathTask?.cancel()
        networkPathTask = nil
        networkPathAvailable = true
        cancelNativeShortcutTasks()
        endStreamingPerformanceMode()
        nativeView?.remoteInputEnabled = false
        let inputDispatcher = self.inputDispatcher
        self.inputDispatcher = nil
        isConnected = false
        pointerLocked = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        microphoneAvailable = false
        microphoneEnabled = false
        microphoneDesiredEnabled = false
        microphoneMode = "disabled"
        microphonePendingStates.removeAll()
        antiAFKMouseMovementEnabled = false
        batteryAlertTracker.reset()
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
        if let path {
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
            }
        } else {
            Task { @MainActor in _ = await stopRemoteCoOpSession() }
            inputDispatcher?.cancel()
        }
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
                WebRTCMediaTelemetry.capture(
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
                    WebRTCMediaTelemetry.capture("nvst.ui.pause.failed", level: .error, message: failureMessage, attributes: ["applicationID": configuration.applicationID])
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
        recordDecodeMeasurementIfLongEnough()
        persistSixteenNineVerdictAtSessionEnd()
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
        microphonePendingStates.removeAll()
        antiAFKMouseMovementEnabled = false
        nativeStatsTask?.cancel()
        nativeStatsTask = nil
        latestNativeStats = nil
        latestRenderDiagnostics = nil
        nativeRigName = ""
        nativeRigRawName = ""
        nativeBitrateStarved = false
        bitrateStarvation.reset()
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        sessionLimit = nil
        networkGovernor = nil
        networkPathTask?.cancel()
        networkPathTask = nil
        networkPathAvailable = true
        cancelNativeShortcutTasks()
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
        WebRTCMediaStreamLifecycle.deactivate(configuration.id)
        onEnd(report.success, report.message, report)
    }
}
