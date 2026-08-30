//
//  NativeNVSTHostViewModel.swift
//  OpenNOW
//
//  The native NVST stream session: starting it, tearing it down, and everything the HUD can do to
//  it while it runs - microphone, anti-AFK, pointer lock, video enhancement, stats polling and the
//  network governor.
//
//  All of this was `@State` and `private func` inside `NativeNVSTMediaStreamSurface`, a SwiftUI
//  view: 52 stored properties, 60 methods and 18 task or timer sites owning a live stream session,
//  none of it reachable without rendering the stream.
//
//  Teardown order is load-bearing and was moved verbatim. In particular the Metal view is never
//  hidden before the native session is destroyed - doing so wedges the render loop and deadlocks
//  shutdown - and `didEnd` is a once-guard that must not be reset while a session can still end.
//
//  swiftlint:disable:next no_appkit_in_view_model
import AppKit
import AVFoundation
import Combine
import Foundation
import GameController

/// AppKit is imported deliberately, and is the one exception to the "view models do not import
/// AppKit" rule. `NativeWebRTCStreamView` *is* the stream: it owns the Metal surface the decoder
/// draws into, the pointer-lock state and the input callbacks. Hiding it behind a protocol would
/// mean a thirty-member pass-through with exactly one implementation - the wrapper layer AGENTS.md
/// rules out - and would not make the session logic any more testable, because every one of those
/// members is a real side effect on a real surface.
@MainActor
final class NativeNVSTHostViewModel: ObservableObject {
    let configuration: StreamLaunchConfiguration
    let sessionProvider: any NativeNVSTSessionProvider
    let preventDisplaySleep: Bool
    let onProgress: WebRTCMediaStreamProgressHandler?
    let onEnd: WebRTCMediaStreamCompletion
    let sidebarCapabilities = StreamSidebarCapabilities.nativeNVST

