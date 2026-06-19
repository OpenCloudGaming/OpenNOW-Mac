import AppKit
import Foundation
import SwiftUI

public typealias WebRTCMediaStreamProgressCallback = @MainActor @Sendable (_ progress: StreamProgress) -> Void
public typealias WebRTCMediaStreamEndCallback = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: StreamReport?) -> Void

@MainActor
public struct WebRTCMediaStreamSurface: View {
    private let configuration: StreamLaunchConfiguration
    private let sessionProvider: any StreamSessionProvider
    private let signaling: (any StreamSignalingChannel)?
    private let onProgress: WebRTCMediaStreamProgressCallback?
    private let onEnd: WebRTCMediaStreamEndCallback

    @State private var path: WebRTCStreamingPath?
    @State private var transport: NativeWebRTCTransport?
    @State private var hasStarted = false
    @State private var isStreamReady = false
    @State private var statusMessage = "Starting WebRTC media path..."
    @State private var pointerLocked = false
    @State private var statsVisible = false
    @State private var videoEnhancementSettingsVisible = false
    @State private var sidebarVisible = true
    @State private var quitMenuVisible = false
    @State private var isEndingStream = false
    @State private var didEndStream = false
    @State private var latestStats: OPNStreamStatsSnapshot?
    @State private var statsTask: Task<Void, Never>?
    @State private var nativeView: NativeWebRTCStreamView?
    @State private var pendingApplicationQuitCompletion: WebRTCMediaStreamQuitDecisionHandler?
    @State private var runtimeSettings = StreamRuntimeSettings()
    @State private var microphoneEnabled = false
    @State private var recordingStatus = WebRTCStreamRecordingStatus.idle

