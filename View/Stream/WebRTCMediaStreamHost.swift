//  OpenNOW
//
//  Created by OpenCode on 6/16/26.
//

import Foundation
import SwiftUI

typealias WebRTCMediaStreamCompletion = WebRTCMediaStreamEndCallback
typealias WebRTCMediaStreamProgressHandler = WebRTCMediaStreamProgressCallback

enum StreamLaunchLoadingStage {
    static func label(stepIndex: Int, queuePosition: Int? = nil) -> String {
        if let queuePosition, queuePosition > 0 { return "Waiting in queue" }
        switch stepIndex {
        case StreamLaunchStep.checkNetworkRoute.rawValue: return "Checking connection"
        case StreamLaunchStep.allocateCloudSession.rawValue: return "Finding a server"
        case StreamLaunchStep.receiveStreamOffer.rawValue: return "Preparing stream"
        case StreamLaunchStep.negotiateWebRTC.rawValue: return "Connecting"
        case StreamLaunchStep.connected.rawValue: return "Ready"
        default: return "Starting"
        }
    }
}

extension StreamLaunchConfiguration {
    var loadingArtworkURL: URL? {
        let urls = (metadata["loadingScreenshotUrls"] ?? "")
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !urls.isEmpty else { return nil }
        let seed = id.uuidString.utf8.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1) }
        return URL(string: urls[Int(seed % UInt(urls.count))])
    }
}

