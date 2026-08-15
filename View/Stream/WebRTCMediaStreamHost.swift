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
    @State private var streamingPerformanceActivity: (any NSObjectProtocol)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativeNVSTStreamHostView { view in
                nativeView = view
                configureInput(for: view)
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
        beginStreamingPerformanceMode()
        let transport = NativeNVSTBifrostTransport(nativeVideoSurfaceHandle: nativeVideoSurfaceHandle)
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
                Task {
                    await finish(reason: .paused, message: "Native NVST stream paused before application exit.")
                    completion(true)
                }
                return true
            },
            commandHandler: { command in
                guard case .showQuitMenu = command else { return }
                Task { await finish(reason: .paused, message: "Native NVST stream paused.") }
            }
        )
        startTask = Task {
            do {
                let session = try await path.start(configuration: configuration) { progress in
                    await MainActor.run {
                        statusMessage = progress.message
                        onProgress?(progress)
                    }
                }
                await MainActor.run {
                    isConnected = true
                    statusMessage = "Connected over native NVST."
                    onProgress?(StreamProgress(configuration: configuration, step: .connected, message: "Connected over native NVST.", isReady: true))
                    WebRTCMediaTelemetry.capture("nvst.ui.connected", level: .info, message: "Native NVST stream connected.", attributes: ["sessionId": session.id])
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
        endStreamingPerformanceMode()
        finishOnce(report: StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID, "transport": "nvst"]))
    }

    private func stopStream() {
        WebRTCMediaStreamLifecycle.deactivate(configuration.id)
        startTask?.cancel()
        startTask = nil
        endEventTask?.cancel()
        endEventTask = nil
        endStreamingPerformanceMode()
        guard !didEnd else { return }
        didEnd = true
        nativeView?.onInputEvent = nil
        if let path {
            Task { try? await path.stop(reason: .userRequested, message: "Native NVST stream view closed.") }
        }
    }

    private func finish(reason: StreamEndReason, message: String) async {
        guard !isEnding else { return }
        await MainActor.run { isEnding = true }
        let report: StreamReport
        if let path {
            report = (try? await path.stop(reason: reason, message: message)) ?? StreamReport(title: configuration.title, success: reason != .failed, reason: reason, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID, "transport": "nvst"])
        } else {
            report = StreamReport(title: configuration.title, success: reason != .failed, reason: reason, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID, "transport": "nvst"])
        }
        await MainActor.run { finishOnce(report: report) }
    }

    private func finishOnce(report: StreamReport) {
        guard !didEnd else { return }
        didEnd = true
        isConnected = false
        endEventTask?.cancel()
        endEventTask = nil
        nativeView?.onInputEvent = nil
        nativeView?.onCommand = nil
        WebRTCMediaStreamLifecycle.deactivate(configuration.id)
        onEnd(report.success, report.message, report)
    }

    private func configureInput(for view: NativeWebRTCStreamView) {
        view.onInputEvent = { [path] event in
            guard let path else { return }
            Task { try? await path.send(event) }
        }
        view.onCommand = { command in
            _ = WebRTCMediaStreamLifecycle.sendCommand(command)
        }
    }

    private static func nativeVideoSurfaceHandle(for view: NativeWebRTCStreamView) -> UInt? {
        let videoSurface = view.nativeVideoView()
        guard videoSurface.window != nil else { return nil }
        return UInt(bitPattern: Unmanaged.passUnretained(videoSurface).toOpaque())
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

    func makeNSView(context: Context) -> NativeNVSTContainerView {
        let view = NativeNVSTContainerView(frame: .zero)
        view.onResolve = { streamView in
            Task { @MainActor in onResolve(streamView) }
        }
        return view
    }

    func updateNSView(_ nsView: NativeNVSTContainerView, context: Context) {}

    final class NativeNVSTContainerView: NSView {
        let streamView = NativeWebRTCStreamView(frame: .zero)
        var onResolve: ((NativeWebRTCStreamView) -> Void)?

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
            if window != nil { onResolve?(streamView) }
        }

        override func layout() {
            super.layout()
            streamView.frame = bounds
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
