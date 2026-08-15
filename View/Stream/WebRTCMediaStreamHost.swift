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
    @State private var statsTogglePending = false
    @State private var statsToggleTask: Task<Void, Never>?
    @State private var pendingApplicationQuitCompletion: WebRTCMediaStreamQuitDecisionHandler?
    @State private var streamingPerformanceActivity: (any NSObjectProtocol)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativeNVSTStreamHostView(
                overlay: AnyView(nativeWindowOverlay),
                overlayVisible: unifiedHUDVisible || streamControlsVisible
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
        beginStreamingPerformanceMode()
        let transport = NativeNVSTBifrostTransport(
            nativeVideoSurfaceHandle: nativeVideoSurfaceHandle,
            prepareVideoSurfaceForShutdown: {
                nativeView.prepareNativeNVSTRendererForShutdown()
            }
        )
        let path = NativeNVSTStreamingPath(sessionProvider: sessionProvider, transport: transport)
        self.path = path
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
                    nativeView.remoteInputEnabled = !unifiedHUDVisible && !streamControlsVisible
                    nativeView.setNativeNVSTVideoVisible(true)
                    nativeView.restoreInputFocus()
                    statusMessage = "Connected over native NVST."
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
        statsToggleTask?.cancel()
        statsToggleTask = nil
        statsTogglePending = false
        endStreamingPerformanceMode()
        nativeView?.remoteInputEnabled = false
        isConnected = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        nativeView?.setNativeNVSTVideoVisible(false)
        guard !didEnd else { return }
        didEnd = true
        nativeView?.onInputEvent = nil
        nativeView?.onPointerLockChanged = nil
        nativeView?.onCommand = nil
        nativeView?.shouldHandleCommand = nil
        if let path {
            Task { try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed.") }
        }
    }

    private func finish(reason: StreamEndReason, message: String) async -> Bool {
        guard !isEnding else { return false }
        await MainActor.run {
            nativeView?.remoteInputEnabled = false
            nativeView?.setNativeNVSTVideoVisible(false)
            isEnding = true
        }
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
        didEnd = true
        isConnected = false
        unifiedHUDVisible = false
        streamControlsVisible = false
        nativeStatsVisible = false
        statsToggleTask?.cancel()
        statsToggleTask = nil
        statsTogglePending = false
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        nativeView?.remoteInputEnabled = false
        nativeView?.setPointerLocked(false)
        nativeView?.setNativeNVSTVideoVisible(false)
        endEventTask?.cancel()
        endEventTask = nil
        nativeView?.onInputEvent = nil
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
        view.hidesCursorWhilePointerLocked = false
        view.setStreamContentSize(width: profile.resolution.width, height: profile.resolution.height)
        view.remoteInputEnabled = isConnected && !unifiedHUDVisible && !streamControlsVisible
        configureInput(for: view)
    }

    private func configureInput(for view: NativeWebRTCStreamView) {
        view.onInputEvent = { [path, weak view] event in
            guard let path, let view, isConnected, !unifiedHUDVisible, !streamControlsVisible, !isEnding, !didEnd else { return }
            if view.remoteInputEnabled {
                guard NSApplication.shared.isActive, view.window?.isKeyWindow == true else { return }
            }
            Task { try? await path.send(event) }
        }
        view.shouldHandleCommand = { command in
            guard isConnected else { return false }
            return switch command {
            case .toggleStatsHUD, .toggleUnifiedHUD, .toggleMicrophone, .showQuitMenu:
                true
            default:
                false
            }
        }
        view.onCommand = { command in
            handleNativeCommand(command)
        }
    }

    private func handleNativeCommand(_ command: WebRTCMediaStreamCommand) {
        switch command {
        case .toggleStatsHUD, .toggleMicrophone:
            toggleNativeStatsHUD()
        case .toggleUnifiedHUD:
            guard !streamControlsVisible else { return }
            setUnifiedHUDVisible(!unifiedHUDVisible)
        case .showQuitMenu:
            if !streamControlsVisible { showStreamControls() }
        default:
            break
        }
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
        unifiedHUDVisible = visible
        nativeView?.remoteInputEnabled = !visible
        if !visible {
            nativeView?.restoreInputFocus()
        }
        WebRTCMediaTelemetry.capture("nvst.ui.hud.toggle", level: .info, message: visible ? "Native NVST HUD shown." : "Native NVST HUD hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(visible)])
    }

    private func toggleNativeStatsHUD() {
        guard isConnected, !statsTogglePending, let path else { return }
        statsTogglePending = true
        statsToggleTask = Task {
            do {
                try await path.togglePerformanceOverlay()
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    defer {
                        statsTogglePending = false
                        statsToggleTask = nil
                    }
                    guard isConnected, !isEnding, !didEnd else { return }
                    nativeStatsVisible.toggle()
                    WebRTCMediaTelemetry.capture("nvst.ui.stats.toggle", level: .info, message: nativeStatsVisible ? "Native NVST stats shown." : "Native NVST stats hidden.", attributes: ["applicationID": configuration.applicationID, "visible": String(nativeStatsVisible)])
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    defer {
                        statsTogglePending = false
                        statsToggleTask = nil
                    }
                    guard isConnected, !isEnding, !didEnd else { return }
                    WebRTCMediaTelemetry.capture("nvst.ui.stats.failed", level: .error, message: Self.message(for: error), attributes: ["applicationID": configuration.applicationID])
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
            if unifiedHUDVisible { nativeUnifiedHUD }
            if streamControlsVisible { nativeStreamControlsOverlay }
        }
    }

    private var nativeUnifiedHUD: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                nativeHUDHeader
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        nativeHUDStatusPanel
                        nativeHUDControlsPanel
                        nativeHUDStreamPanel
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                Text("Cmd+G HUD   Cmd+M Stats   Cmd+Q Quit")
                    .font(.streamNvidia(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
            }
            .frame(width: WebRTCMediaStreamTheme.dockWidth(for: proxy.size.width), height: proxy.size.height, alignment: .topLeading)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.985))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(width: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.accent)
                    .frame(height: 2)
            }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 14, y: 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private var nativeHUDHeader: some View {
        HStack(spacing: 10) {
            Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                .font(.streamNvidia(size: 12, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Button(action: { setUnifiedHUDVisible(false) }) {
                Image(systemName: "xmark")
                    .font(.streamNvidia(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close stream HUD")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(WebRTCMediaStreamTheme.appBar)
    }

    private var nativeHUDStatusPanel: some View {
        HStack(spacing: 8) {
            nativeHUDMetricCard(title: "Stream", value: isConnected ? "Live" : "Starting", positive: isConnected)
            nativeHUDMetricCard(title: "Transport", value: "NVST", positive: isConnected)
            nativeHUDMetricCard(title: "Stats", value: nativeStatsVisible ? "On" : "Off", positive: nativeStatsVisible)
        }
    }

    private var nativeHUDControlsPanel: some View {
        nativeHUDSection(label: "CONTROLS") {
            HStack(spacing: 8) {
                StreamHUDActionRow(
                    title: nativeStatsVisible ? "Hide Floating Stats" : "Show Floating Stats",
                    subtitle: "Geronimo performance overlay",
                    systemName: "chart.line.uptrend.xyaxis",
                    isActive: nativeStatsVisible,
                    isDisabled: statsTogglePending,
                    action: toggleNativeStatsHUD
                )
                StreamHUDActionRow(
                    title: "Stream Controls",
                    subtitle: "Pause or end this stream",
                    systemName: "power",
                    isActive: false,
                    isDisabled: isEnding,
                    action: { showStreamControls() }
                )
            }
        }
    }

    private var nativeHUDStreamPanel: some View {
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: OPNStreamPreferences.loadDeviceCapabilities())
        return nativeHUDSection(label: "STREAM") {
            VStack(alignment: .leading, spacing: 8) {
                nativeHUDDetailRow(label: "Resolution", value: "\(profile.resolution.width) x \(profile.resolution.height)")
                nativeHUDDetailRow(label: "Frame Rate", value: "\(profile.fps) FPS")
                nativeHUDDetailRow(label: "Codec", value: profile.codec.value.uppercased())
                nativeHUDDetailRow(label: "Input", value: unifiedHUDVisible ? "Paused for HUD" : "Active")
            }
        }
    }

    private func nativeHUDSection<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.streamNvidia(size: 9, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            content()
        }
        .padding(12)
        .background(WebRTCMediaStreamTheme.surfaceRaised)
        .overlay(Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1))
    }

    private func nativeHUDMetricCard(title: String, value: String, positive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.streamNvidia(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Text(value)
                .font(.streamNvidia(size: 12, weight: .bold))
                .foregroundStyle(positive ? WebRTCMediaStreamTheme.accentSoft : WebRTCMediaStreamTheme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(WebRTCMediaStreamTheme.surfaceRaised)
        .overlay(Rectangle().stroke(positive ? WebRTCMediaStreamTheme.accent.opacity(0.30) : WebRTCMediaStreamTheme.divider, lineWidth: 1))
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
                Text("Cmd+G HUD  |  Cmd+M stats  |  Cmd+Q menu  |  Esc resume")
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
    let onResolve: @MainActor (NativeWebRTCStreamView) -> Void

    func makeNSView(context: Context) -> NativeNVSTContainerView {
        let view = NativeNVSTContainerView(frame: .zero)
        view.onResolve = { streamView in
            Task { @MainActor in onResolve(streamView) }
        }
        view.updateOverlay(overlay, visible: overlayVisible)
        return view
    }

    func updateNSView(_ nsView: NativeNVSTContainerView, context: Context) {
        nsView.updateOverlay(overlay, visible: overlayVisible)
    }

    final class NativeNVSTContainerView: NSView {
        let streamView = NativeWebRTCStreamView(frame: .zero)
        private let overlayView = NSHostingView(rootView: AnyView(EmptyView()))
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

        func updateOverlay(_ overlay: AnyView, visible: Bool) {
            overlayView.rootView = overlay
            overlayView.isHidden = !visible
            if visible { NSCursor.arrow.set() }
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
