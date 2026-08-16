//  OpenNOW
//
//  Created by OpenCode on 6/16/26.
//

import Foundation
import SwiftUI

typealias WebRTCMediaStreamCompletion = WebRTCMediaStreamEndCallback
typealias WebRTCMediaStreamProgressHandler = WebRTCMediaStreamProgressCallback

struct WebRTCMediaStreamView: View {
    let configuration: StreamLaunchConfiguration
    let onProgress: WebRTCMediaStreamProgressHandler?
    let onRequiredSessionAd: (@Sendable (StreamSessionAdPresentation) async throws -> Int)?
    let onEnd: WebRTCMediaStreamCompletion
    private let coordinator: OpenNOWStreamSessionCoordinator

    init(configuration: StreamLaunchConfiguration,
         onProgress: WebRTCMediaStreamProgressHandler?,
         onRequiredSessionAd: (@Sendable (StreamSessionAdPresentation) async throws -> Int)? = nil,
         onEnd: @escaping WebRTCMediaStreamCompletion) {
        self.configuration = configuration
        self.onProgress = onProgress
        self.onRequiredSessionAd = onRequiredSessionAd
        self.onEnd = onEnd
        coordinator = OpenNOWStreamSessionCoordinator(
            adPresenter: InlineStreamSessionAdPresenter(handler: onRequiredSessionAd),
            progressHandler: { progress in
                Task { @MainActor in onProgress?(progress) }
            }
        )
    }

    var body: some View {
        switch Self.selectedTransport(applicationID: configuration.applicationID) {
        case .webRTC:
            WebRTCMediaStreamSurface(
                configuration: configuration,
                sessionProvider: coordinator,
                signaling: coordinator,
                onAntiAFKStateChange: { enabled in OPNStreamPreferences.saveAntiAFKMouseMovementEnabled(enabled) },
                onVideoEnhancementChange: { mode, sharpness, denoise in
                    OPNStreamPreferences.saveUpscalingSettings(mode: mode, sharpness: sharpness, denoise: denoise, forGame: configuration.applicationID)
                },
                preventDisplaySleep: Self.preventDisplaySleepWhileStreaming(applicationID: configuration.applicationID),
                onProgress: { progress in
                    onProgress?(progress)
                },
                onEnd: { success, message, report in
                    onEnd(success, message, report)
                }
            )
        case .nativeNVST:
            NativeNVSTMediaStreamSurface(
                configuration: configuration,
                sessionProvider: coordinator,
                preventDisplaySleep: Self.preventDisplaySleepWhileStreaming(applicationID: configuration.applicationID),
                onProgress: { progress in
                    onProgress?(progress)
                },
                onEnd: { success, message, report in
                    onEnd(success, message, report)
                }
            )
        }
    }

    private static func selectedTransport(applicationID: String) -> OPNSelectedStreamTransport {
        OPNStreamTransportSelector.selectedTransport(forGame: applicationID)
    }

    private static func preventDisplaySleepWhileStreaming(applicationID: String) -> Bool {
        let profile = OPNStreamPreferences.launchProfile(forGame: applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        return profile.preventDisplaySleepWhileStreaming
    }
}

private struct NativeNVSTMediaStreamSurface: View {
    let configuration: StreamLaunchConfiguration
    let sessionProvider: any NativeNVSTSessionProvider
    let preventDisplaySleep: Bool
    let onProgress: WebRTCMediaStreamProgressHandler?
    let onEnd: WebRTCMediaStreamCompletion
    private let sidebarCapabilities = StreamSidebarCapabilities.nativeNVST

