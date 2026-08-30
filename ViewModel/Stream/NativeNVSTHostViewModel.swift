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
    @Published var recordingStatus = WebRTCStreamRecordingStatus.idle
    var recordingStatusResetTask: Task<Void, Never>?
    /// The settings the session actually started with, kept because the recording configuration is
    /// built from them (bitrates, fps, resolution) long after `prepareLaunch` returns.
    var resolvedStreamSettings: WebRTCMediaResolvedStreamSettings?
    @Published var streamControlsFocusIndex = 0
    @Published var onScreenKeyboardVisible = false
    var restorePointerLockOnKeyboardHide = false
    let onScreenKeyboard = StreamOnScreenKeyboardModel()

    func startIfNeeded() {
        guard startTask == nil, path == nil, !didEnd else { return }
        guard let nativeView, Self.nativeVideoSurfaceHandle(for: nativeView) != nil else {
            loadingStepIndex = StreamLaunchStep.checkNetworkRoute.rawValue
            return
        }
        let launch = prepareLaunch(nativeView: nativeView)
        let resolvedStreamSettings = launch.settings
        self.resolvedStreamSettings = resolvedStreamSettings
        let transport = makeTransport(nativeView: nativeView, settings: resolvedStreamSettings)
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
        runStartTask(path: path,
                     nativeView: nativeView,
                     microphoneConfiguration: launch.microphoneConfiguration,
                     initialMicrophoneEnabled: launch.microphoneConfiguration.initiallyEnabled)
    }

    /// Applies the saved launch profile to this model and returns what starting the stream needs.
    func prepareLaunch(nativeView: NativeWebRTCStreamView) -> (settings: WebRTCMediaResolvedStreamSettings, microphoneConfiguration: NativeNVSTMicrophoneConfiguration) {
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
        antiAFKMouseMovementEnabled = profile.antiAFKMouseMovementEnabled
        networkGovernor = NativeNVSTNetworkGovernor(maximumBitrateKbps: UInt32(resolvedStreamSettings.maxBitrateMbps * 1_000), l4sEnabled: resolvedStreamSettings.enableL4S)
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        lastAcceptedStreamInputAt = Date()
        beginStreamingPerformanceMode()
        startNetworkPathMonitoring()
        return (resolvedStreamSettings, microphoneConfiguration)
    }

    /// The only transport. The vendored NVIDIA path has been removed; there is no fallback, so a
    /// failure surfaces as a failed stream instead of silently using the old libraries.
    ///
    /// Bifrost-free (no NVIDIA libraries): our own RTSP control plane + raw-SRTP Mjolnir receiver +
    /// VideoToolbox decode, drawn on the shared Metal surface.
    func makeTransport(nativeView: NativeWebRTCStreamView, settings resolvedStreamSettings: WebRTCMediaResolvedStreamSettings) -> any NativeNVSTTransport {
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
        Task {
            await transport.setRecordingStatusHandler { [weak self] status in
                self?.handleRecordingStatusChanged(status)
            }
        }
        return transport
    }

    /// Drives the streaming path to a connected session, or reports why it did not get there.
    func runStartTask(path: NativeNVSTStreamingPath,
                              nativeView: NativeWebRTCStreamView,
                              microphoneConfiguration: NativeNVSTMicrophoneConfiguration,
                              initialMicrophoneEnabled: Bool) {
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
                    presentStream(session: session, path: path, nativeView: nativeView)
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

    /// Publishes an established session to the UI. False means the view went away while the stream
    /// was still coming up, and the caller stops the session instead.
    func presentStream(session: StreamSessionDescriptor, path: NativeNVSTStreamingPath, nativeView: NativeWebRTCStreamView) -> Bool {
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

}
