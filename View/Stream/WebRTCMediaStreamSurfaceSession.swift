//
//  WebRTCMediaStreamSurfaceSession.swift
//  OpenNOW
//
//  Starting and ending the stream the surface hosts: the transport, the input route into it,
//  and the recording and session-limit state it publishes. Split out of
//  WebRTCMediaStreamSurface.swift.
//

import AppKit
import Combine
import GameController
import Foundation
import SwiftUI

extension WebRTCMediaStreamSurface {
    func startIfNeeded(nativeView: NativeWebRTCStreamView) async {
        guard !hasStarted else { return }
        hasStarted = true
        defer { startTask = nil }
        beginStreamingPerformanceMode()
        let transport = NativeWebRTCTransport(nativeView: nativeView)
        transport.setRemoteCoOpVideoRelay(remoteCoOpVideoRelay)
        transport.setRemoteCoOpAudioRelay(remoteCoOpAudioRelay)
        let path = WebRTCStreamingPath(sessionProvider: sessionProvider, transport: transport, signaling: signaling)
        transport.onEnded = { message in
            handleTransportEnded(message: message)
        }
        transport.onRecordingStatusChanged = { status in
            handleRecordingStatusChanged(status)
        }
        nativeView.onInputEvent = { event in
            routeStreamInput(event, transport: transport)
        }
        self.transport = transport
        self.path = path
        startStatsPolling(transport: transport)
        startSessionLimitUpdatePolling(transport: transport)
        await launchSession(path: path, transport: transport, nativeView: nativeView)
    }

    /// Where one input event goes. The on-screen keyboard and the HUD take gamepad input for
    /// themselves while they are up, but still forward a neutral state so the game does not see a
    /// button stuck down.
    func routeStreamInput(_ event: UserInputEvent, transport: NativeWebRTCTransport) {
        if onScreenKeyboardVisible, !isEndingStream, case .gamepad(let state) = event {
            onScreenKeyboard.handleGamepadState(state)
            if isStreamReady {
                transport.sendNow(.gamepad(GamepadState(deviceID: state.deviceID, playerIndex: state.playerIndex, timestamp: state.timestamp)))
            }
            return
        }
        if unifiedHUDVisible || quitMenuVisible, !isEndingStream, case .gamepad(let state) = event {
            if quitMenuVisible {
                handleQuitMenuGamepad(state)
            } else {
                handleHUDGamepad(state)
            }
            if isStreamReady {
                transport.sendNow(.gamepad(GamepadState(deviceID: state.deviceID, playerIndex: state.playerIndex, timestamp: state.timestamp)))
            }
            return
        }
        switch inputAction(for: event) {
        case .send:
            guard isStreamReady else { return }
            lastAcceptedStreamInputAt = Date()
            transport.sendNow(event)
        case .drop:
            return
        case .setMicrophone(let enabled):
            lastAcceptedStreamInputAt = Date()
            microphoneEnabled = enabled
            transport.setMicrophoneEnabled(enabled)
        }
    
    }

    /// Runs the streaming path and applies what the established session says about itself.
    func launchSession(path: WebRTCStreamingPath, transport: NativeWebRTCTransport, nativeView: NativeWebRTCStreamView) async {
        do {
            let session = try await path.start(configuration: configuration) { progress in
                await MainActor.run {
                    loadingStepIndex = progress.currentStepIndex
                    isStreamReady = progress.isReady
                    onProgress?(progress)
                }
            }
            await MainActor.run {
                sessionLimit = StreamSessionSidebarLimit(session: session)
                publishSessionLimitProgress()
                runtimeSettings = StreamRuntimeSettings(json: session.metadata["settings"])
                microphoneEnabled = runtimeSettings.microphoneMode == "voice-activity"
                transport.setMicrophoneEnabled(microphoneEnabled)
                nativeView.directMouseInputEnabled = runtimeSettings.directMouseInput
                nativeView.setStreamContentSize(width: runtimeSettings.resolutionWidth, height: runtimeSettings.resolutionHeight)
                lastAcceptedStreamInputAt = Date()
                refreshAntiAFKMouseMovementTask()
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else {
                loadingStepIndex = -1
                endStreamingPerformanceMode()
                return
            }
            let message = Self.message(for: error)
            endStreamingPerformanceMode()
            var metadata = ["applicationID": configuration.applicationID]
            if let sessionError = error as? OpenNOWStreamSessionError, case .activeSessionConflict(let conflict) = sessionError {
                metadata.merge(conflict.reportMetadata) { current, _ in current }
            }
            onEnd(false, message, StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: metadata))
        }
    }