    @State private var path: NativeNVSTStreamingPath?
    @State private var startTask: Task<Void, Never>?
    @State private var endEventTask: Task<Void, Never>?
    @State private var nativeView: NativeWebRTCStreamView?
    @State private var statusMessage = "Starting native NVST transport..."
    @State private var isConnected = false
    @State private var isEnding = false
    @State private var didEnd = false
    @State private var unifiedHUDVisible = false
    @State private var streamControlsVisible = false
    @State private var nativeStatsVisible = false
    @State private var latestNativeStats: NativeNVSTPerformanceSnapshot?
    @State private var nativeStatsTask: Task<Void, Never>?
    @State private var mouseInputDispatcher: NativeNVSTMouseInputDispatcher?
    @State private var microphoneAvailable = false
    @State private var microphoneEnabled = false
    @State private var microphoneUpdateTask: Task<Void, Never>?
    @State private var antiAFKMouseMovementEnabled = false
    @State private var antiAFKMouseMovementTask: Task<Void, Never>?
    @State private var lastAcceptedStreamInputAt = Date()
    @State private var transientStreamMessage = ""
    @State private var transientStreamMessageTask: Task<Void, Never>?
    @State private var pendingApplicationQuitCompletion: WebRTCMediaStreamQuitDecisionHandler?
    @State private var streamingPerformanceActivity: (any NSObjectProtocol)?
    @State private var sessionLimit: StreamSessionSidebarLimit?
    @State private var remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativeNVSTStreamHostView(
                overlay: AnyView(nativeWindowOverlay),
                overlayVisible: nativeStatsVisible || unifiedHUDVisible || streamControlsVisible || !transientStreamMessage.isEmpty,
                overlayCapturesInput: unifiedHUDVisible || streamControlsVisible
            ) { view in
                nativeView = view
                configureNativeView(view)
                startIfNeeded()
            }
            .ignoresSafeArea()
            if !isConnected {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Color.openNowGreen)
                    Text("NATIVE NVST")
                        .font(OpenNOWNVIDIAFont.font(size: 13, weight: .bold))
                        .foregroundStyle(Color.openNowGreen)
                        .tracking(1.4)
                    Text(statusMessage)
                        .font(OpenNOWNVIDIAFont.font(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }
                .padding(28)
            }
        }
        .onAppear {
            WebRTCMediaTelemetry.configure(sink: OpenNOWWebRTCMediaTelemetrySink())
            startIfNeeded()
        }
        .onDisappear { stopStream() }
    }

    private func startIfNeeded() {
        guard startTask == nil, path == nil, !didEnd else { return }
        guard let nativeView, let nativeVideoSurfaceHandle = Self.nativeVideoSurfaceHandle(for: nativeView) else {
            statusMessage = "Preparing native NVST video surface..."
            return
        }
        nativeView.remoteInputEnabled = false
        nativeView.setNativeNVSTVideoVisible(false)
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        microphoneAvailable = profile.microphoneMode.caseInsensitiveCompare("disabled") != .orderedSame
        microphoneEnabled = microphoneAvailable && profile.microphoneMode.caseInsensitiveCompare("voice-activity") == .orderedSame
        antiAFKMouseMovementEnabled = profile.antiAFKMouseMovementEnabled
        lastAcceptedStreamInputAt = Date()
        beginStreamingPerformanceMode()
        let transport = NativeNVSTBifrostTransport(
            nativeVideoSurfaceHandle: nativeVideoSurfaceHandle,
            cursorVisibilityHandler: { [weak nativeView] visible in
                guard let nativeView else { return }
                nativeView.mouseInputMode = visible || !nativeView.directMouseInputEnabled ? .absolute : .relative
            },
            prepareVideoSurfaceForShutdown: {
                nativeView.prepareNativeNVSTRendererForShutdown()
            }
        )
        let path = NativeNVSTStreamingPath(sessionProvider: sessionProvider, transport: transport)
        let mouseInputDispatcher = NativeNVSTMouseInputDispatcher { input in
            switch input {
            case .event(let event):
                try? await path.send(event)
            case .absoluteMove(let event):
                try? await path.sendAbsoluteMouseMove(event)
            }
        }
        self.path = path
        self.mouseInputDispatcher = mouseInputDispatcher
        endEventTask = Task {
            let events = await path.endEvents()
            for await report in events {
                guard !Task.isCancelled else { return }
                await MainActor.run { finishOnce(report: report) }
                return
            }
        }
        configureInput(for: nativeView)
        WebRTCMediaStreamLifecycle.activate(
            configuration.id,
            quitRequestHandler: { completion in
                showStreamControls(completion: completion)
                return true
            },
            commandHandler: handleNativeCommand
        )
        startTask = Task {
            do {
                let session = try await path.start(configuration: configuration) { progress in
                    await MainActor.run {
                        statusMessage = progress.message
                        onProgress?(progress)
                    }
                }
                let shouldPresentStream = await MainActor.run {
                    guard !Task.isCancelled, !didEnd, !isEnding else { return false }
                    isConnected = true
                    sessionLimit = StreamSessionSidebarLimit(session: session)
                    nativeView.remoteInputEnabled = !unifiedHUDVisible && !streamControlsVisible
                    nativeView.setNativeNVSTVideoVisible(true)
                    nativeView.restoreInputFocus()
                    statusMessage = "Connected over native NVST."
                    startNativeStatsPolling(path: path)
                    refreshAntiAFKMouseMovementTask()
                    onProgress?(StreamProgress(configuration: configuration, step: .connected, message: "Connected over native NVST.", isReady: true))
                    WebRTCMediaTelemetry.capture("nvst.ui.connected", level: .info, message: "Native NVST stream connected.", attributes: ["sessionId": session.id])
                    return true
                }
                if !shouldPresentStream {
                    _ = try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed during startup.")
                }
            } catch {
                await MainActor.run { handleStartFailure(error) }
            }
        }
    }

    private func handleStartFailure(_ error: Error) {
        guard !(error is CancellationError), !Task.isCancelled else {
            statusMessage = "Native NVST launch cancelled."
            endStreamingPerformanceMode()
            return
        }
        let message = Self.message(for: error)
        statusMessage = message
        isConnected = false
        nativeView?.remoteInputEnabled = false
        nativeView?.setPointerLocked(false)
        nativeView?.setNativeNVSTVideoVisible(false)
        mouseInputDispatcher?.cancel()
        mouseInputDispatcher = nil
        endStreamingPerformanceMode()
        var metadata = ["applicationID": configuration.applicationID, "transport": "nvst"]
        if let sessionError = error as? OpenNOWStreamSessionError, case .activeSessionConflict(let conflict) = sessionError {
            metadata.merge(conflict.reportMetadata) { current, _ in current }
        }
        finishOnce(report: StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: metadata))
    }

    private func stopStream() {
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
        sessionLimit = nil
        cancelNativeShortcutTasks()
        endStreamingPerformanceMode()
        nativeView?.remoteInputEnabled = false
        let mouseInputDispatcher = self.mouseInputDispatcher
        self.mouseInputDispatcher = nil
        isConnected = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        microphoneAvailable = false
        microphoneEnabled = false
        antiAFKMouseMovementEnabled = false
        nativeView?.setNativeNVSTVideoVisible(false)
        guard !didEnd else {
            mouseInputDispatcher?.cancel()
            return
        }
        didEnd = true
        nativeView?.onInputEvent = nil
        nativeView?.onAbsoluteMouseMove = nil
        nativeView?.onPointerLockChanged = nil
        nativeView?.onCommand = nil
        nativeView?.shouldHandleCommand = nil
        if let path {
            Task {
                await mouseInputDispatcher?.finish()
                _ = try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed.")
            }
        } else {
            mouseInputDispatcher?.cancel()
        }
    }

    private func finish(reason: StreamEndReason, message: String) async -> Bool {
        guard !isEnding else { return false }
        let mouseInputDispatcher = await MainActor.run {
            nativeView?.remoteInputEnabled = false
            nativeView?.setNativeNVSTVideoVisible(false)
            let dispatcher = self.mouseInputDispatcher
            self.mouseInputDispatcher = nil
            isEnding = true
            return dispatcher
        }
        await mouseInputDispatcher?.finish()
        guard let path else {
            await MainActor.run {
                isEnding = false
                showStreamControls()
            }
            return false
        }
        do {
            let report = try await path.stop(reason: reason, message: message)
            await MainActor.run { finishOnce(report: report) }
            return true
        } catch {
            let failureMessage = Self.message(for: error)
            if reason == .paused {
                await MainActor.run {
                    isEnding = false
                    statusMessage = failureMessage
                    self.mouseInputDispatcher = NativeNVSTMouseInputDispatcher { input in
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

    private func finishOnce(report: StreamReport) {
        guard !didEnd else { return }
        nativeView?.remoteInputEnabled = false
        mouseInputDispatcher?.cancel()
        mouseInputDispatcher = nil
        didEnd = true
        isConnected = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        microphoneAvailable = false
        microphoneEnabled = false
        antiAFKMouseMovementEnabled = false
        nativeStatsTask?.cancel()
        nativeStatsTask = nil
        latestNativeStats = nil
        sessionLimit = nil
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

    private func configureNativeView(_ view: NativeWebRTCStreamView) {
        guard !didEnd, !isEnding else {
            view.remoteInputEnabled = false
            view.setNativeNVSTVideoVisible(false)
            return
        }
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        view.directMouseInputEnabled = profile.directMouseInput
        view.locksPointerWhenRelativeModeSelected = true
        view.hidesCursorWhilePointerLocked = true
        if path == nil { view.mouseInputMode = .absolute }
        view.setStreamContentSize(width: profile.resolution.width, height: profile.resolution.height)
        view.remoteInputEnabled = isConnected && !unifiedHUDVisible && !streamControlsVisible
        configureInput(for: view)
    }

    private func configureInput(for view: NativeWebRTCStreamView) {
        view.onInputEvent = { [path, weak view] event in
            guard let path, let view, isConnected, !unifiedHUDVisible, !streamControlsVisible, !isEnding, !didEnd else { return }
            let isLockedMouseRelease = view.isPointerLocked && Self.isMouseButtonRelease(event)
            if view.remoteInputEnabled && !isLockedMouseRelease {
                guard NSApplication.shared.isActive, view.window?.isKeyWindow == true else { return }
            }
            lastAcceptedStreamInputAt = Date()
            if case .mouse = event {
                if view.mouseInputMode == .relative, !view.isPointerLocked { return }
                mouseInputDispatcher?.enqueue(event)
                return
            }
            Task { try? await path.send(event) }
        }
        view.shouldHandleCommand = { _ in
            isConnected
        }
        view.onCommand = { command in
            handleNativeCommand(command)
        }
        view.onAbsoluteMouseMove = { event in
            guard isConnected, !unifiedHUDVisible, !streamControlsVisible, !isEnding, !didEnd,
                  view.remoteInputEnabled, view.mouseInputMode == .absolute,
                  NSApplication.shared.isActive, view.window?.isKeyWindow == true else { return }
            lastAcceptedStreamInputAt = Date()
            mouseInputDispatcher?.enqueueAbsoluteMove(event)
        }
    }

    private static func isMouseButtonRelease(_ event: UserInputEvent) -> Bool {
        guard case .mouse(.button(_, _, let isPressed, _)) = event else { return false }
        return !isPressed
    }

    private func handleNativeCommand(_ command: WebRTCMediaStreamCommand) {
        switch command {
        case .toggleStatsHUD:
            toggleNativeStatsHUD()
        case .toggleUnifiedHUD:
            guard !streamControlsVisible else { return }
            setUnifiedHUDVisible(!unifiedHUDVisible)
        case .toggleMicrophone:
            toggleNativeMicrophone()
        case .toggleRecording:
            showNativeTransientStreamMessage("Recording is unavailable with native NVST.")
            WebRTCMediaTelemetry.capture("nvst.ui.recording.unavailable", level: .warning, message: "Native NVST recording shortcut requested without a registered recorder pipeline.", attributes: ["applicationID": configuration.applicationID])
        case .toggleAntiAFK:
            toggleNativeAntiAFKMouseMovement()
        case .showQuitMenu:
            if !streamControlsVisible { showStreamControls() }
        }
    }

    private func toggleNativeMicrophone() {
        guard isConnected, !isEnding, !didEnd else { return }
        guard microphoneAvailable else {
            microphoneEnabled = false
            showNativeTransientStreamMessage("Microphone is disabled in Settings.")
            return
        }
        guard microphoneUpdateTask == nil, let path else { return }
        let nextEnabled = !microphoneEnabled
        microphoneUpdateTask = Task { @MainActor in
            defer { microphoneUpdateTask = nil }
            do {
                try await path.setMicrophoneEnabled(nextEnabled)
                guard !Task.isCancelled, !didEnd else { return }
                microphoneEnabled = nextEnabled
                showNativeTransientStreamMessage(nextEnabled ? "Microphone On" : "Microphone Muted")
                WebRTCMediaTelemetry.capture("nvst.ui.microphone.toggle", level: .info, message: nextEnabled ? "Native NVST microphone enabled." : "Native NVST microphone muted.", attributes: ["applicationID": configuration.applicationID, "enabled": String(nextEnabled)])
            } catch {
                guard !Task.isCancelled, !didEnd else { return }
                let message = Self.message(for: error)
                showNativeTransientStreamMessage(message)
                WebRTCMediaTelemetry.capture("nvst.ui.microphone.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID])
            }
        }
    }

    private func toggleNativeAntiAFKMouseMovement() {
        guard isConnected, !isEnding, !didEnd else { return }
        antiAFKMouseMovementEnabled.toggle()
        OPNStreamPreferences.saveAntiAFKMouseMovementEnabled(antiAFKMouseMovementEnabled)
        refreshAntiAFKMouseMovementTask()
        showNativeTransientStreamMessage(antiAFKMouseMovementEnabled ? "Anti-AFK On" : "Anti-AFK Off")
        WebRTCMediaTelemetry.capture("nvst.ui.anti_afk.toggle", level: .info, message: antiAFKMouseMovementEnabled ? "Native NVST Anti-AFK mouse movement enabled." : "Native NVST Anti-AFK mouse movement disabled.", attributes: ["applicationID": configuration.applicationID, "enabled": String(antiAFKMouseMovementEnabled)])
    }

    private func refreshAntiAFKMouseMovementTask() {
        guard isConnected, antiAFKMouseMovementEnabled else {
            antiAFKMouseMovementTask?.cancel()
            antiAFKMouseMovementTask = nil
            return
        }
        guard antiAFKMouseMovementTask == nil else { return }
        antiAFKMouseMovementTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: StreamAntiAFKInputPolicy.pollInterval)
                guard !Task.isCancelled else { return }
                sendNativeAntiAFKMouseMovement()
            }
        }
    }

    private func sendNativeAntiAFKMouseMovement() {
        guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, !unifiedHUDVisible, !streamControlsVisible, mouseInputDispatcher != nil else { return }
        guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
        let delta = StreamAntiAFKInputPolicy.randomMouseDelta()
        mouseInputDispatcher?.enqueue(StreamAntiAFKInputPolicy.mouseMove(deltaX: delta.x, deltaY: delta.y))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, !unifiedHUDVisible, !streamControlsVisible else { return }
            guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
            mouseInputDispatcher?.enqueue(StreamAntiAFKInputPolicy.mouseMove(deltaX: -delta.x, deltaY: -delta.y))
        }
    }

    private func showNativeTransientStreamMessage(_ message: String) {
        transientStreamMessageTask?.cancel()
        transientStreamMessage = message
        transientStreamMessageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            transientStreamMessage = ""
            transientStreamMessageTask = nil
        }
    }

    private func cancelNativeShortcutTasks() {
        microphoneUpdateTask?.cancel()
        microphoneUpdateTask = nil
        antiAFKMouseMovementTask?.cancel()
        antiAFKMouseMovementTask = nil
        transientStreamMessageTask?.cancel()
        transientStreamMessageTask = nil
        transientStreamMessage = ""
    }

    private func showStreamControls(completion: WebRTCMediaStreamQuitDecisionHandler? = nil) {
        guard isConnected else {
            let pendingStartTask = startTask
            let pendingPath = path
            pendingStartTask?.cancel()
            Task {
                await pendingStartTask?.value
                await pendingPath?.cancelStart()
                completion?(true)
            }
            return
        }
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = completion
        unifiedHUDVisible = false
        nativeView?.remoteInputEnabled = false
        nativeView?.setNativeNVSTVideoVisible(isConnected)
        streamControlsVisible = true
        WebRTCMediaTelemetry.capture("nvst.ui.controls.show", level: .info, message: "Native NVST stream controls shown.", attributes: ["applicationID": configuration.applicationID])
    }

    private func dismissStreamControls() {
        guard !isEnding else { return }
        streamControlsVisible = false
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        nativeView?.remoteInputEnabled = isConnected && !unifiedHUDVisible
        nativeView?.setNativeNVSTVideoVisible(isConnected)
        nativeView?.restoreInputFocus()
        completion?(false)
        WebRTCMediaTelemetry.capture("nvst.ui.controls.dismiss", level: .info, message: "Native NVST stream controls dismissed.", attributes: ["applicationID": configuration.applicationID])
    }

    private func setUnifiedHUDVisible(_ visible: Bool) {
        guard isConnected, !streamControlsVisible else { return }
        if visible {
            nativeView?.remoteInputEnabled = false
            unifiedHUDVisible = true
        } else {
            unifiedHUDVisible = false
            nativeView?.remoteInputEnabled = true
            nativeView?.restoreInputFocus()
        }
        WebRTCMediaTelemetry.capture("nvst.ui.hud.toggle", level: .info, message: visible ? "Native NVST HUD shown." : "Native NVST HUD hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(visible)])
    }

    private func toggleNativeStatsHUD() {
        guard isConnected, !isEnding, !didEnd else { return }
        nativeStatsVisible.toggle()
        WebRTCMediaTelemetry.capture("nvst.ui.stats.toggle", level: .info, message: nativeStatsVisible ? "OpenNOW NVST stats shown." : "OpenNOW NVST stats hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(nativeStatsVisible)])
    }

    private func startNativeStatsPolling(path: NativeNVSTStreamingPath) {
        nativeStatsTask?.cancel()
        nativeStatsTask = Task {
            while !Task.isCancelled {
                if let snapshot = await path.performanceSnapshot(), isConnected, !isEnding, !didEnd {
                    latestNativeStats = snapshot
                }
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func pauseFromStreamControls() {
        guard !isEnding else { return }
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        Task {
            _ = await finish(reason: .paused, message: "Native NVST stream paused.")
            completion?(false)
        }
    }

    private func endFromStreamControls() {
        guard !isEnding else { return }
        let completion = pendingApplicationQuitCompletion
        let shouldTerminateApplication = completion != nil
        pendingApplicationQuitCompletion = nil
        Task {
            let didFinish = await finish(reason: .userRequested, message: "Native NVST stream ended by user.")
            completion?(didFinish && shouldTerminateApplication)
        }
    }

    @ViewBuilder private var nativeWindowOverlay: some View {
        ZStack(alignment: .topLeading) {
            if nativeStatsVisible && !streamControlsVisible { nativeStatsHUD }
            if unifiedHUDVisible { nativeUnifiedHUD }
            if streamControlsVisible { nativeStreamControlsOverlay }
            if !transientStreamMessage.isEmpty { nativeTransientStreamMessageOverlay }
        }
    }

    private var nativeTransientStreamMessageOverlay: some View {
        Text(transientStreamMessage)
            .font(.streamNvidia(size: 12, weight: .bold))
            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.86))
            .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.55), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 24)
            .allowsHitTesting(false)
    }

    private var nativeStatsHUD: some View {
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        let streamFramesPerSecond = latestNativeStats?.streamFramesPerSecond ?? Double(profile.fps)
        let resolution = nonEmptyNativeStat(latestNativeStats?.resolution, fallback: "\(profile.resolution.width)x\(profile.resolution.height)")
        let codec = nonEmptyNativeStat(latestNativeStats?.codec, fallback: profile.codec.value.uppercased())
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                nativeStatsCompactBox(value: nativeLiveStatsWholeNumber(latestNativeStats?.gameFramesPerSecond), label: "GAME FPS", color: nativeGameFPSColor(target: streamFramesPerSecond))
                nativeStatsVerticalDivider
                nativeStatsCompactBox(value: nativeStatsWholeNumber(streamFramesPerSecond), label: "STREAM FPS", color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsVerticalDivider
                nativeStatsCompactBox(value: nativeLiveStatsWholeNumber(latestNativeStats?.latencyMilliseconds), label: "MS", color: nativeLatencyColor)
            }
            .frame(height: 48)

            nativeStatsHorizontalDivider

            VStack(alignment: .leading, spacing: 5) {
                nativeStatsStandardRow(label: "Frame Loss", value: nativeStatsCount(latestNativeStats?.frameLoss), detail: nativeStatsTotal(latestNativeStats?.totalFrameLoss), color: nativeFrameLossColor)
                nativeStatsStandardRow(label: "Packet Loss", value: nativeStatsCount(latestNativeStats?.packetLoss), detail: nativeStatsTotal(latestNativeStats?.totalPacketLoss), color: nativePacketLossColor)
                nativeStatsStandardRow(label: "Bandwidth Used", value: nativeStatsMegabits(latestNativeStats?.bitrateMegabitsPerSecond), detail: "Mbps", color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Resolution", value: resolution, detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Codec", value: codec, detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
                nativeStatsStandardRow(label: "Server Location", value: nonEmptyNativeStat(latestNativeStats?.serverLocation, fallback: "--"), detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
            }
        }
        .padding(10)
        .frame(width: 264, alignment: .topLeading)
        .background(Color.black.opacity(0.90))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(WebRTCMediaStreamTheme.accent)
                .frame(height: 2)
        }
        .overlay(Rectangle().stroke(.white.opacity(0.16), lineWidth: 1))
        .shadow(color: .black.opacity(0.52), radius: 16, x: 0, y: 8)
        .padding(.top, 5)
        .padding(.trailing, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
    }

    private func nativeStatsCompactBox(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.streamNvidia(size: 22, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            Text(label)
                .font(.streamNvidia(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.055))
    }

    private var nativeStatsVerticalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private var nativeStatsHorizontalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(height: 1)
    }

    private func nativeStatsStandardRow(label: String, value: String, detail: String?, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.streamNvidia(size: 10, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamNvidia(size: 10, weight: .bold))
                .foregroundStyle(color)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.streamNvidia(size: 10, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func nativeGameFPSColor(target: Double) -> Color {
        guard let latestNativeStats, latestNativeStats.available, latestNativeStats.gameFramesPerSecond >= 0 else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.gameFramesPerSecond >= max(1, target * 0.9) ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    private var nativeLatencyColor: Color {
        guard let latestNativeStats, latestNativeStats.available, latestNativeStats.latencyMilliseconds >= 0 else { return WebRTCMediaStreamTheme.textTertiary }
        if latestNativeStats.latencyMilliseconds >= 120 { return WebRTCMediaStreamTheme.danger }
        if latestNativeStats.latencyMilliseconds >= 90 { return WebRTCMediaStreamTheme.warning }
        return WebRTCMediaStreamTheme.accent
    }

    private var nativeFrameLossColor: Color {
        guard let latestNativeStats, latestNativeStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.frameLoss == 0 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    private var nativePacketLossColor: Color {
        guard let latestNativeStats, latestNativeStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestNativeStats.packetLoss == 0 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    private func nativeStatsWholeNumber(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    private func nativeLiveStatsWholeNumber(_ value: Double?) -> String {
        guard latestNativeStats?.available == true else { return "--" }
        return nativeStatsWholeNumber(value)
    }

    private func nativeStatsCount(_ value: UInt64?) -> String {
        guard latestNativeStats?.available == true, let value else { return "--" }
        return String(value)
    }

    private func nativeStatsTotal(_ value: UInt64?) -> String {
        guard latestNativeStats?.available == true, let value else { return "(-- Total)" }
        return "(\(value) Total)"
    }

    private func nativeStatsMegabits(_ value: Double?) -> String {
        guard latestNativeStats?.available == true, let value, value >= 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    private func nonEmptyNativeStat(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty else { return fallback }
        return value
    }

    private var nativeMicrophoneStatusText: String {
        guard microphoneAvailable else { return "Disabled" }
        return microphoneEnabled ? "On" : "Muted"
    }

    private func nativeSessionLimitText(at date: Date) -> String {
        guard let sessionLimit else { return "Unlimited" }
        let remainingSeconds = sessionLimit.remainingSeconds(at: date)
        return String(format: "%d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    private func nativeSessionLimitIsHealthy(at date: Date) -> Bool {
        guard let sessionLimit else { return true }
        return sessionLimit.remainingSeconds(at: date) > 300
    }

    private var nativeNetworkHealthText: String {
        guard latestNativeStats?.available == true else { return "Waiting" }
        if (latestNativeStats?.packetLoss ?? 0) > 0 || (latestNativeStats?.jitterMilliseconds ?? 0) >= 35 || (latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Poor" }
        if (latestNativeStats?.jitterMilliseconds ?? 0) >= 20 || (latestNativeStats?.latencyMilliseconds ?? 0) >= 90 { return "Fair" }
        return "Good"
    }

    private var nativeNetworkHealthIsGood: Bool {
        nativeNetworkHealthText == "Good"
    }

    private var nativeLatencyText: String {
        guard latestNativeStats?.available == true, let latency = latestNativeStats?.latencyMilliseconds, latency >= 0 else { return "--" }
        return "\(Int(latency.rounded())) ms"
    }

    private var nativePacketLossText: String {
        guard latestNativeStats?.available == true, let packetLoss = latestNativeStats?.packetLoss else { return "--" }
        return String(packetLoss)
    }

    private var nativeNetworkWarningText: String {
        guard latestNativeStats?.available == true else { return "Waiting for native NVST network telemetry." }
        if (latestNativeStats?.packetLoss ?? 0) > 0 { return "Packet loss is active; image quality or input response may degrade." }
        if (latestNativeStats?.latencyMilliseconds ?? 0) >= 120 { return "Latency is high; input may feel delayed." }
        if (latestNativeStats?.jitterMilliseconds ?? 0) >= 35 { return "Network jitter is unstable; gameplay may stutter." }
        if let bitrate = latestNativeStats?.bitrateMegabitsPerSecond, bitrate >= 0, bitrate < 5 { return "Inbound bitrate is low for cloud gaming quality." }
        return ""
    }

    private var nativeUnifiedHUD: some View {
        StreamUnifiedSidebar(title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title, closeAction: { setUnifiedHUDVisible(false) }) {
            VStack(alignment: .leading, spacing: 14) {
                nativeHUDStatusPanel
                nativeHUDControlsPanel
                nativeHUDNetworkPanel
                if sidebarCapabilities.visibleFeatures.contains(.remoteCoOp), remoteCoOpPreferences.isAlphaOptedIn {
                    nativeHUDRemoteCoOpPanel
                }
                nativeHUDVideoPanel
            }
        }
    }

    private var nativeHUDStatusPanel: some View {
        HStack(spacing: 8) {
            StreamHUDMetricCard(title: "Mic", value: nativeMicrophoneStatusText, positive: microphoneEnabled && microphoneAvailable)
            StreamHUDMetricCard(title: "Rec", value: "Unavailable", positive: false)
            StreamHUDMetricCard(title: "AFK", value: antiAFKMouseMovementEnabled ? "On" : "Off", positive: antiAFKMouseMovementEnabled)
            if sessionLimit != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    StreamHUDMetricCard(title: "Session", value: nativeSessionLimitText(at: context.date), positive: nativeSessionLimitIsHealthy(at: context.date))
                }
            }
            if remoteCoOpPreferences.isAlphaOptedIn {
                StreamHUDMetricCard(title: "Co-Op", value: "Unavailable", positive: false)
            }
        }
    }

    private var nativeHUDControlsPanel: some View {
        StreamHUDSection(label: "CONTROLS", spacing: 8) {
            HStack(spacing: 8) {
                StreamHUDActionRow(
                    title: microphoneEnabled ? "Mute microphone" : "Unmute microphone",
                    subtitle: nativeMicrophoneStatusText,
                    systemName: microphoneEnabled ? "mic.slash.fill" : "mic.fill",
                    isActive: microphoneEnabled && microphoneAvailable,
                    isDisabled: !sidebarCapabilities.supports(.microphone) || !microphoneAvailable || microphoneUpdateTask != nil,
                    action: toggleNativeMicrophone
                )
                StreamHUDActionRow(
                    title: "Record",
                    subtitle: "Unavailable with native NVST",
                    systemName: "record.circle",
                    isActive: false,
                    isDisabled: !sidebarCapabilities.supports(.recording),
                    action: {}
                )
                StreamHUDActionRow(
                    title: antiAFKMouseMovementEnabled ? "Disable Anti-AFK" : "Enable Anti-AFK",
                    subtitle: antiAFKMouseMovementEnabled ? "Active" : "Idle",
                    systemName: "cursorarrow.motionlines",
                    isActive: antiAFKMouseMovementEnabled,
                    isDisabled: !sidebarCapabilities.supports(.antiAFK) || !isConnected,
                    action: toggleNativeAntiAFKMouseMovement
                )
                StreamHUDActionRow(
                    title: nativeStatsVisible ? "Hide Floating Stats" : "Show Floating Stats",
                    subtitle: "Detailed overlay",
                    systemName: "chart.line.uptrend.xyaxis",
                    isActive: nativeStatsVisible,
                    isDisabled: !sidebarCapabilities.supports(.floatingStats),
                    action: toggleNativeStatsHUD
                )
            }
        }
    }

    private var nativeHUDNetworkPanel: some View {
        StreamHUDSection(label: "NETWORK", spacing: 8) {
            HStack(spacing: 8) {
                StreamHUDMetricCard(title: "Health", value: nativeNetworkHealthText, positive: nativeNetworkHealthIsGood)
                StreamHUDMetricCard(title: "Latency", value: nativeLatencyText, positive: (latestNativeStats?.latencyMilliseconds ?? 0) < 90)
                StreamHUDMetricCard(title: "Loss", value: nativePacketLossText, positive: (latestNativeStats?.packetLoss ?? 0) == 0)
            }
            if !nativeNetworkWarningText.isEmpty {
                Text(nativeNetworkWarningText)
                    .font(.streamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.warning)
                    .lineLimit(2)
            }
        }
    }

    private var nativeHUDRemoteCoOpPanel: some View {
        StreamHUDSection(label: "CO-OP", spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Remote Co-Op")
                            .font(.streamNvidia(size: 14, weight: .bold))
                            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        Text("Video and audio relay require WebRTC transport.")
                            .font(.streamNvidia(size: 11, weight: .medium))
                            .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Text("NVST")
                        .font(.streamNvidia(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(WebRTCMediaStreamTheme.warning)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.07))
                        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
                }
                StreamHUDActionRow(
                    title: "Create Invite",
                    subtitle: "Unavailable with native NVST",
                    systemName: "person.badge.plus",
                    isActive: false,
                    isDisabled: !sidebarCapabilities.supports(.remoteCoOp),
                    action: {}
                )
                nativeHUDDetailRow(label: "Slots", value: "\(remoteCoOpPreferences.effectiveReservedGuestSlots)")
                nativeHUDDetailRow(label: "Quality", value: remoteCoOpPreferences.qualityPreset.label)
                nativeHUDDetailRow(label: "Latency", value: remoteCoOpPreferences.latencyMode.label)
            }
        }
    }

    private var nativeHUDVideoPanel: some View {
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        return StreamHUDSection(label: "VIDEO") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("MetalFX Upscaling", selection: Binding.constant(0)) {
                    Text("Off").tag(0)
                    Text("MetalFX").tag(3)
                }
                .font(.streamNvidia(size: 12, weight: .medium))
                .pickerStyle(.segmented)
                .tint(WebRTCMediaStreamTheme.accent)
                .disabled(!sidebarCapabilities.supports(.videoEnhancement))
                nativeHUDDetailRow(label: "Active", value: "Native")
                nativeHUDDetailRow(label: "Target", value: "Native")
                nativeHUDDetailRow(label: "Resolution", value: "\(profile.resolution.width) x \(profile.resolution.height)")
                nativeHUDDetailRow(label: "Frame Rate", value: "\(profile.fps) FPS")
                nativeHUDDetailRow(label: "Codec", value: profile.codec.value.uppercased())
            }
        }
    }

    private func nativeHUDDetailRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamNvidia(size: 10, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamNvidia(size: 10, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                .lineLimit(1)
        }
    }

    private var nativeStreamControlsOverlay: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()
            VStack(spacing: 20) {
                Text("NATIVE NVST")
                    .font(OpenNOWNVIDIAFont.font(size: 12, weight: .bold))
                    .foregroundStyle(Color.openNowGreen)
                    .tracking(2.2)
                Text("STREAM CONTROLS")
                    .font(OpenNOWNVIDIAFont.font(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(OpenNOWNVIDIAFont.font(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                Text("Remote input is paused. Resume to return focus to the game.")
                    .font(OpenNOWNVIDIAFont.font(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.54))
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button("Resume", action: dismissStreamControls)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.borderedProminent)
                        .tint(Color.openNowGreen)
                    Button("Pause Stream", action: pauseFromStreamControls)
                        .buttonStyle(.bordered)
                    Button(pendingApplicationQuitCompletion == nil ? "End Stream" : "Quit OpenNOW", action: endFromStreamControls)
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .disabled(isEnding)
                Text("\(WebRTCMediaStreamCommand.shortcutGuide)   Esc Resume")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.36))
            }
            .padding(36)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.openNowGreen.opacity(0.32), lineWidth: 1))
        }
    }

    private static func nativeVideoSurfaceHandle(for view: NativeWebRTCStreamView) -> UInt? {
        guard let videoWindow = view.nativeNVSTVideoWindow() else { return nil }
        return UInt(bitPattern: Unmanaged.passUnretained(videoWindow).toOpaque())
    }

    private func beginStreamingPerformanceMode() {
        guard streamingPerformanceActivity == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
        if preventDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        streamingPerformanceActivity = ProcessInfo.processInfo.beginActivity(options: options, reason: "OpenNOW active native NVST stream")
        WebRTCMediaTelemetry.capture("nvst.stream.performance_mode.begin", level: .info, message: "Native NVST performance mode enabled.", attributes: ["applicationID": configuration.applicationID, "preventDisplaySleep": String(preventDisplaySleep)])
    }

    private func endStreamingPerformanceMode() {
        guard let streamingPerformanceActivity else { return }
        ProcessInfo.processInfo.endActivity(streamingPerformanceActivity)
        self.streamingPerformanceActivity = nil
        WebRTCMediaTelemetry.capture("nvst.stream.performance_mode.end", level: .info, message: "Native NVST performance mode disabled.", attributes: ["applicationID": configuration.applicationID])
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST stream request failed." : error.localizedDescription
    }
}

private struct NativeNVSTStreamHostView: NSViewRepresentable {
    let overlay: AnyView
    let overlayVisible: Bool
    let overlayCapturesInput: Bool
    let onResolve: @MainActor (NativeWebRTCStreamView) -> Void

    func makeNSView(context: Context) -> NativeNVSTContainerView {
        let view = NativeNVSTContainerView(frame: .zero)
        view.onResolve = { streamView in
            Task { @MainActor in onResolve(streamView) }
        }
        view.updateOverlay(overlay, visible: overlayVisible, capturesInput: overlayCapturesInput)
        return view
    }

    func updateNSView(_ nsView: NativeNVSTContainerView, context: Context) {
        nsView.updateOverlay(overlay, visible: overlayVisible, capturesInput: overlayCapturesInput)
    }

    static func dismantleNSView(_ nsView: NativeNVSTContainerView, coordinator: ()) {
        nsView.streamView.remoteInputEnabled = false
        nsView.streamView.setPointerLocked(false)
        nsView.streamView.onInputEvent = nil
        nsView.streamView.onAbsoluteMouseMove = nil
        nsView.streamView.onPointerLockChanged = nil
        nsView.streamView.onCommand = nil
        nsView.streamView.shouldHandleCommand = nil
    }

    final class NativeNVSTContainerView: NSView {
        let streamView = NativeWebRTCStreamView(frame: .zero)
        private let overlayView = NativeNVSTOverlayHostingView(rootView: AnyView(EmptyView()))
        var onResolve: ((NativeWebRTCStreamView) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            addSubview(streamView)
            overlayView.isHidden = true
            addSubview(overlayView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onResolve?(streamView) }
        }

        override func layout() {
            super.layout()
            streamView.frame = bounds
            overlayView.frame = bounds
            if window != nil { onResolve?(streamView) }
        }

        func updateOverlay(_ overlay: AnyView, visible: Bool, capturesInput: Bool) {
            overlayView.rootView = overlay
            overlayView.isHidden = !visible
            overlayView.capturesInput = capturesInput
            if visible && capturesInput { NSCursor.arrow.set() }
        }
    }

    final class NativeNVSTOverlayHostingView: NSHostingView<AnyView> {
        var capturesInput = false

        override func hitTest(_ point: NSPoint) -> NSView? {
            capturesInput ? super.hitTest(point) : nil
        }
    }
}

private struct InlineStreamSessionAdPresenter: StreamSessionAdPresenter {
    let handler: (@Sendable (StreamSessionAdPresentation) async throws -> Int)?

    func playRequiredSessionAd(_ ad: StreamSessionAdPresentation) async throws -> Int {
        guard let handler else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("Required ad playback is not available.")
        }
        return try await handler(ad)
    }
}