    init(
        configuration: StreamLaunchConfiguration,
        sessionProvider: any NativeNVSTSessionProvider,
        preventDisplaySleep: Bool,
        onProgress: WebRTCMediaStreamProgressHandler?,
        onEnd: @escaping WebRTCMediaStreamCompletion
    ) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.preventDisplaySleep = preventDisplaySleep
        self.onProgress = onProgress
        self.onEnd = onEnd
    }

    @Published var path: NativeNVSTStreamingPath?
    var startTask: Task<Void, Never>?
    var endEventTask: Task<Void, Never>?
    @Published var nativeView: NativeWebRTCStreamView?
    @Published var loadingStepIndex = -1
    @Published var isConnected = false
    @Published var isEnding = false
    var didEnd = false
    @Published var unifiedHUDVisible = false
    @Published var streamControlsVisible = false
    @Published var nativeStatsVisible = false
    @Published var latestNativeStats: NativeNVSTPerformanceSnapshot?
    var nativeStatsTask: Task<Void, Never>?
    var nativeStreamHealth = NativeNVSTStreamHealthMonitor()
    var inputDispatcher: NativeNVSTInputDispatcher?
    @Published var microphoneAvailable = false
    @Published var microphoneEnabled = false
    var microphoneDesiredEnabled = false
    @Published var microphoneMode = "disabled"
    var microphonePendingStates: [Bool] = []
    @Published var microphoneUpdateTask: Task<Void, Never>?
    @Published var antiAFKMouseMovementEnabled = false
    var antiAFKMouseMovementTask: Task<Void, Never>?
    var lastAcceptedStreamInputAt = Date()
    @Published var transientStreamMessage = ""
    var transientStreamMessageTask: Task<Void, Never>?
    @Published var pendingApplicationQuitCompletion: WebRTCMediaStreamQuitDecisionHandler?
    var streamingPerformanceActivity: (any NSObjectProtocol)?
    @Published var sessionLimit: StreamSessionSidebarLimit?
    @Published var remoteCoOpPreferences = OPNRemoteCoOpPreferencesStore.load()
    var networkGovernor: NativeNVSTNetworkGovernor?
    var networkPathTask: Task<Void, Never>?
    @Published var networkPathAvailable = true
    @Published var pointerLocked = false
    @Published var pillarboxFillModeIndex = 0
    @Published var upscalingModeIndex = 0
    @Published var upscalingTargetIndex = 1
    @Published var upscalingSharpness = 10
    @Published var upscalingDenoise = 0
    @Published var nativeStreamResolutionText = ""
    @Published var nativeStreamFrameRateText = ""
    @Published var nativeStreamCodecText = ""
    @Published var controllerBatteries: [ControllerBatteryInfo] = []
    var batteryAlertTracker = ControllerBatteryAlertTracker()
    @Published var showingControllerMapping = false
    @Published var hudFocusID: String?
    var hudGamepadTracker = StreamHUDGamepadTracker()
    @Published var streamControlsFocusIndex = 0
    @Published var onScreenKeyboardVisible = false
    var restorePointerLockOnKeyboardHide = false
    let onScreenKeyboard = StreamOnScreenKeyboardController()

    func startIfNeeded() {
        guard startTask == nil, path == nil, !didEnd else { return }
        guard let nativeView, Self.nativeVideoSurfaceHandle(for: nativeView) != nil else {
            loadingStepIndex = StreamLaunchStep.checkNetworkRoute.rawValue
            return
        }
        nativeView.remoteInputEnabled = false
        nativeView.setNativeNVSTVideoVisible(false)
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: capabilities)
        let resolvedStreamSettings = WebRTCMediaStreamSettingsResolver.resolve(
            profile: webRTCMediaProfile(from: profile),
            capabilities: webRTCMediaCapabilities(from: capabilities),
            cloudVariables: webRTCMediaCloudVariables(from: OPNStreamPreferences.loadCachedCloudVariables())
        )
        microphoneMode = profile.microphoneMode.lowercased()
        let microphoneConfiguration = NativeNVSTMicrophoneConfiguration.settings(volume: profile.microphoneVolume, mode: microphoneMode)
        microphoneAvailable = microphoneConfiguration.captureRequested
        microphoneEnabled = microphoneConfiguration.initiallyEnabled
        microphoneDesiredEnabled = microphoneEnabled
        microphonePendingStates.removeAll()
        let initialMicrophoneEnabled = microphoneEnabled
        antiAFKMouseMovementEnabled = profile.antiAFKMouseMovementEnabled
        networkGovernor = NativeNVSTNetworkGovernor(maximumBitrateKbps: UInt32(resolvedStreamSettings.maxBitrateMbps * 1_000), l4sEnabled: resolvedStreamSettings.enableL4S)
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        lastAcceptedStreamInputAt = Date()
        beginStreamingPerformanceMode()
        startNetworkPathMonitoring()
        // Experimental: OpenNOW's own session core (Phase 2) replaces the Geronimo
        // transport when enabled. Geronimo/SDL2 are not loaded; video frames are counted but
        // not decoded until Phase 2C, so the surface stays blank while HUD and input work.
        // Bifrost-free (no NVIDIA libraries): our own RTSP control plane + raw-SRTP Mjolnir
        // receiver + VideoToolbox decode, drawn on the shared Metal surface. Input/audio still
        // need the ICE/DTLS bundle, so this stays opt-in until that lands.
        let bifrostFreeSink = nativeView.attachNvstBifrostFreeRenderer(targetFps: Int32(max(30, resolvedStreamSettings.fps))).frameSink
        // The only transport. The vendored NVIDIA path has been removed; there is no fallback, so
        // a failure surfaces as a failed stream instead of silently using the old libraries.
        // The unified log purges info-level lines within minutes, which has already cost one
        // session's counter timeline mid-investigation; the diagnostic file is the durable copy.
        let diagnosticLog = NvstDiagnosticLog()
        if let logURL = diagnosticLog.url {
            WebRTCMediaTelemetry.capture("nvst.bifrost_free", level: .info,
                                         message: "NVST diagnostic log at \(logURL.path)")
        }
        let transport: any NativeNVSTTransport = NvstBifrostFreeTransport(
            pixelBufferSink: { pixelBuffer, presentationTime, isKeyframe in
                bifrostFreeSink.render(pixelBuffer: pixelBuffer, presentationTime: presentationTime, isKeyframe: isKeyframe)
            },
            configuredFps: resolvedStreamSettings.fps,
            configuredMaxBitrateKbps: resolvedStreamSettings.maxBitrateMbps * 1_000,
            configuredPrefilterMode: resolvedStreamSettings.prefilterMode,
            configuredPrefilterSharpness: resolvedStreamSettings.prefilterSharpness,
            configuredPrefilterDenoise: resolvedStreamSettings.prefilterDenoise,
            configuredPrefilterModel: resolvedStreamSettings.prefilterModel,
            logger: { message in
                WebRTCMediaTelemetry.capture("nvst.bifrost_free", level: .info, message: message)
                diagnosticLog.append(message)
            }
        )
        // Match the local pointer to the game's: the seat stops compositing its own cursor as soon
        // as it starts publishing cursor state, so from then on the only pointer is ours and it has
        // to appear and disappear when the game's does.
        if let bifrostFree = transport as? NvstBifrostFreeTransport {
            Task {
                await bifrostFree.setRemoteCursorVisibilityHandler { [weak nativeView] isVisible in
                    nativeView?.setRemoteCursorVisible(isVisible)
                }
            }
        }
        let path = NativeNVSTStreamingPath(sessionProvider: sessionProvider, transport: transport, automaticRecovery: .singleAttempt)
        let inputDispatcher = NativeNVSTInputDispatcher { input in
            switch input {
            case .event(let event):
                try? await path.send(event)
            case .absoluteMove(let event):
                try? await path.sendAbsoluteMouseMove(event)
            }
        }
        self.path = path
        self.inputDispatcher = inputDispatcher
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
            // Both handlers land in `WebRTCMediaStreamLifecycle`'s static dictionaries, so both
            // capture weakly: as a struct these closures held a value copy and retained nothing, but
            // this class owns the Metal surface, the transport and five unbounded tasks.
            //
            // Returning `false` when `self` is gone is load-bearing, not a formality. `true` makes
            // `applicationShouldTerminate` answer `.terminateLater` and wait for a `completion` that
            // a deallocated model can never call - the app would refuse to quit, permanently, with
            // no way out but force-quit.
            quitRequestHandler: { [weak self] completion in
                guard let self else { return false }
                self.showStreamControls(completion: completion)
                return true
            },
            commandHandler: { [weak self] command in self?.handleNativeCommand(command) }
        )
        startTask = Task {
            do {
                try await path.setMicrophoneConfiguration(microphoneConfiguration)
                let session = try await path.start(configuration: configuration) { progress in
                    await MainActor.run {
                        self.loadingStepIndex = progress.currentStepIndex
                        self.onProgress?(progress)
                    }
                }
                do {
                    try await path.setMicrophoneEnabled(initialMicrophoneEnabled)
                } catch {
                    await MainActor.run {
                        microphoneEnabled = false
                        microphoneDesiredEnabled = false
                        WebRTCMediaTelemetry.capture("nvst.microphone.initialization.failed", level: .error, message: Self.message(for: error), attributes: ["applicationID": configuration.applicationID])
                    }
                }
                let shouldPresentStream = await MainActor.run {
                    guard !Task.isCancelled, !didEnd, !isEnding else { return false }
                    isConnected = true
                    sessionLimit = StreamSessionSidebarLimit(session: session)
                    nativeView.remoteInputEnabled = !unifiedHUDVisible && !streamControlsVisible
                    nativeView.setNativeNVSTVideoVisible(true)
                    nativeView.restoreInputFocus()
                    Task { try? await path.updateGamepadTopology(nativeView.gamepadTopology) }
                    loadingStepIndex = StreamLaunchStep.connected.rawValue
                    startNativeStatsPolling(path: path)
                    refreshAntiAFKMouseMovementTask()
                    let launchProfile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
                    pillarboxFillModeIndex = launchProfile.pillarboxFillModeIndex
                    nativeView.setPillarboxFill(mode: launchProfile.pillarboxFillModeIndex, dim: launchProfile.pillarboxFillDim)
                    upscalingModeIndex = launchProfile.upscalingModeIndex
                    upscalingTargetIndex = launchProfile.upscalingTargetIndex
                    upscalingSharpness = launchProfile.upscalingSharpness
                    upscalingDenoise = launchProfile.upscalingDenoise
                    nativeStreamResolutionText = "\(launchProfile.resolution.width) x \(launchProfile.resolution.height)"
                    nativeStreamFrameRateText = "\(launchProfile.fps) FPS"
                    nativeStreamCodecText = launchProfile.codec.value.uppercased()
                    nativeView.setVideoEnhancement(mode: launchProfile.upscalingMode,
                                                   sharpness: launchProfile.upscalingSharpness,
                                                   denoise: launchProfile.upscalingDenoise,
                                                   targetHeight: launchProfile.upscalingTargetHeight)
                    onProgress?(StreamProgress(configuration: configuration, step: .connected, message: "Connected over native NVST.", isReady: true))
                    WebRTCMediaTelemetry.capture("nvst.ui.connected", level: .info, message: "Native NVST stream connected.", attributes: ["sessionId": session.id])
                    return true
                }
                if !shouldPresentStream {
                    _ = try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed during startup.")
                }
            } catch {
                let diagnostics = await path.diagnosticMetadata()
                await MainActor.run { handleStartFailure(error, diagnostics: diagnostics) }
            }
        }
    }

    func handleStartFailure(_ error: Error, diagnostics: [String: String]) {
        guard !(error is CancellationError), !Task.isCancelled else {
            loadingStepIndex = -1
            endStreamingPerformanceMode()
            return
        }
        let message = Self.message(for: error)
        isConnected = false
        nativeView?.remoteInputEnabled = false
        nativeView?.stopHaptics()
        nativeView?.setPointerLocked(false)
        inputDispatcher?.cancel()
        inputDispatcher = nil
        endStreamingPerformanceMode()
        var metadata = ["applicationID": configuration.applicationID, "transport": "nvst"]
        metadata.merge(diagnostics) { current, _ in current }
        if let sessionError = error as? OpenNOWStreamSessionError, case .activeSessionConflict(let conflict) = sessionError {
            metadata.merge(conflict.reportMetadata) { current, _ in current }
        }
        finishOnce(report: StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: metadata))
    }

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
                await inputDispatcher?.finish()
                try? await path.setMicrophoneEnabled(false)
                _ = try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed.")
            }
        } else {
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
        nativeView?.remoteInputEnabled = false
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

    func configureNativeView(_ view: NativeWebRTCStreamView) {
        guard !didEnd, !isEnding else {
            view.remoteInputEnabled = false
            view.setNativeNVSTVideoVisible(false)
            return
        }
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        view.directMouseInputEnabled = profile.directMouseInput
        view.locksPointerWhenRelativeModeSelected = true
        view.confinesCursorToWindowInAbsoluteMode = profile.directMouseInput
        view.hidesCursorWhilePointerLocked = true
        view.onPointerLockChanged = { [weak self] locked in self?.pointerLocked = locked }
        if path == nil { view.mouseInputMode = .absolute }
        view.setStreamContentSize(width: profile.resolution.width, height: profile.resolution.height)
        view.remoteInputEnabled = isConnected && !unifiedHUDVisible && !streamControlsVisible
        let pushToTalkEnabled = profile.microphoneMode.caseInsensitiveCompare("push-to-talk") == .orderedSame
        view.configurePushToTalk(
            keyCode: pushToTalkEnabled ? profile.microphonePushToTalkKeyCode : nil,
            modifierMask: profile.microphonePushToTalkModifierMask
        ) { [weak self] enabled in
            self?.requestNativeMicrophoneEnabled(enabled, source: "push-to-talk")
        }
        configureInput(for: view)
    }

    /// Every callback below is stored *on the view*, and the view model holds the view - so each one
    /// captures `self` weakly. As `@State` on a struct this was not a cycle; as a class it would be,
    /// and the session would never deallocate.
    func configureInput(for view: NativeWebRTCStreamView) {
        view.onInputEvent = { [weak self, weak view] event in
            guard let self else { return }
            if self.onScreenKeyboardVisible, !self.isEnding, !self.didEnd, case .gamepad(let state) = event {
                self.onScreenKeyboard.handleGamepadState(state)
                if self.isConnected {
                    self.inputDispatcher?.enqueue(.gamepad(GamepadState(deviceID: state.deviceID, playerIndex: state.playerIndex, timestamp: state.timestamp)))
                }
                return
            }
            guard self.path != nil, let view, self.isConnected, !self.unifiedHUDVisible, !self.streamControlsVisible, !self.isEnding, !self.didEnd else { return }
            if view.remoteInputEnabled && !NativeNVSTInputDispatcher.isNeutralizing(event) {
                guard NSApplication.shared.isActive, view.window?.isKeyWindow == true else { return }
            }
            self.lastAcceptedStreamInputAt = Date()
            if case .mouse = event {
                if view.mouseInputMode == .relative, !view.isPointerLocked { return }
                self.inputDispatcher?.enqueue(event)
                return
            }
            self.inputDispatcher?.enqueue(event)
        }
        view.shouldHandleCommand = { [weak self] _ in
            self?.isConnected ?? false
        }
        view.onCommand = { [weak self] command in
            self?.handleNativeCommand(command)
        }
        view.onAbsoluteMouseMove = { [weak self, weak view] event in
            guard let self, let view else { return }
            guard self.isConnected, !self.unifiedHUDVisible, !self.streamControlsVisible, !self.isEnding, !self.didEnd,
                  view.remoteInputEnabled, view.mouseInputMode == .absolute else { return }
            guard view.isEmittingNeutralizingAbsolutePosition ||
                    (NSApplication.shared.isActive && view.window?.isKeyWindow == true) else { return }
            self.lastAcceptedStreamInputAt = Date()
            self.inputDispatcher?.enqueueAbsoluteMove(event)
        }
        view.onGamepadTopologyChanged = { [weak self] topology in
            guard let self, let path = self.path, self.isConnected, !self.isEnding, !self.didEnd else { return }
            Task { try? await path.updateGamepadTopology(topology) }
        }
        view.onScreenKeyboardCapture = { [weak self] deviceID, snapshot in
            guard let self, self.onScreenKeyboardVisible else { return false }
            self.onScreenKeyboard.handleSteamSnapshot(deviceID: deviceID, snapshot: snapshot)
            return true
        }
        onScreenKeyboard.onOutput = { [weak self] output in
            self?.sendOnScreenKeyboardOutput(output)
        }
        onScreenKeyboard.onDismiss = { [weak self] in
            self?.setOnScreenKeyboardVisible(false)
        }
        view.onLocalGamepadState = { [weak self] state in
            guard let self, !self.isEnding, !self.didEnd, !self.showingControllerMapping else { return }
            if self.streamControlsVisible {
                self.handleStreamControlsGamepad(state)
            } else if self.unifiedHUDVisible {
                self.handleHUDGamepad(state)
            }
        }
    }
}