    func startStatsPolling(transport: NativeWebRTCTransport) {
        statsTask?.cancel()
        statsTask = Task {
            for await snapshot in transport.statsSnapshots(intervalSeconds: 1) {
                latestStats = snapshot
            }
        }
    }

    func startSessionLimitUpdatePolling(transport: NativeWebRTCTransport) {
        sessionLimitUpdateTask?.cancel()
        sessionLimitUpdateTask = Task {
            for await update in transport.sessionLimitUpdates() {
                await MainActor.run { applySessionLimitUpdate(update) }
            }
        }
    }

    func applySessionLimitUpdate(_ update: StreamSessionLimitUpdate) {
        guard let limit = StreamSessionSidebarLimit(update: update) else { return }
        sessionLimit = limit
        publishSessionLimitProgress()
        WebRTCMediaTelemetry.capture("webrtc.ui.session_limit.update", level: .info, message: "Session limit timer updated from stream message.", attributes: ["applicationID": configuration.applicationID, "remainingSeconds": String(update.remainingSeconds), "timerType": update.timerType])
    }

    func publishSessionLimitProgress() {
        guard let sessionLimit else { return }
        onProgress?(StreamProgress(
            title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title,
            message: "Connected.",
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: StreamLaunchStep.connected.rawValue,
            isReady: true,
            sessionLimitStartedAtEpochSeconds: sessionLimit.startedAt.timeIntervalSince1970,
            sessionLimitSeconds: sessionLimit.durationSeconds
        ))
    }