struct StreamLaunchLoadingScreen<Accessory: View>: View {
    let title: String
    let stage: String
    let artworkURL: URL?
    let queuePosition: Int?
    let accessoryPresented: Bool
    let cancelAction: (() -> Void)?
    private let accessory: Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String,
         stage: String,
         artworkURL: URL?,
         queuePosition: Int? = nil,
         accessoryPresented: Bool = false,
         cancelAction: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title.isEmpty ? "GeForce NOW" : title
        self.stage = stage
        self.artworkURL = artworkURL
        self.queuePosition = queuePosition
        self.accessoryPresented = accessoryPresented
        self.cancelAction = cancelAction
        self.accessory = accessory()
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = min(proxy.size.width, proxy.size.height) < 620
            ZStack {
                Color.black

                if let artworkURL {
                    AsyncImage(url: artworkURL) { phase in
                        if case .success(let image) = phase {
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        }
                    }
                }

                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.54), location: 0),
                        .init(color: .black.opacity(0.20), location: 0.42),
                        .init(color: .black.opacity(0.78), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                RadialGradient(
                    colors: [Color.openNowGreen.opacity(0.18), .clear],
                    center: .center,
                    startRadius: 12,
                    endRadius: compact ? 260 : 480
                )
                .blendMode(.screen)

                VStack(spacing: compact ? 16 : 22) {
                    Spacer(minLength: 24)

                    if accessoryPresented {
                        accessory
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .frame(maxWidth: 920, maxHeight: compact ? 300 : 520)
                    } else {
                        StreamLaunchSignal(reduceMotion: reduceMotion)
                            .frame(width: compact ? 68 : 84, height: compact ? 68 : 84)
                    }

                    VStack(spacing: 8) {
                        Text(title)
                            .font(.nvidia(size: compact ? 24 : 32, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        HStack(spacing: 8) {
                            Circle()
                                .fill(Color.openNowGreen)
                                .frame(width: 6, height: 6)
                                .shadow(color: Color.openNowGreen, radius: 6)
                            Text(stage.uppercased())
                                .font(.nvidia(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }

                    if let queuePosition, queuePosition > 0 {
                        Text("Position \(queuePosition)")
                            .font(.nvidia(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(.black.opacity(0.48), in: Capsule())
                            .overlay(Capsule().stroke(Color.openNowGreen.opacity(0.38), lineWidth: 1))
                    }

                    if let cancelAction {
                        Button("Cancel", action: cancelAction)
                            .font(.nvidia(size: 12, weight: .bold))
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(0.68))
                            .padding(.horizontal, 18)
                            .frame(height: 34)
                            .overlay(Capsule().stroke(.white.opacity(0.20), lineWidth: 1))
                            .accessibilityLabel("Cancel stream launch")
                    }

                    Spacer(minLength: 24)

                    if !accessoryPresented {
                        VendorIndeterminateProgressBar()
                            .frame(width: compact ? 190 : 280, height: 3)
                            .padding(.bottom, compact ? 22 : 34)
                    }
                }
                .padding(.horizontal, compact ? 22 : 40)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .background(.black)
    }
}

private struct StreamLaunchSignal: View {
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation) { timeline in
            let cycle = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
            let rotation = reduceMotion ? 0 : cycle * 360
            ZStack {
                Circle()
                    .fill(Color.openNowGreen.opacity(0.12))
                    .blur(radius: 14)
                Circle()
                    .stroke(.white.opacity(0.15), lineWidth: 1)
                Circle()
                    .trim(from: 0.06, to: 0.70)
                    .stroke(Color.openNowGreen, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(rotation))
                Circle()
                    .trim(from: 0.12, to: 0.42)
                    .stroke(.white.opacity(0.64), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                    .padding(9)
                    .rotationEffect(.degrees(-rotation * 0.72))
                Circle()
                    .fill(Color.openNowGreen)
                    .frame(width: 8, height: 8)
                    .shadow(color: Color.openNowGreen, radius: 8)
            }
        }
    }
}

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
    @State private var loadingStepIndex = -1
    @State private var isConnected = false
    @State private var isEnding = false
    @State private var didEnd = false
    @State private var unifiedHUDVisible = false
    @State private var streamControlsVisible = false
    @State private var nativeStatsVisible = false
    @State private var latestNativeStats: NativeNVSTPerformanceSnapshot?
    @State private var nativeStatsTask: Task<Void, Never>?
    @State private var nativeStreamHealth = NativeNVSTStreamHealthMonitor()
    @State private var inputDispatcher: NativeNVSTInputDispatcher?
    @State private var microphoneAvailable = false
    @State private var microphoneEnabled = false
    @State private var microphoneDesiredEnabled = false
    @State private var microphoneMode = "disabled"
    @State private var microphonePendingStates: [Bool] = []
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
    @State private var networkGovernor: NativeNVSTNetworkGovernor?
    @State private var networkPathTask: Task<Void, Never>?
    @State private var networkPathAvailable = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            NativeNVSTStreamHostView { view in
                nativeView = view
                configureNativeView(view)
                startIfNeeded()
            }
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            nativeWindowOverlay
            if !isConnected {
                StreamLaunchLoadingScreen(
                    title: configuration.title,
                    stage: StreamLaunchLoadingStage.label(stepIndex: loadingStepIndex),
                    artworkURL: configuration.loadingArtworkURL
                ) { EmptyView() }
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
            loadingStepIndex = StreamLaunchStep.checkNetworkRoute.rawValue
            return
        }
        nativeView.remoteInputEnabled = false
        nativeView.setNativeNVSTVideoVisible(false)
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        microphoneMode = profile.microphoneMode.lowercased()
        let microphoneConfiguration = NativeNVSTMicrophoneConfiguration.settings(volume: profile.microphoneVolume, mode: microphoneMode)
        microphoneAvailable = microphoneConfiguration.captureRequested
        microphoneEnabled = microphoneConfiguration.initiallyEnabled
        microphoneDesiredEnabled = microphoneEnabled
        microphonePendingStates.removeAll()
        let initialMicrophoneEnabled = microphoneEnabled
        antiAFKMouseMovementEnabled = profile.antiAFKMouseMovementEnabled
        networkGovernor = NativeNVSTNetworkGovernor(maximumBitrateKbps: UInt32(max(1, profile.maxBitrateMbps) * 1_000), l4sEnabled: profile.enableL4S)
        nativeStreamHealth = NativeNVSTStreamHealthMonitor()
        lastAcceptedStreamInputAt = Date()
        beginStreamingPerformanceMode()
        startNetworkPathMonitoring()
        let transport = NativeNVSTBifrostTransport(
            nativeVideoSurfaceHandle: nativeVideoSurfaceHandle,
            cursorVisibilityHandler: { [weak nativeView] visible in
                guard let nativeView else { return }
                nativeView.mouseInputMode = visible || !nativeView.directMouseInputEnabled ? .absolute : .relative
            },
            prepareVideoSurfaceForShutdown: {
                nativeView.prepareNativeNVSTRendererForShutdown()
            },
            restoreVideoSurfaceAfterRecovery: {
                nativeView.setNativeNVSTVideoVisible(true)
            },
            hapticHandler: { [weak nativeView] command in
                nativeView?.playHaptic(command)
            },
            hapticResetHandler: { [weak nativeView] in
                nativeView?.stopHaptics()
            }
        )
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
            quitRequestHandler: { completion in
                showStreamControls(completion: completion)
                return true
            },
            commandHandler: handleNativeCommand
        )
        startTask = Task {
            do {
                try await path.setMicrophoneConfiguration(microphoneConfiguration)
                let session = try await path.start(configuration: configuration) { progress in
                    await MainActor.run {
                        loadingStepIndex = progress.currentStepIndex
                        onProgress?(progress)
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

    private func handleStartFailure(_ error: Error, diagnostics: [String: String]) {
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
        nativeView?.setNativeNVSTVideoVisible(false)
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
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        microphoneAvailable = false
        microphoneEnabled = false
        microphoneDesiredEnabled = false
        microphoneMode = "disabled"
        microphonePendingStates.removeAll()
        antiAFKMouseMovementEnabled = false
        nativeView?.stopHaptics()
        nativeView?.setNativeNVSTVideoVisible(false)
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

    private func finish(reason: StreamEndReason, message: String) async -> Bool {
        guard !isEnding else { return false }
        let inputDispatcher = await MainActor.run {
            nativeView?.remoteInputEnabled = false
            nativeView?.setNativeNVSTVideoVisible(false)
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

    private func finishOnce(report: StreamReport) {
        guard !didEnd else { return }
        nativeView?.remoteInputEnabled = false
        inputDispatcher?.cancel()
        inputDispatcher = nil
        didEnd = true
        isConnected = false
        unifiedHUDVisible = false
        streamControlsVisible = false
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

    private func configureNativeView(_ view: NativeWebRTCStreamView) {
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
        if path == nil { view.mouseInputMode = .absolute }
        view.setStreamContentSize(width: profile.resolution.width, height: profile.resolution.height)
        view.remoteInputEnabled = isConnected && !unifiedHUDVisible && !streamControlsVisible
        let pushToTalkEnabled = profile.microphoneMode.caseInsensitiveCompare("push-to-talk") == .orderedSame
        view.configurePushToTalk(
            keyCode: pushToTalkEnabled ? profile.microphonePushToTalkKeyCode : nil,
            modifierMask: profile.microphonePushToTalkModifierMask
        ) { enabled in
            requestNativeMicrophoneEnabled(enabled, source: "push-to-talk")
        }
        configureInput(for: view)
    }

    private func configureInput(for view: NativeWebRTCStreamView) {
        view.onInputEvent = { [weak view] event in
            guard path != nil, let view, isConnected, !unifiedHUDVisible, !streamControlsVisible, !isEnding, !didEnd else { return }
            if view.remoteInputEnabled && !NativeNVSTInputDispatcher.isNeutralizing(event) {
                guard NSApplication.shared.isActive, view.window?.isKeyWindow == true else { return }
            }
            lastAcceptedStreamInputAt = Date()
            if case .mouse = event {
                if view.mouseInputMode == .relative, !view.isPointerLocked { return }
                inputDispatcher?.enqueue(event)
                return
            }
            inputDispatcher?.enqueue(event)
        }
        view.shouldHandleCommand = { _ in
            isConnected
        }
        view.onCommand = { command in
            handleNativeCommand(command)
        }
        view.onAbsoluteMouseMove = { event in
            guard isConnected, !unifiedHUDVisible, !streamControlsVisible, !isEnding, !didEnd,
                  view.remoteInputEnabled, view.mouseInputMode == .absolute else { return }
            guard view.isEmittingNeutralizingAbsolutePosition ||
                    (NSApplication.shared.isActive && view.window?.isKeyWindow == true) else { return }
            lastAcceptedStreamInputAt = Date()
            inputDispatcher?.enqueueAbsoluteMove(event)
        }
        view.onGamepadTopologyChanged = { topology in
            guard let path, isConnected, !isEnding, !didEnd else { return }
            Task { try? await path.updateGamepadTopology(topology) }
        }
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
            microphoneDesiredEnabled = false
            showNativeTransientStreamMessage("Microphone is disabled in Settings.")
            return
        }
        guard microphoneMode != "push-to-talk" else {
            showNativeTransientStreamMessage("Hold the configured Push-to-Talk key to speak.")
            return
        }
        requestNativeMicrophoneEnabled(!microphoneDesiredEnabled, source: "toggle")
    }

    private func requestNativeMicrophoneEnabled(_ enabled: Bool, source: String) {
        guard microphoneAvailable, isConnected, !isEnding, !didEnd, let path else { return }
        microphoneDesiredEnabled = enabled
        let lastScheduledState = microphonePendingStates.last ?? microphoneEnabled
        if lastScheduledState != enabled { microphonePendingStates.append(enabled) }
        guard microphoneUpdateTask == nil else { return }
        microphoneUpdateTask = Task { @MainActor in
            defer { microphoneUpdateTask = nil }
            while !Task.isCancelled, !didEnd, !microphonePendingStates.isEmpty {
                let target = microphonePendingStates.removeFirst()
                do {
                    try await path.setMicrophoneEnabled(target)
                    guard !Task.isCancelled, !didEnd else { return }
                    microphoneEnabled = target
                    let enabledMessage = microphoneMode == "voice-activity" ? "Voice Activity On" : "Microphone On"
                    showNativeTransientStreamMessage(target ? enabledMessage : "Microphone Muted")
                    WebRTCMediaTelemetry.capture("nvst.ui.microphone.update", level: .info, message: target ? "Native NVST microphone enabled." : "Native NVST microphone muted.", attributes: ["applicationID": configuration.applicationID, "enabled": String(target), "source": source])
                } catch {
                    guard !Task.isCancelled, !didEnd else { return }
                    microphoneDesiredEnabled = microphoneEnabled
                    microphonePendingStates.removeAll()
                    let message = Self.message(for: error)
                    showNativeTransientStreamMessage(message)
                    WebRTCMediaTelemetry.capture("nvst.ui.microphone.failed", level: .error, message: message, attributes: ["applicationID": configuration.applicationID, "source": source])
                }
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
        guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, !unifiedHUDVisible, !streamControlsVisible, inputDispatcher != nil else { return }
        guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
        let delta = StreamAntiAFKInputPolicy.randomMouseDelta()
        inputDispatcher?.enqueue(StreamAntiAFKInputPolicy.mouseMove(deltaX: delta.x, deltaY: delta.y))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard isConnected, antiAFKMouseMovementEnabled, !isEnding, !didEnd, !unifiedHUDVisible, !streamControlsVisible else { return }
            guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= StreamAntiAFKInputPolicy.idleThresholdSeconds else { return }
            inputDispatcher?.enqueue(StreamAntiAFKInputPolicy.mouseMove(deltaX: -delta.x, deltaY: -delta.y))
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
                let snapshot = await path.performanceSnapshot()
                if snapshot == nil {
                    nativeStreamHealth = NativeNVSTStreamHealthMonitor()
                }
                if let snapshot, isConnected, !isEnding, !didEnd {
                    latestNativeStats = snapshot
                    recordNativeNetworkTelemetry(snapshot)
                    let adjustments = networkGovernor?.evaluate(snapshot) ?? []
                    for adjustment in adjustments { await applyNativeNetworkAdjustment(adjustment, path: path) }
                }
                if isConnected, !isEnding, !didEnd,
                   let failure = nativeStreamHealth.observe(snapshot: snapshot, rendererReady: nativeView?.nativeNVSTRendererSurfaceReady == true) {
                    WebRTCMediaTelemetry.capture("nvst.stream.health.failed", level: .error, message: failure.message, attributes: ["applicationID": configuration.applicationID])
                    _ = await finish(reason: .failed, message: failure.message)
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func recordNativeNetworkTelemetry(_ snapshot: NativeNVSTPerformanceSnapshot) {
        let attributes = ["transport": "nvst", "applicationID": configuration.applicationID]
        if snapshot.latencyMilliseconds >= 0 { WebRTCMediaTelemetry.record("nvst.network.latency_ms", kind: .gauge, value: snapshot.latencyMilliseconds, unit: "millisecond", attributes: attributes) }
        if snapshot.jitterMilliseconds >= 0 { WebRTCMediaTelemetry.record("nvst.network.jitter_ms", kind: .gauge, value: snapshot.jitterMilliseconds, unit: "millisecond", attributes: attributes) }
        if snapshot.bitrateMegabitsPerSecond >= 0 { WebRTCMediaTelemetry.record("nvst.network.bitrate_mbps", kind: .gauge, value: snapshot.bitrateMegabitsPerSecond, unit: "megabit/second", attributes: attributes) }
        if snapshot.bandwidthUtilizationPercent >= 0 { WebRTCMediaTelemetry.record("nvst.network.bandwidth_utilization_percent", kind: .gauge, value: snapshot.bandwidthUtilizationPercent, unit: "percent", attributes: attributes) }
        WebRTCMediaTelemetry.record("nvst.network.packet_loss", kind: .gauge, value: Double(snapshot.packetLoss), unit: "packet", attributes: attributes)
        WebRTCMediaTelemetry.record("nvst.network.frame_loss", kind: .gauge, value: Double(snapshot.frameLoss), unit: "frame", attributes: attributes)
    }

    private func startNetworkPathMonitoring() {
        networkPathTask?.cancel()
        let monitor = NativeNVSTNetworkPathMonitor()
        networkPathTask = Task { @MainActor in
            for await networkPath in monitor.updates() {
                guard !Task.isCancelled, !didEnd else { return }
                if networkPath.isSatisfied {
                    networkPathAvailable = true
                    if isConnected, !unifiedHUDVisible, !streamControlsVisible { nativeView?.remoteInputEnabled = true }
                    WebRTCMediaTelemetry.capture("nvst.network.path.available", level: .info, message: "Native NVST network path is available.", attributes: ["wifi": String(networkPath.usesWiFi), "ethernet": String(networkPath.usesWiredEthernet), "expensive": String(networkPath.isExpensive), "constrained": String(networkPath.isConstrained)])
                } else {
                    networkPathAvailable = false
                    nativeView?.remoteInputEnabled = false
                    showNativeTransientStreamMessage("Network interrupted - waiting to reconnect")
                    WebRTCMediaTelemetry.capture("nvst.network.path.unavailable", level: .warning, message: "Native NVST network path is unavailable.")
                }
            }
        }
    }

    private func applyNativeNetworkAdjustment(_ adjustment: NativeNVSTNetworkAdjustment, path: NativeNVSTStreamingPath) async {
        do {
            switch adjustment {
            case .maximumBitrateKbps(let bitrate): try await path.setMaximumBitrateKbps(bitrate)
            case .dynamicStreamingMode(let mode): try await path.setDynamicStreamingMode(mode)
            case .l4sEnabled(let enabled): try await path.setL4SEnabled(enabled)
            }
            WebRTCMediaTelemetry.capture("nvst.network.adjustment", level: .info, message: "Applied native NVST network adjustment.", attributes: ["adjustment": String(describing: adjustment)])
        } catch {
            WebRTCMediaTelemetry.capture("nvst.network.adjustment.failed", level: .warning, message: Self.message(for: error), attributes: ["adjustment": String(describing: adjustment)])
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
            if nativeStatsVisible && !streamControlsVisible { nativeStatsHUD.allowsHitTesting(false) }
            if unifiedHUDVisible {
                ZStack {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
                        .onTapGesture {}
                    nativeUnifiedHUD
                }
            }
            if streamControlsVisible { nativeStreamControlsOverlay }
            if !networkPathAvailable && !streamControlsVisible { nativeNetworkRecoveryOverlay }
            if !transientStreamMessage.isEmpty { nativeTransientStreamMessageOverlay.allowsHitTesting(false) }
        }
    }

    private var nativeNetworkRecoveryOverlay: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(spacing: 14) {
                ProgressView().controlSize(.large).tint(WebRTCMediaStreamTheme.accent)
                Text("CONNECTION INTERRUPTED")
                    .font(.streamNvidia(size: 16, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(WebRTCMediaStreamTheme.accent)
                Text("Waiting for a usable network path. OpenNOW will resume the same GeForce NOW session automatically.")
                    .font(.streamNvidia(size: 12, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("End Stream", action: endFromStreamControls)
                    .buttonStyle(.bordered)
            }
            .padding(30)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.96))
            .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.4), lineWidth: 1))
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
        if microphoneMode == "push-to-talk" { return microphoneEnabled ? "PTT Active" : "PTT Ready" }
        if microphoneMode == "voice-activity", microphoneEnabled { return "Voice Activity" }
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
            Color.black.opacity(0.96).ignoresSafeArea(.container, edges: [.horizontal, .bottom])
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
    let onResolve: @MainActor (NativeWebRTCStreamView) -> Void

    func makeNSView(context: Context) -> NativeNVSTSurfaceContainerView {
        let view = NativeNVSTSurfaceContainerView(frame: .zero)
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NativeNVSTSurfaceContainerView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveIfReady()
    }

    static func dismantleNSView(_ nsView: NativeNVSTSurfaceContainerView, coordinator: ()) {
        nsView.streamView.remoteInputEnabled = false
        nsView.streamView.setPointerLocked(false)
        nsView.streamView.onInputEvent = nil
        nsView.streamView.onAbsoluteMouseMove = nil
        nsView.streamView.onGamepadTopologyChanged = nil
        nsView.streamView.onPointerLockChanged = nil
        nsView.streamView.onCommand = nil
        nsView.streamView.shouldHandleCommand = nil
        nsView.onResolve = nil
    }

    final class NativeNVSTSurfaceContainerView: NSView {
        let streamView = NativeWebRTCStreamView(frame: .zero)
        var onResolve: (@MainActor (NativeWebRTCStreamView) -> Void)?
        private var didResolve = false

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            addSubview(streamView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveIfReady()
        }

        override func layout() {
            super.layout()
            streamView.frame = bounds
            resolveIfReady()
        }

        func resolveIfReady() {
            streamView.frame = bounds
            guard !didResolve, window != nil, bounds.width >= 1, bounds.height >= 1, let onResolve else { return }
            didResolve = true
            onResolve(streamView)
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