    public init(configuration: StreamLaunchConfiguration,
                sessionProvider: any StreamSessionProvider,
                signaling: (any StreamSignalingChannel)? = nil,
                onProgress: WebRTCMediaStreamProgressCallback? = nil,
                onEnd: @escaping WebRTCMediaStreamEndCallback) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.signaling = signaling
        self.onProgress = onProgress
        self.onEnd = onEnd
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            NativeWebRTCStreamSurface { view in
                nativeView = view
                view.onPointerLockChanged = { locked in handlePointerLockChanged(locked) }
                view.onCommand = { command in
                    handle(command)
                }
                Task { await startIfNeeded(nativeView: view) }
            }
            if !isStreamReady { launchOverlay }
            if statsVisible { statsHUD }
            if videoEnhancementSettingsVisible { videoEnhancementSettingsPanel }
            if sidebarVisible { sidebar }
            if quitMenuVisible { quitMenu }
            recordingIndicator
            micStatusIndicator
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { registerStreamLifecycle() }
        .onDisappear { stopStream() }
    }

    private var launchOverlay: some View {
        LinearGradient(
            colors: [Color(red: 0.015, green: 0.02, blue: 0.018), Color(red: 0.05, green: 0.08, blue: 0.055)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            VStack(spacing: 18) {
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(statusMessage)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.67, green: 1.0, blue: 0.36).opacity(0.84))
                ProgressView()
                    .controlSize(.large)
                    .tint(Color(red: 0.56, green: 1.0, blue: 0.25))
            }
            .padding(36)
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        }
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREAM STATS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
            statsRow("Latency", formatted(latestStats?.latencyMs, suffix: " ms"))
            statsRow("Jitter", formatted(latestStats?.jitterMs, suffix: " ms"))
            statsRow("Bitrate", formatted(latestStats?.inboundBitrateMbps, suffix: " Mbps"))
            statsRow("Loss", formatted(latestStats?.packetLossPercent, suffix: "%"))
            statsRow("FPS", formatted(latestStats?.renderFps, suffix: ""))
            statsRow("Decode", formatted(latestStats?.decodeTimeMs, suffix: " ms"))
            statsRow("Drops", String(latestStats?.framesDropped ?? 0))
            statsRow("Frame Δ", formatted(latestStats?.videoFrameIntervalMs, suffix: " ms"))
            statsRow("Max Δ", formatted(latestStats?.videoMaxFrameIntervalMs, suffix: " ms"))
            statsRow("Codec", latestStats?.codec.isEmpty == false ? latestStats?.codec ?? "-" : "-")
            statsRow("Resolution", latestStats?.resolution.isEmpty == false ? latestStats?.resolution ?? "-" : "-")
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(14)
        .frame(width: 252, alignment: .leading)
        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(red: 0.61, green: 1.0, blue: 0.22).opacity(0.28), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        .padding(.top, 22)
        .padding(.trailing, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var sidebar: some View {
        VStack(spacing: 10) {
            Text("GFN")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
                .padding(.bottom, 6)
            sidebarButton(systemName: "waveform.path.ecg", title: "Stats") {
                statsVisible.toggle()
            }
            sidebarButton(systemName: "record.circle", title: recordingButtonTitle, isActive: recordingCanStop) {
                toggleRecording()
            }
            .disabled(!isStreamReady || recordingIsBusy)
            sidebarButton(systemName: "sparkles", title: "Video") {
                toggleVideoEnhancementSettings()
            }
        }
        .padding(10)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        .padding(.top, 22)
        .padding(.leading, 18)
    }

    private var videoEnhancementSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("VIDEO ENHANCEMENT")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
                Spacer()
                Button(action: { videoEnhancementSettingsVisible = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.09), in: Circle())
                }
                .buttonStyle(.plain)
            }
            Picker("Mode", selection: Binding(get: { runtimeSettings.upscalingMode }, set: { updateVideoEnhancement(mode: $0) })) {
                ForEach(StreamRuntimeSettings.upscalingModes, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .tint(Color(red: 0.61, green: 1.0, blue: 0.22))
            .disabled(!isStreamReady)
            if runtimeSettings.upscalingMode != 0 {
                videoStepperRow("Sharpness", value: runtimeSettings.upscalingSharpness, range: 0...40) { value in
                    updateVideoEnhancement(sharpness: value)
                }
                videoStepperRow("Denoise", value: runtimeSettings.upscalingDenoise, range: 0...20) { value in
                    updateVideoEnhancement(denoise: value)
                }
                Picker("Target", selection: Binding(get: { runtimeSettings.upscalingTargetHeight }, set: { updateVideoEnhancement(targetHeight: $0) })) {
                    ForEach(StreamRuntimeSettings.upscalingTargets, id: \.height) { option in
                        Text(option.label).tag(option.height)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!isStreamReady)
            }
            Divider().overlay(.white.opacity(0.12))
            settingsRow("Configured", liveEnhancementValue(latestStats?.videoEnhancementConfiguredTier, fallback: runtimeSettings.upscalingModeLabel))
            settingsRow("Active", liveEnhancementValue(latestStats?.videoEnhancementActiveTier, fallback: runtimeSettings.upscalingMode == 0 ? "Native" : "Pending"))
            settingsRow("Source", liveEnhancementValue(latestStats?.videoEnhancementSourceResolution, fallback: "Pending"))
            settingsRow("Drawable", liveEnhancementValue(latestStats?.videoEnhancementDrawableResolution, fallback: "Pending"))
            settingsRow("Frame", frameTimeValue(latestStats?.videoEnhancementFrameTimeMs))
            settingsRow("Dropped", String(latestStats?.videoEnhancementDroppedFrames ?? 0))
            if let fallback = latestStats?.videoEnhancementFallbackReason, !fallback.isEmpty {
                Text(fallback)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(14)
        .frame(width: 272, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color(red: 0.61, green: 1.0, blue: 0.22).opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.48), radius: 24, x: 0, y: 12)
        .padding(.top, 22)
        .padding(.leading, 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var quitMenu: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.54))
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Text("STREAM PAUSED")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(Color(red: 0.61, green: 1.0, blue: 0.22))
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Pause the quit request or quit the current session. Remote input is paused while this menu is open.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 12) {
                    Button(action: pauseFromQuitMenu) {
                        Text("Pause")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(width: 150, height: 44)
                            .background(Color(red: 0.61, green: 1.0, blue: 0.22), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button(action: quitStreamFromMenu) {
                        Text(isEndingStream ? "Quitting..." : "Quit")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 150, height: 44)
                            .background(.white.opacity(0.11), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isEndingStream)
                }
            }
            .padding(32)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Color(red: 0.61, green: 1.0, blue: 0.22).opacity(0.26), lineWidth: 1))
            .shadow(color: .black.opacity(0.62), radius: 42, x: 0, y: 20)
        }
    }

    private var micStatusIndicator: some View {
        let isAvailable = runtimeSettings.microphoneMode != "disabled"
        return Image(systemName: microphoneEnabled && isAvailable ? "mic.fill" : "mic.slash.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(microphoneEnabled && isAvailable ? Color(red: 0.61, green: 1.0, blue: 0.22) : .white.opacity(0.72))
            .frame(width: 30, height: 30)
            .background(.black.opacity(0.58), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
            .opacity(isAvailable ? 1 : 0.55)
            .padding(.trailing, 18)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var recordingIndicator: some View {
        Group {
            switch recordingStatus {
            case .starting:
                Text("Starting recording...")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(.black.opacity(0.62), in: Capsule())
            case .recording(_, let elapsedSeconds):
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(recordingElapsedText(elapsedSeconds))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.94))
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.black.opacity(0.62), in: Capsule())
                .overlay(Capsule().stroke(Color.red.opacity(0.36), lineWidth: 1))
            case .finishing:
                Text("Saving recording...")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(.black.opacity(0.62), in: Capsule())
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color.red.opacity(0.72), in: Capsule())
            case .finished(let recording):
                Text("Saved: \(recording.title)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(.black.opacity(0.62), in: Capsule())
                    .overlay(Capsule().stroke(Color(red: 0.61, green: 1.0, blue: 0.22).opacity(0.32), lineWidth: 1))
            default:
                EmptyView()
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sidebarButton(systemName: String, title: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(isActive ? .white : .white.opacity(0.92))
            .frame(width: 58, height: 54)
            .background(isActive ? Color.red.opacity(0.72) : .white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var recordingIsBusy: Bool {
        if case .finishing = recordingStatus { return true }
        return false
    }

    private var recordingCanStop: Bool {
        if case .starting = recordingStatus { return true }
        return recordingStatus.isRecording
    }

    private var recordingButtonTitle: String {
        recordingCanStop ? "Stop" : "Record"
    }

    private func toggleRecording() {
        if recordingCanStop {
            transport?.stopRecording()
            return
        }
        guard !recordingIsBusy else { return }
        let recordingConfiguration = WebRTCStreamRecordingConfiguration(
            title: configuration.title,
            applicationID: configuration.applicationID,
            width: runtimeSettings.resolutionWidth,
            height: runtimeSettings.resolutionHeight,
            fps: runtimeSettings.fps,
            videoBitrateMbps: runtimeSettings.recordingVideoBitrateMbps,
            audioBitrateKbps: runtimeSettings.recordingAudioBitrateKbps,
            enhancedVideoEnabled: runtimeSettings.recordingEnhancedVideoEnabled
        )
        transport?.startRecording(configuration: recordingConfiguration)
        WebRTCMediaTelemetry.capture("webrtc.ui.recording.start", level: .info, message: "Stream recording started.", attributes: ["applicationID": configuration.applicationID])
    }

    private func toggleVideoEnhancementSettings() {
        videoEnhancementSettingsVisible.toggle()
        WebRTCMediaTelemetry.capture("webrtc.ui.video_enhancement.toggle", level: .info, message: videoEnhancementSettingsVisible ? "Video enhancement settings shown." : "Video enhancement settings hidden.", attributes: ["visible": String(videoEnhancementSettingsVisible)])
    }

    private func recordingElapsedText(_ elapsedSeconds: Double) -> String {
        let seconds = max(0, Int(elapsedSeconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func statsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.58))
            Spacer()
            Text(value).foregroundStyle(.white.opacity(0.94))
        }
    }

    private func settingsRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.white.opacity(0.58))
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func videoStepperRow(_ label: String, value: Int, range: ClosedRange<Int>, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.white.opacity(0.58))
            Spacer(minLength: 8)
            Stepper(value: Binding(get: { value }, set: { action($0) }), in: range) {
                Text(String(value))
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .disabled(!isStreamReady)
        }
    }

    private func updateVideoEnhancement(mode: Int? = nil, sharpness: Int? = nil, denoise: Int? = nil, targetHeight: Int? = nil) {
        runtimeSettings.updateVideoEnhancement(mode: mode, sharpness: sharpness, denoise: denoise, targetHeight: targetHeight)
        transport?.setLocalVideoEnhancement(mode: runtimeSettings.upscalingMode, sharpness: runtimeSettings.upscalingSharpness, denoise: runtimeSettings.upscalingDenoise, targetHeight: runtimeSettings.upscalingTargetHeight)
        WebRTCMediaTelemetry.capture(
            "webrtc.ui.video_enhancement.update",
            level: .info,
            message: "Video enhancement settings updated.",
            attributes: [
                "mode": String(runtimeSettings.upscalingMode),
                "sharpness": String(runtimeSettings.upscalingSharpness),
                "denoise": String(runtimeSettings.upscalingDenoise),
                "targetHeight": String(runtimeSettings.upscalingTargetHeight),
            ]
        )
    }

    private func formatted(_ value: Double?, suffix: String) -> String {
        guard let value, value >= 0 else { return "-" }
        return String(format: "%.1f%@", value, suffix)
    }

    private func frameTimeValue(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "Pending" }
        return String(format: "%.1f ms", value)
    }

    private func liveEnhancementValue(_ value: String?, fallback: String) -> String {
        guard let value, !value.isEmpty, value != "unknown", value != "pending" else { return fallback }
        return value
    }

    private func startIfNeeded(nativeView: NativeWebRTCStreamView) async {
        guard !hasStarted else { return }
        hasStarted = true
        let transport = NativeWebRTCTransport(nativeView: nativeView)
        let path = WebRTCStreamingPath(sessionProvider: sessionProvider, transport: transport, signaling: signaling)
        transport.onEnded = { message in
            handleTransportEnded(message: message)
        }
        transport.onRecordingStatusChanged = { status in
            recordingStatus = status
        }
        nativeView.onInputEvent = { event in
            switch inputAction(for: event) {
            case .send:
                guard isStreamReady else { return }
                transport.sendNow(event)
            case .drop:
                return
            case .setMicrophone(let enabled):
                microphoneEnabled = enabled
                transport.setMicrophoneEnabled(enabled)
            }
        }
        self.transport = transport
        self.path = path
        startStatsPolling(transport: transport)
        do {
            let session = try await path.start(configuration: configuration) { progress in
                await MainActor.run {
                    statusMessage = progress.message
                    isStreamReady = progress.isReady
                    onProgress?(progress)
                }
            }
            await MainActor.run {
                runtimeSettings = StreamRuntimeSettings(json: session.metadata["settings"])
                microphoneEnabled = runtimeSettings.microphoneMode == "voice-activity"
                transport.setMicrophoneEnabled(microphoneEnabled)
                nativeView.directMouseInputEnabled = runtimeSettings.directMouseInput
                nativeView.setStreamContentSize(width: runtimeSettings.resolutionWidth, height: runtimeSettings.resolutionHeight)
            }
        } catch {
            let message = Self.message(for: error)
            statusMessage = message
            onEnd(false, message, StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID]))
        }
    }

    private func startStatsPolling(transport: NativeWebRTCTransport) {
        statsTask?.cancel()
        statsTask = Task {
            for await snapshot in transport.statsSnapshots(intervalSeconds: 1) {
                latestStats = snapshot
            }
        }
    }

    private func inputAction(for event: UserInputEvent) -> StreamInputAction {
        guard !quitMenuVisible, !isEndingStream else { return .drop }
        if let keyboard = keyboardEvent(from: event), let microphoneAction = microphoneToggleAction(for: keyboard) { return microphoneAction }
        guard shouldAcceptInputWhenInactive() else { return runtimeSettings.microphoneMode == "push-to-talk" ? .setMicrophone(false) : .drop }
        if let keyboard = keyboardEvent(from: event), let microphoneAction = microphoneAction(for: keyboard) { return microphoneAction }
        if let mouse = mouseEvent(from: event) {
            guard pointerLocked else { return .drop }
            if !runtimeSettings.directMouseInput, isMouseMove(mouse) { return .drop }
        }
        return .send
    }

    private func shouldAcceptInputWhenInactive() -> Bool {
        guard runtimeSettings.suppressInputWhenInactive else { return true }
        guard let nativeView else { return false }
        return nativeView.window?.isKeyWindow == true && NSApplication.shared.isActive
    }

    private func microphoneToggleAction(for keyboard: KeyboardEvent) -> StreamInputAction? {
        guard keyboard.modifiers.contains(.command), Int(keyboard.keyCode) == Self.microphoneToggleKeyCode else { return nil }
        guard keyboard.isPressed else { return .drop }
        toggleMicrophone()
        return .drop
    }

    private func microphoneAction(for keyboard: KeyboardEvent) -> StreamInputAction? {
        guard runtimeSettings.microphoneMode == "push-to-talk" else { return nil }
        guard Int(keyboard.keyCode) == runtimeSettings.microphonePushToTalkKeyCode else { return nil }
        let configuredModifiers = UInt16(truncatingIfNeeded: runtimeSettings.microphonePushToTalkModifierMask) & Self.pushToTalkModifierMask
        guard keyboard.modifiers.rawValue & Self.pushToTalkModifierMask == configuredModifiers else { return nil }
        return .setMicrophone(keyboard.isPressed)
    }

    private func keyboardEvent(from event: UserInputEvent) -> KeyboardEvent? {
        if case .keyboard(let keyboard) = event { return keyboard }
        return nil
    }

    private func mouseEvent(from event: UserInputEvent) -> MouseEvent? {
        if case .mouse(let mouse) = event { return mouse }
        return nil
    }

    private func isMouseMove(_ event: MouseEvent) -> Bool {
        if case .moved = event { return true }
        return false
    }

    private func handle(_ command: WebRTCMediaStreamCommand) {
        switch command {
        case .toggleStatsHUD:
            statsVisible.toggle()
            WebRTCMediaTelemetry.capture("webrtc.ui.stats.toggle", level: .info, message: statsVisible ? "Stats HUD shown." : "Stats HUD hidden.", attributes: ["visible": String(statsVisible)])
        case .toggleSidebar:
            setSidebarVisible(!sidebarVisible)
            WebRTCMediaTelemetry.capture("webrtc.ui.sidebar.toggle", level: .info, message: sidebarVisible ? "Sidebar shown." : "Sidebar hidden.", attributes: ["visible": String(sidebarVisible)])
        case .toggleMicrophone:
            toggleMicrophone()
        case .toggleRecording:
            guard isStreamReady, !recordingIsBusy else { return }
            toggleRecording()
        case .toggleVideoEnhancement:
            toggleVideoEnhancementSettings()
        case .showQuitMenu:
            showQuitMenu()
        }
    }

    private func toggleMicrophone() {
        guard runtimeSettings.microphoneMode != "disabled" else {
            microphoneEnabled = false
            transport?.setMicrophoneEnabled(false)
            return
        }
        microphoneEnabled.toggle()
        transport?.setMicrophoneEnabled(microphoneEnabled)
        WebRTCMediaTelemetry.capture("webrtc.ui.microphone.toggle", level: .info, message: microphoneEnabled ? "Microphone enabled." : "Microphone muted.", attributes: ["enabled": String(microphoneEnabled)])
    }

    private func handlePointerLockChanged(_ locked: Bool) {
        pointerLocked = locked
        if locked {
            setSidebarVisible(false)
        }
    }

    private func setSidebarVisible(_ visible: Bool) {
        sidebarVisible = visible
        guard visible else { return }
        nativeView?.setPointerLocked(false)
    }

    private func registerStreamLifecycle() {
        WebRTCMediaStreamLifecycle.activate(configuration.id) { completion in
            showQuitMenu(completion: completion)
            return true
        }
    }

    private func showQuitMenu(completion: WebRTCMediaStreamQuitDecisionHandler? = nil) {
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = completion
        nativeView?.setPointerLocked(false)
        microphoneEnabled = false
        transport?.setMicrophoneEnabled(false)
        quitMenuVisible = true
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.show", level: .info, message: "Stream quit menu shown.", attributes: ["applicationID": configuration.applicationID])
    }

    private func pauseFromQuitMenu() {
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

    private func quitStreamFromMenu() {
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

    private func handleTransportEnded(message: String) {
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

    private func finishStream(reason: StreamEndReason, message: String) async -> StreamReport {
        let fallbackReport = StreamReport(title: configuration.title, success: reason != .failed, reason: reason, message: message, durationSeconds: 0, metadata: ["applicationID": configuration.applicationID])
        let shouldFinish = await MainActor.run {
            guard !didEndStream else { return false }
            didEndStream = true
            return true
        }
        guard shouldFinish else { return fallbackReport }
        guard let path else { return fallbackReport }
        do {
            return try await path.stop(reason: reason, message: message)
        } catch {
            return StreamReport(title: configuration.title, success: false, reason: .failed, message: Self.message(for: error), durationSeconds: 0, metadata: ["applicationID": configuration.applicationID])
        }
    }

    private func stopStream() {
        WebRTCMediaStreamLifecycle.deactivate(configuration.id)
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        statsTask?.cancel()
        statsTask = nil
        nativeView?.setPointerLocked(false)
        microphoneEnabled = false
        transport?.setMicrophoneEnabled(false)
        transport?.stopRecording()
        guard !didEndStream else { return }
        didEndStream = true
        if let path { Task { try? await path.stop(reason: .userRequested, message: "Stream view closed.") } }
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }

    private static let pushToTalkModifierMask = KeyboardModifiers.shift.rawValue | KeyboardModifiers.control.rawValue | KeyboardModifiers.option.rawValue | KeyboardModifiers.command.rawValue | KeyboardModifiers.capsLock.rawValue
    private static let microphoneToggleKeyCode = 46
}

private enum StreamInputAction {
    case send
    case drop
    case setMicrophone(Bool)
}

private struct StreamRuntimeSettings: Equatable {
    static let upscalingModes = [
        VideoEnhancementMode(label: "Off", value: 0),
        VideoEnhancementMode(label: "Auto", value: 1),
        VideoEnhancementMode(label: "Spatial", value: 2),
        VideoEnhancementMode(label: "MetalFX", value: 3),
        VideoEnhancementMode(label: "Temporal", value: 4),
    ]
    static let upscalingTargets = [
        VideoEnhancementTarget(label: "2K", height: 1440),
        VideoEnhancementTarget(label: "4K", height: 2160),
    ]

    var resolutionWidth = 1920
    var resolutionHeight = 1080
    var fps = 60
    var microphoneMode = "disabled"
    var microphonePushToTalkKeyCode = 9
    var microphonePushToTalkModifierMask = 0
    var suppressInputWhenInactive = true
    var directMouseInput = true
    var upscalingMode = 0
    var upscalingSharpness = 4
    var upscalingDenoise = 0
    var upscalingTargetHeight = 2160
    var recordingVideoBitrateMbps = 0
    var recordingAudioBitrateKbps = 160
    var recordingEnhancedVideoEnabled = true

    var upscalingModeLabel: String {
        switch upscalingMode {
        case 0: return "Off"
        case 1: return "Auto"
        case 2: return "Spatial"
        case 3: return "MetalFX"
        case 4: return "Temporal"
        default: return "Mode \(upscalingMode)"
        }
    }

    init() {}

    mutating func updateVideoEnhancement(mode: Int? = nil, sharpness: Int? = nil, denoise: Int? = nil, targetHeight: Int? = nil) {
        if let mode {
            let allowed = Self.upscalingModes.map(\.value)
            upscalingMode = allowed.contains(mode) ? mode : 0
        }
        if let sharpness { upscalingSharpness = min(max(sharpness, 0), 40) }
        if let denoise { upscalingDenoise = min(max(denoise, 0), 20) }
        if let targetHeight {
            let allowed = Self.upscalingTargets.map(\.height)
            upscalingTargetHeight = allowed.contains(targetHeight) ? targetHeight : 2160
        }
    }

    init(json: String?) {
        guard let json,
              let data = json.data(using: .utf8),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let resolution = Self.resolution(Self.string(dictionary["resolution"], fallback: "1920x1080"))
        resolutionWidth = resolution.width
        resolutionHeight = resolution.height
        fps = Self.int(dictionary["fps"], fallback: 60)
        microphoneMode = Self.string(dictionary["microphoneMode"], fallback: "disabled")
        microphonePushToTalkKeyCode = Self.int(dictionary["microphonePushToTalkKeyCode"], fallback: 9)
        microphonePushToTalkModifierMask = Self.int(dictionary["microphonePushToTalkModifierMask"])
        suppressInputWhenInactive = Self.bool(dictionary["suppressInputWhenInactive"], fallback: true)
        directMouseInput = Self.bool(dictionary["directMouseInput"], fallback: true)
        upscalingMode = Self.int(dictionary["upscalingMode"])
        upscalingSharpness = Self.int(dictionary["upscalingSharpness"], fallback: 4)
        upscalingDenoise = Self.int(dictionary["upscalingDenoise"])
        upscalingTargetHeight = Self.int(dictionary["upscalingTargetHeight"], fallback: 2160)
        recordingVideoBitrateMbps = Self.int(dictionary["recordingVideoBitrateMbps"])
        recordingAudioBitrateKbps = Self.int(dictionary["recordingAudioBitrateKbps"], fallback: 160)
        recordingEnhancedVideoEnabled = Self.bool(dictionary["recordingEnhancedVideoEnabled"], fallback: true)
    }

    private static func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.isEmpty ? fallback : value }
        if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    private static func int(_ value: Any?, fallback: Int = 0) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? fallback }
        return fallback
    }

    private static func bool(_ value: Any?, fallback: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
        return fallback
    }

    private static func resolution(_ value: String) -> (width: Int, height: Int) {
        let parts = value.split(separator: "x").compactMap { Int($0) }
        return (max(1, parts.first ?? 1920), max(1, parts.count > 1 ? parts[1] : 1080))
    }
}

private struct VideoEnhancementMode: Equatable {
    let label: String
    let value: Int
}

private struct VideoEnhancementTarget: Equatable {
    let label: String
    let height: Int
}

private struct NativeWebRTCStreamSurface: NSViewRepresentable {
    let onResolve: @MainActor (NativeWebRTCStreamView) -> Void

    func makeNSView(context: Context) -> NativeWebRTCStreamView {
        let view = NativeWebRTCStreamView(frame: .zero)
        Task { @MainActor in onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NativeWebRTCStreamView, context: Context) {}
}