    func handleRecordingStatusChanged(_ status: WebRTCStreamRecordingStatus) {
        recordingNotificationTask?.cancel()
        let previousStatus = recordingStatus
        recordingStatus = status
        logRecordingStatusChanged(status, previousStatus: previousStatus)
        guard status.isTerminal else { return }
        recordingNotificationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard recordingStatus == status else { return }
            recordingStatus = .idle
            recordingNotificationTask = nil
        }
    }

    func logRecordingStatusChanged(_ status: WebRTCStreamRecordingStatus, previousStatus: WebRTCStreamRecordingStatus) {
        switch status {
        case .idle:
            return
        case .starting:
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.starting", level: .info, message: "Stream recording accepted start request.", attributes: ["applicationID": configuration.applicationID])
        case .recording:
            guard !previousStatus.isRecording else { return }
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.active", level: .info, message: "Stream recording captured its first video frame.", attributes: ["applicationID": configuration.applicationID])
        case .finishing:
            guard previousStatus != .finishing else { return }
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.finishing", level: .info, message: "Stream recording is saving.", attributes: ["applicationID": configuration.applicationID])
        case .finished(let recording):
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.finished", level: .info, message: "Stream recording saved.", attributes: ["applicationID": configuration.applicationID, "file": recording.videoURL.lastPathComponent, "durationSeconds": String(format: "%.2f", recording.durationSeconds), "fileSizeBytes": String(recording.fileSizeBytes)])
        case .failed(let message):
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.failed", level: .warning, message: message, attributes: ["applicationID": configuration.applicationID])
        }
    }

    func inputAction(for event: UserInputEvent) -> StreamInputAction {
        if let mouse = mouseEvent(from: event), pointerLocked, isMouseButtonRelease(mouse) { return .send }
        guard !quitMenuVisible, !isEndingStream else { return .drop }
        if let keyboard = keyboardEvent(from: event), let microphoneAction = microphoneToggleAction(for: keyboard) { return microphoneAction }
        if unifiedHUDVisible { return .drop }
        guard shouldAcceptInputWhenInactive() else { return runtimeSettings.microphoneMode == "push-to-talk" ? .setMicrophone(false) : .drop }
        if let keyboard = keyboardEvent(from: event), let microphoneAction = microphoneAction(for: keyboard) { return microphoneAction }
        if let mouse = mouseEvent(from: event) {
            guard pointerLocked else { return .drop }
            if !runtimeSettings.directMouseInput, isMouseMove(mouse) { return .drop }
        }
        return .send
    }

    func shouldAcceptInputWhenInactive() -> Bool {
        guard runtimeSettings.suppressInputWhenInactive else { return true }
        guard let nativeView else { return false }
        return nativeView.window?.isKeyWindow == true && NSApplication.shared.isActive
    }

    func microphoneToggleAction(for keyboard: KeyboardEvent) -> StreamInputAction? {
        guard keyboard.modifiers.intersection(Self.hotkeyModifierMask) == .command, Int(keyboard.keyCode) == Self.microphoneToggleKeyCode else { return nil }
        guard keyboard.isPressed else { return .drop }
        toggleMicrophone()
        return .drop
    }

    func microphoneAction(for keyboard: KeyboardEvent) -> StreamInputAction? {
        guard runtimeSettings.microphoneMode == "push-to-talk" else { return nil }
        guard Int(keyboard.keyCode) == runtimeSettings.microphonePushToTalkKeyCode else { return nil }
        let configuredModifiers = UInt16(truncatingIfNeeded: runtimeSettings.microphonePushToTalkModifierMask) & Self.pushToTalkModifierMask
        guard keyboard.modifiers.rawValue & Self.pushToTalkModifierMask == configuredModifiers else { return nil }
        return .setMicrophone(keyboard.isPressed)
    }

    func keyboardEvent(from event: UserInputEvent) -> KeyboardEvent? {
        if case .keyboard(let keyboard) = event { return keyboard }
        return nil
    }

    func mouseEvent(from event: UserInputEvent) -> MouseEvent? {
        if case .mouse(let mouse) = event { return mouse }
        return nil
    }

    func isMouseMove(_ event: MouseEvent) -> Bool {
        if case .moved = event { return true }
        return false
    }

    func isMouseButtonRelease(_ event: MouseEvent) -> Bool {
        guard case .button(_, _, let isPressed, _) = event else { return false }
        return !isPressed
    }

    func handle(_ command: WebRTCMediaStreamCommand) {
        switch command {
        case .toggleStatsHUD:
            toggleStatsHUD()
        case .toggleUnifiedHUD:
            toggleUnifiedHUD()
        case .toggleMicrophone:
            toggleMicrophone()
        case .toggleRecording:
            toggleRecording()
        case .toggleAntiAFK:
            toggleAntiAFKMouseMovement()
        case .togglePointerCapture:
            togglePointerLockFromHUD()
        case .showQuitMenu:
            showQuitMenu()
        case .toggleOnScreenKeyboard:
            toggleOnScreenKeyboard()
        }
    }

    func toggleOnScreenKeyboard() {
        guard isStreamReady, !isEndingStream, !didEndStream else { return }
        setOnScreenKeyboardVisible(!onScreenKeyboardVisible)
        WebRTCMediaTelemetry.capture("webrtc.ui.osk.toggle", level: .info, message: onScreenKeyboardVisible ? "On-screen keyboard shown." : "On-screen keyboard hidden.", attributes: ["visible": String(onScreenKeyboardVisible)])
    }

    func setOnScreenKeyboardVisible(_ visible: Bool) {
        if visible {
            if quitMenuVisible { dismissQuitMenu() }
            if unifiedHUDVisible { setUnifiedHUDVisible(false) }
            onScreenKeyboard.reset()
            restorePointerLockOnKeyboardHide = pointerLocked
            if pointerLocked { nativeView?.setPointerLocked(false) }
        }
        onScreenKeyboardVisible = visible
        guard !visible, restorePointerLockOnKeyboardHide else { return }
        restorePointerLockOnKeyboardHide = false
        if NSApplication.shared.isActive, nativeView?.window?.isKeyWindow == true {
            nativeView?.setPointerLocked(true)
        }
    }

    func sendOnScreenKeyboardOutput(_ output: StreamOSKOutput) {
        guard isStreamReady, !isEndingStream, let transport else { return }
        let timestamp = MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)
        lastAcceptedStreamInputAt = Date()
        switch output {
        case .text(let value):
            transport.sendNow(.text(deviceID: "keyboard", value: value, timestamp: timestamp))
        case .keyPress(let keyCode):
            transport.sendNow(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: keyCode, scanCode: keyCode, isPressed: true, timestamp: timestamp)))
            transport.sendNow(.keyboard(KeyboardEvent(deviceID: "keyboard", keyCode: keyCode, scanCode: keyCode, isPressed: false, timestamp: timestamp)))
        }
    }

    func toggleAntiAFKMouseMovement() {
        runtimeSettings.antiAFKMouseMovementEnabled.toggle()
        onAntiAFKStateChange?(runtimeSettings.antiAFKMouseMovementEnabled)
        refreshAntiAFKMouseMovementTask()
        showTransientStreamMessage(runtimeSettings.antiAFKMouseMovementEnabled ? "Anti-AFK On" : "Anti-AFK Off")
        WebRTCMediaTelemetry.capture("webrtc.ui.anti_afk.toggle", level: .info, message: runtimeSettings.antiAFKMouseMovementEnabled ? "Anti-AFK mouse movement enabled." : "Anti-AFK mouse movement disabled.", attributes: ["enabled": String(runtimeSettings.antiAFKMouseMovementEnabled)])
    }

    func refreshAntiAFKMouseMovementTask() {
        guard isStreamReady, runtimeSettings.antiAFKMouseMovementEnabled else {
            antiAFKMouseMovementTask?.cancel()
            antiAFKMouseMovementTask = nil
            return
        }
        guard antiAFKMouseMovementTask == nil else { return }
        antiAFKMouseMovementTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: StreamAntiAFKInputPolicy.pollInterval)
                guard !Task.isCancelled else { return }
                sendAntiAFKMouseMovement()
            }
        }
    }

    func sendAntiAFKMouseMovement() {
        guard isStreamReady, runtimeSettings.antiAFKMouseMovementEnabled, !isEndingStream, !didEndStream, !quitMenuVisible, let activeTransport = transport else { return }
        guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
        let delta = StreamAntiAFKInputPolicy.randomMouseDelta()
        activeTransport.sendNow(StreamAntiAFKInputPolicy.mouseMove(deltaX: delta.x, deltaY: delta.y))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard isStreamReady, runtimeSettings.antiAFKMouseMovementEnabled, !isEndingStream, !didEndStream, !quitMenuVisible, let transport else { return }
            guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
            transport.sendNow(StreamAntiAFKInputPolicy.mouseMove(deltaX: -delta.x, deltaY: -delta.y))
        }
    }

    func showTransientStreamMessage(_ message: String) {
        transientStreamMessageTask?.cancel()
        transientStreamMessage = message
        transientStreamMessageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            transientStreamMessage = ""
            transientStreamMessageTask = nil
        }
    }

    func refreshControllerBatteries() {
        let batteries = ControllerBatteryInfo.currentSnapshot()
        for message in batteryAlertTracker.messages(for: batteries) {
            showTransientStreamMessage(message)
        }
        controllerBatteries = batteries
    }

    static func randomAntiAFKMouseDelta() -> (x: Int16, y: Int16) {
        var x = Int16(Int.random(in: -5...5))
        let y = Int16(Int.random(in: -5...5))
        if x == 0 && y == 0 { x = 1 }
        return (x, y)
    }

    static let antiAFKIdleThresholdSeconds: TimeInterval = 210

    static func mouseMove(deltaX: Int16, deltaY: Int16) -> UserInputEvent {
        .mouse(.moved(deviceID: "mouse", deltaX: deltaX, deltaY: deltaY, timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)))
    }

    func toggleMicrophone() {
        guard runtimeSettings.microphoneMode != "disabled" else {
            microphoneEnabled = false
            transport?.setMicrophoneEnabled(false)
            return
        }
        microphoneEnabled.toggle()
        transport?.setMicrophoneEnabled(microphoneEnabled)
        WebRTCMediaTelemetry.capture("webrtc.ui.microphone.toggle", level: .info, message: microphoneEnabled ? "Microphone enabled." : "Microphone muted.", attributes: ["enabled": String(microphoneEnabled)])
    }

    func handlePointerLockChanged(_ locked: Bool) {
        pointerLocked = locked
        if locked {
            setUnifiedHUDVisible(false)
        }
    }

    func registerStreamLifecycle() {
        WebRTCMediaStreamLifecycle.activate(
            configuration.id,
            quitRequestHandler: { completion in
                showQuitMenu(completion: completion)
                return true
            },
            commandHandler: handle
        )
    }

    func showQuitMenu(completion: WebRTCMediaStreamQuitDecisionHandler? = nil) {
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = completion
        if onScreenKeyboardVisible { setOnScreenKeyboardVisible(false) }
        nativeView?.setPointerLocked(false)
        microphoneEnabled = false
        transport?.setMicrophoneEnabled(false)
        quitMenuFocusIndex = 0
        hudGamepadTracker.reset()
        quitMenuVisible = true
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.show", level: .info, message: "Stream quit menu shown.", attributes: ["applicationID": configuration.applicationID])
    }

    func dismissQuitMenu() {
        guard !isEndingStream else { return }
        quitMenuVisible = false
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.dismiss", level: .info, message: "Stream quit menu dismissed.", attributes: ["applicationID": configuration.applicationID])
        completion?(false)
    }

    func pauseFromQuitMenu() {
        guard !isEndingStream else { return }
        isEndingStream = true
        quitMenuVisible = false
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        nativeView?.setPointerLocked(false)
        microphoneEnabled = false
        transport?.setMicrophoneEnabled(false)
        transport?.stopRecording()
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.pause", level: .info, message: "Stream paused from quit menu.", attributes: ["applicationID": configuration.applicationID])
        Task {
            let report = await finishStream(reason: .paused, message: "Stream paused.")
            await MainActor.run {
                completion?(false)
                onEnd(report.success, report.message, report)
            }
        }
    }

    func quitStreamFromMenu() {
        guard !isEndingStream else { return }
        isEndingStream = true
        quitMenuVisible = false
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        nativeView?.setPointerLocked(false)
        microphoneEnabled = false
        transport?.setMicrophoneEnabled(false)
        transport?.stopRecording()
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.quit_stream", level: .info, message: "Stream quit requested from quit menu.", attributes: ["applicationID": configuration.applicationID])
        Task {
            let report = await finishStream(reason: .userRequested, message: "Stream ended by user.")
            await MainActor.run {
                completion?(false)
                onEnd(report.success, report.message, report)
            }
        }
    }

    func handleTransportEnded(message: String) {
        guard !didEndStream else { return }
        isEndingStream = true
        quitMenuVisible = false
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        nativeView?.setPointerLocked(false)
        microphoneEnabled = false
        transport?.setMicrophoneEnabled(false)
        transport?.stopRecording()
        Task {
            let report = await finishStream(reason: .remoteEnded, message: message.isEmpty ? "Stream ended." : message)
            await MainActor.run { onEnd(report.success, report.message, report) }
        }
    }

    func finishStream(reason: StreamEndReason, message: String) async -> StreamReport {
        let fallbackReport = StreamReport(title: configuration.title, success: reason != .failed, reason: reason, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID])
        let shouldFinish = await MainActor.run {
            guard !didEndStream else { return false }
            didEndStream = true
            return true
        }
        guard shouldFinish else { return fallbackReport }
        antiAFKMouseMovementTask?.cancel()
        antiAFKMouseMovementTask = nil
        sessionLimitUpdateTask?.cancel()
        sessionLimitUpdateTask = nil
        let remoteNeutralEvents = await stopRemoteCoOpSession()
        remoteNeutralEvents.forEach { transport?.sendNow($0) }
        remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
        guard let path else { return fallbackReport }
        defer { Task { @MainActor in endStreamingPerformanceMode() } }
        do {
            return try await path.stop(reason: reason, message: message)
        } catch {
            return StreamReport(title: configuration.title, success: false, reason: .failed, message: Self.message(for: error), durationSeconds: 0, metadata: ["applicationID": configuration.applicationID])
        }
    }

    func stopStream() {
        endStreamingPerformanceMode()
        WebRTCMediaStreamLifecycle.deactivate(configuration.id)
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        startTask?.cancel()
        startTask = nil
        statsTask?.cancel()
        statsTask = nil
        sessionLimitUpdateTask?.cancel()
        sessionLimitUpdateTask = nil
        antiAFKMouseMovementTask?.cancel()
        antiAFKMouseMovementTask = nil
        recordingNotificationTask?.cancel()
        recordingNotificationTask = nil
        transientStreamMessageTask?.cancel()
        transientStreamMessageTask = nil
        transientStreamMessage = ""
        controllerBatteries.removeAll()
        batteryAlertTracker.reset()
        sessionLimit = nil
        onScreenKeyboardVisible = false
        restorePointerLockOnKeyboardHide = false
        nativeView?.onScreenKeyboardCapture = nil
        nativeView?.setPointerLocked(false)
        microphoneEnabled = false
        transport?.setMicrophoneEnabled(false)
        transport?.stopRecording()
        let currentTransport = transport
        Task { @MainActor in
            let neutralEvents = await stopRemoteCoOpSession()
            neutralEvents.forEach { currentTransport?.sendNow($0) }
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
        }
        guard !didEndStream else { return }
        didEndStream = true
        if let path { Task { try? await path.stop(reason: .userRequested, message: "Stream view closed.") } }
    }

    func beginStreamingPerformanceMode() {
        guard streamingPerformanceActivity == nil else { return }
        streamingPerformanceActivity = ProcessInfo.processInfo.beginActivity(options: streamingPerformanceActivityOptions, reason: "OpenNOW active cloud gaming stream")
        WebRTCMediaTelemetry.capture("webrtc.stream.performance_mode.begin", level: .info, message: "Streaming performance mode enabled.", attributes: ["applicationID": configuration.applicationID, "preventDisplaySleep": String(preventDisplaySleep)])
    }

    func endStreamingPerformanceMode() {
        guard let streamingPerformanceActivity else { return }
        ProcessInfo.processInfo.endActivity(streamingPerformanceActivity)
        self.streamingPerformanceActivity = nil
        WebRTCMediaTelemetry.capture("webrtc.stream.performance_mode.end", level: .info, message: "Streaming performance mode disabled.", attributes: ["applicationID": configuration.applicationID])
    }

    func refreshStreamingPerformanceMode() {
        guard streamingPerformanceActivity != nil else { return }
        endStreamingPerformanceMode()
        beginStreamingPerformanceMode()
    }

    var streamingPerformanceActivityOptions: ProcessInfo.ActivityOptions {
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
        if preventDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        return options
    }

    static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }

    static let hotkeyModifierMask: KeyboardModifiers = [.shift, .control, .option, .command]
    static let pushToTalkModifierMask = KeyboardModifiers.shift.rawValue | KeyboardModifiers.control.rawValue | KeyboardModifiers.option.rawValue | KeyboardModifiers.command.rawValue | KeyboardModifiers.capsLock.rawValue
    static let microphoneToggleKeyCode = 46
}
