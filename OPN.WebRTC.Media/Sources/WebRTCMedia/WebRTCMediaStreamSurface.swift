import AppKit
import Common
import Foundation
import SwiftUI

public typealias WebRTCMediaStreamProgressCallback = @MainActor @Sendable (_ progress: StreamProgress) -> Void
public typealias WebRTCMediaStreamEndCallback = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: StreamReport?) -> Void
public typealias WebRTCMediaBroadcastConfigurationProvider = @MainActor @Sendable (_ title: String, _ applicationID: String, _ width: Int, _ height: Int, _ fps: Int) -> WebRTCLiveBroadcastConfiguration?
public typealias WebRTCMediaBroadcastStartCallback = @MainActor @Sendable (_ title: String, _ applicationID: String) async -> String?
public typealias WebRTCMediaBroadcastLiveVerificationCallback = @MainActor @Sendable (_ title: String, _ applicationID: String) async -> WebRTCMediaBroadcastLiveVerificationResult
public typealias WebRTCMediaStreamMarkerCallback = @MainActor @Sendable (_ title: String, _ applicationID: String, _ description: String) async -> String
public typealias WebRTCMediaTwitchChatSendCallback = @MainActor @Sendable (_ message: String) -> Void
public typealias WebRTCMediaTwitchHealthRefreshCallback = @MainActor @Sendable () async -> Void
public typealias WebRTCMediaAntiAFKStateChangeCallback = @MainActor @Sendable (_ enabled: Bool) -> Void
public typealias WebRTCMediaVideoEnhancementChangeCallback = @MainActor @Sendable (_ mode: Int, _ sharpness: Int, _ denoise: Int) -> Void

public struct WebRTCMediaTwitchChatMessage: Identifiable, Equatable, Sendable {
    public let id: String
    public let author: String
    public let text: String
    public let timestamp: Date

    public init(id: String, author: String, text: String, timestamp: Date) {
        self.id = id
        self.author = author
        self.text = text
        self.timestamp = timestamp
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private enum WebRTCMediaStreamTheme {
    static let accent = Color(red: 0.46, green: 0.90, blue: 0.10)
    static let accentSoft = Color(red: 0.67, green: 1.0, blue: 0.36)
    static let appBar = Color(red: 45 / 255, green: 45 / 255, blue: 45 / 255)
    static let surface = Color(red: 25 / 255, green: 25 / 255, blue: 25 / 255)
    static let panel = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
    static let surfaceRaised = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let divider = Color.white.opacity(0.10)
    static let textPrimary = Color.white.opacity(0.96)
    static let textSecondary = Color.white.opacity(0.72)
    static let textTertiary = Color.white.opacity(0.52)
    static let warning = Color.orange
    static let danger = Color.red

    static func dockWidth(for width: CGFloat) -> CGFloat {
        min(344, max(220, width * 0.72))
    }
}

private extension Font {
    static func streamNvidia(size: CGFloat, weight: OPNNVIDIAFont.Weight = .regular) -> Font {
        OPNNVIDIAFont.font(size: size, weight: weight)
    }
}

private struct StreamHUDActionRow: View {
    let title: String
    let subtitle: String
    let systemName: String
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    Rectangle()
                        .fill(iconBackground)
                    Image(systemName: systemName)
                        .font(.streamNvidia(size: 14, weight: .bold))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.streamNvidia(size: 14, weight: .bold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.streamNvidia(size: 11, weight: .medium))
                        .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 50)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isActive ? WebRTCMediaStreamTheme.accent : Color.clear)
                    .frame(width: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.46 : 1)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    private var rowBackground: Color {
        if isActive { return WebRTCMediaStreamTheme.accent.opacity(0.095) }
        return Color.white.opacity(isHovering ? 0.085 : 0)
    }

    private var iconBackground: Color {
        if isActive { return WebRTCMediaStreamTheme.accent }
        return Color.white.opacity(isHovering ? 0.16 : 0.08)
    }

    private var titleColor: Color {
        isActive ? .white : .white.opacity(isHovering ? 0.96 : 0.82)
    }

    private var iconColor: Color {
        isActive ? .black.opacity(0.86) : .white.opacity(isHovering ? 0.94 : 0.72)
    }
}

public struct WebRTCMediaTwitchEventAlert: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let message: String
    public let timestamp: Date

    public init(id: String, title: String, message: String, timestamp: Date) {
        self.id = id
        self.title = title
        self.message = message
        self.timestamp = timestamp
    }
}

public struct WebRTCMediaTwitchOverlayState: Equatable, Sendable {
    public var accountSummary: String
    public var streamKeyAvailable: Bool
    public var chatState: String
    public var eventSubState: String
    public var supportedAlertTypes: [String]
    public var chatMessages: [WebRTCMediaTwitchChatMessage]
    public var eventAlerts: [WebRTCMediaTwitchEventAlert]

    public init(accountSummary: String = "Not connected", streamKeyAvailable: Bool = false, chatState: String = "Disconnected", eventSubState: String = "Disconnected", supportedAlertTypes: [String] = [], chatMessages: [WebRTCMediaTwitchChatMessage] = [], eventAlerts: [WebRTCMediaTwitchEventAlert] = []) {
        self.accountSummary = accountSummary
        self.streamKeyAvailable = streamKeyAvailable
        self.chatState = chatState
        self.eventSubState = eventSubState
        self.supportedAlertTypes = supportedAlertTypes
        self.chatMessages = chatMessages
        self.eventAlerts = eventAlerts
    }
}

public enum WebRTCMediaBroadcastLiveVerificationResult: Equatable, Sendable {
    case verified(String)
    case unavailable(String)
    case notLive(String)

    var message: String {
        switch self {
        case .verified(let message), .unavailable(let message), .notLive(let message): return message
        }
    }
}

private enum WebRTCMediaBroadcastPreparationResult: Equatable, Sendable {
    case completed(String?)
    case unavailable
    case timedOut
}

private actor WebRTCMediaBroadcastPreparationGate {
    private var result: WebRTCMediaBroadcastPreparationResult?
    private var continuation: CheckedContinuation<WebRTCMediaBroadcastPreparationResult, Never>?

    func wait() async -> WebRTCMediaBroadcastPreparationResult {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ result: WebRTCMediaBroadcastPreparationResult) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
public struct WebRTCMediaStreamSurface: View {
    private let configuration: StreamLaunchConfiguration
    private let sessionProvider: any StreamSessionProvider
    private let signaling: (any StreamSignalingChannel)?
    private let broadcastConfigurationProvider: WebRTCMediaBroadcastConfigurationProvider?
    private let onBroadcastStart: WebRTCMediaBroadcastStartCallback?
    private let onBroadcastLiveVerification: WebRTCMediaBroadcastLiveVerificationCallback?
    private let onStreamMarker: WebRTCMediaStreamMarkerCallback?
    private let twitchOverlayState: WebRTCMediaTwitchOverlayState
    private let onTwitchChatSend: WebRTCMediaTwitchChatSendCallback?
    private let onTwitchHealthRefresh: WebRTCMediaTwitchHealthRefreshCallback?
    private let onAntiAFKStateChange: WebRTCMediaAntiAFKStateChangeCallback?
    private let onVideoEnhancementChange: WebRTCMediaVideoEnhancementChangeCallback?
    private let preventDisplaySleep: Bool
    private let onProgress: WebRTCMediaStreamProgressCallback?
    private let onEnd: WebRTCMediaStreamEndCallback

    @State private var path: WebRTCStreamingPath?
    @State private var transport: NativeWebRTCTransport?
    @State private var hasStarted = false
    @State private var isStreamReady = false
    @State private var statusMessage = "Starting WebRTC media path..."
    @State private var pointerLocked = false
    @State private var statsVisible = false
    @State private var unifiedHUDVisible = false
    @State private var twitchMarkerMessage = ""
    @State private var twitchMarkerDraft = ""
    @State private var twitchChatDraft = ""
    @State private var quitMenuVisible = false
    @State private var isEndingStream = false
    @State private var didEndStream = false
    @State private var latestStats: OPNStreamStatsSnapshot?
    @State private var statsTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?
    @State private var nativeView: NativeWebRTCStreamView?
    @State private var pendingApplicationQuitCompletion: WebRTCMediaStreamQuitDecisionHandler?
    @State private var runtimeSettings = StreamRuntimeSettings()
    @State private var microphoneEnabled = false
    @State private var recordingStatus = WebRTCStreamRecordingStatus.idle
    @State private var broadcastStatus = WebRTCLiveBroadcastStatus.idle
    @State private var isPreparingBroadcast = false
    @State private var broadcastLiveVerified = false
    @State private var broadcastVerificationMessage = ""
    @State private var broadcastForcedFailureMessage = ""
    @State private var broadcastVerificationUnavailable = false
    @State private var recordingNotificationTask: Task<Void, Never>?
    @State private var broadcastNotificationTask: Task<Void, Never>?
    @State private var broadcastVerificationTask: Task<Void, Never>?
    @State private var antiAFKMouseMovementTask: Task<Void, Never>?
    @State private var lastAcceptedStreamInputAt = Date()
    @State private var transientStreamMessage = ""
    @State private var transientStreamMessageTask: Task<Void, Never>?
    @State private var streamingPerformanceActivity: (any NSObjectProtocol)?

    public init(configuration: StreamLaunchConfiguration,
                sessionProvider: any StreamSessionProvider,
                signaling: (any StreamSignalingChannel)? = nil,
                broadcastConfigurationProvider: WebRTCMediaBroadcastConfigurationProvider? = nil,
                onBroadcastStart: WebRTCMediaBroadcastStartCallback? = nil,
                onBroadcastLiveVerification: WebRTCMediaBroadcastLiveVerificationCallback? = nil,
                onStreamMarker: WebRTCMediaStreamMarkerCallback? = nil,
                twitchOverlayState: WebRTCMediaTwitchOverlayState = WebRTCMediaTwitchOverlayState(),
                onTwitchChatSend: WebRTCMediaTwitchChatSendCallback? = nil,
                onTwitchHealthRefresh: WebRTCMediaTwitchHealthRefreshCallback? = nil,
                onAntiAFKStateChange: WebRTCMediaAntiAFKStateChangeCallback? = nil,
                onVideoEnhancementChange: WebRTCMediaVideoEnhancementChangeCallback? = nil,
                preventDisplaySleep: Bool = true,
                onProgress: WebRTCMediaStreamProgressCallback? = nil,
                onEnd: @escaping WebRTCMediaStreamEndCallback) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.signaling = signaling
        self.broadcastConfigurationProvider = broadcastConfigurationProvider
        self.onBroadcastStart = onBroadcastStart
        self.onBroadcastLiveVerification = onBroadcastLiveVerification
        self.onStreamMarker = onStreamMarker
        self.twitchOverlayState = twitchOverlayState
        self.onTwitchChatSend = onTwitchChatSend
        self.onTwitchHealthRefresh = onTwitchHealthRefresh
        self.onAntiAFKStateChange = onAntiAFKStateChange
        self.onVideoEnhancementChange = onVideoEnhancementChange
        self.preventDisplaySleep = preventDisplaySleep
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
                if startTask == nil {
                    startTask = Task { await startIfNeeded(nativeView: view) }
                }
            }
            if !isStreamReady { launchOverlay }
            if isStreamReady && !quitMenuVisible { microphoneToggleOverlay }
            if statsVisible { statsHUD }
            if unifiedHUDVisible { unifiedHUD }
            if !transientStreamMessage.isEmpty { transientStreamMessageOverlay }
            if quitMenuVisible { quitMenu }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .onAppear { registerStreamLifecycle() }
        .onDisappear { stopStream() }
        .onChange(of: preventDisplaySleep) { _, _ in refreshStreamingPerformanceMode() }
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STREAM STATS")
                .font(.streamNvidia(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(WebRTCMediaStreamTheme.accent)
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
        .font(.streamNvidia(size: 11, weight: .medium))
        .padding(14)
        .frame(width: 252, alignment: .leading)
        .background(WebRTCMediaStreamTheme.panel.opacity(0.92))
        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.accent.opacity(0.28), lineWidth: 1) }
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        .padding(.top, 22)
        .padding(.trailing, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var unifiedHUD: some View {
        GeometryReader { proxy in
            let dockWidth = WebRTCMediaStreamTheme.dockWidth(for: proxy.size.width)
            VStack(alignment: .leading, spacing: 0) {
                hudDockHeader
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        hudStatusPanel
                        hudControlsPanel
                        hudVideoPanel
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                hudShortcutFooter
            }
            .frame(width: dockWidth, height: proxy.size.height, alignment: .topLeading)
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
        .ignoresSafeArea()
    }

    private var hudDockHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GEFORCE NOW")
                        .font(.streamNvidia(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text("Stream HUD")
                        .font(.streamNvidia(size: 20, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: { setUnifiedHUDVisible(false) }) {
                    Image(systemName: "xmark")
                        .font(.streamNvidia(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08))
                        .overlay { Rectangle().stroke(Color.white.opacity(0.14), lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close stream HUD")
            }

            Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                .font(.streamNvidia(size: 13, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 18)
        .background(WebRTCMediaStreamTheme.appBar)
    }

    private var hudStatusPanel: some View {
        HStack(spacing: 8) {
            hudMetricCard(title: "Mic", value: microphoneStatusText, positive: microphoneEnabled && runtimeSettings.microphoneMode != "disabled")
            hudMetricCard(title: "Recording", value: recordingStatusText, positive: recordingStatus.isRecording)
            hudMetricCard(title: "Anti-AFK", value: runtimeSettings.antiAFKMouseMovementEnabled ? "On" : "Off", positive: runtimeSettings.antiAFKMouseMovementEnabled)
        }
    }

    private var hudShortcutFooter: some View {
        Text("CMD-G HUD  |  CMD-M MIC  |  CMD-R REC  |  CMD-K ANTI-AFK  |  CMD-Q QUIT")
            .font(.streamNvidia(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
    }

    private var hudControlsPanel: some View {
        hudSection(label: "CONTROLS") {
            VStack(alignment: .leading, spacing: 4) {
                StreamHUDActionRow(
                    title: microphoneEnabled ? "Mute Mic" : "Unmute Mic",
                    subtitle: microphoneStatusText,
                    systemName: microphoneEnabled ? "mic.slash.fill" : "mic.fill",
                    isActive: microphoneEnabled && runtimeSettings.microphoneMode != "disabled",
                    isDisabled: runtimeSettings.microphoneMode == "disabled",
                    action: toggleMicrophone
                )
                StreamHUDActionRow(
                    title: recordingCanStop ? "Stop Recording" : "Record",
                    subtitle: recordingStatusText,
                    systemName: "record.circle",
                    isActive: recordingStatus.isRecording,
                    isDisabled: !isStreamReady || recordingIsBusy,
                    action: toggleRecording
                )
                StreamHUDActionRow(
                    title: runtimeSettings.antiAFKMouseMovementEnabled ? "Anti-AFK Off" : "Anti-AFK On",
                    subtitle: runtimeSettings.antiAFKMouseMovementEnabled ? "Mouse keepalive active" : "Mouse keepalive idle",
                    systemName: "cursorarrow.motionlines",
                    isActive: runtimeSettings.antiAFKMouseMovementEnabled,
                    isDisabled: !isStreamReady,
                    action: toggleAntiAFKMouseMovement
                )
                StreamHUDActionRow(
                    title: "Quit Menu",
                    subtitle: "Pause input and end session",
                    systemName: "power",
                    isActive: false,
                    isDisabled: false,
                    action: { showQuitMenu() }
                )
            }
        }
    }

    private func hudSection<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.streamNvidia(size: 10, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
    }

    private var microphoneToggleOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                microphoneToggleButton
            }
        }
        .padding(.trailing, 24)
        .padding(.bottom, 24)
    }

    private var microphoneToggleButton: some View {
        Button(action: toggleMicrophone) {
            Image(systemName: microphoneEnabled ? "mic.fill" : "mic.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(microphoneEnabled ? .black.opacity(0.72) : .white.opacity(0.58))
                .frame(width: 28, height: 28)
                .background(microphoneEnabled ? WebRTCMediaStreamTheme.accent.opacity(0.42) : .black.opacity(0.26), in: Circle())
                .overlay(Circle().stroke(.white.opacity(runtimeSettings.microphoneMode == "disabled" ? 0.05 : 0.11), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(runtimeSettings.microphoneMode == "disabled")
        .opacity(runtimeSettings.microphoneMode == "disabled" ? 0.24 : 0.58)
        .accessibilityLabel(microphoneEnabled ? "Mute microphone" : "Unmute microphone")
    }

    private var transientStreamMessageOverlay: some View {
        Text(transientStreamMessage)
            .font(.system(size: 12, weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.94))
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(.black.opacity(0.68), in: Capsule())
            .overlay(Capsule().stroke(WebRTCMediaStreamTheme.accent.opacity(0.36), lineWidth: 1))
            .shadow(color: .black.opacity(0.36), radius: 18, x: 0, y: 8)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var hudStatsPanel: some View {
        hudSection(label: "STREAM STATS") {
            VStack(alignment: .leading, spacing: 8) {
                statsRow("Latency", formatted(latestStats?.latencyMs, suffix: " ms"))
                statsRow("Jitter", formatted(latestStats?.jitterMs, suffix: " ms"))
                statsRow("Bitrate", formatted(latestStats?.inboundBitrateMbps, suffix: " Mbps"))
                statsRow("Loss", formatted(latestStats?.packetLossPercent, suffix: "%"))
                statsRow("FPS", formatted(latestStats?.renderFps, suffix: ""))
                statsRow("Decode", formatted(latestStats?.decodeTimeMs, suffix: " ms"))
                statsRow("Drops", String(latestStats?.framesDropped ?? 0))
                statsRow("Codec", latestStats?.codec.isEmpty == false ? latestStats?.codec ?? "-" : "-")
                statsRow("Resolution", latestStats?.resolution.isEmpty == false ? latestStats?.resolution ?? "-" : "-")
            }
        }
    }

    private var hudVideoPanel: some View {
        hudSection(label: "VIDEO ENHANCEMENT") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("MetalFX Upscaling", selection: Binding(get: { runtimeSettings.upscalingMode }, set: { updateVideoEnhancement(mode: $0) })) {
                    ForEach(StreamRuntimeSettings.upscalingModes, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .font(.streamNvidia(size: 12, weight: .medium))
                .pickerStyle(.segmented)
                .tint(WebRTCMediaStreamTheme.accent)
                .disabled(!isStreamReady)
                if runtimeSettings.upscalingMode != 0 {
                    videoStepperRow("Clarity", value: runtimeSettings.upscalingSharpness, range: 0...15) { value in updateVideoEnhancement(sharpness: value) }
                    videoStepperRow("Noise Reduction", value: runtimeSettings.upscalingDenoise, range: 0...20) { value in updateVideoEnhancement(denoise: value) }
                }
                settingsRow("Active", liveEnhancementValue(latestStats?.videoEnhancementActiveTier, fallback: runtimeSettings.upscalingMode == 0 ? "Native" : "Pending"))
                settingsRow("Target", runtimeSettings.upscalingMode == 0 ? "Native" : "Display")
                settingsRow("Frame", frameTimeValue(latestStats?.videoEnhancementFrameTimeMs))
                settingsRow("Dropped", String(latestStats?.videoEnhancementDroppedFrames ?? 0))
            }
        }
    }

    private var hudTwitchPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                twitchMetricCard(title: "Account", value: twitchOverlayState.accountSummary, positive: twitchOverlayState.streamKeyAvailable)
                twitchMetricCard(title: "Chat", value: twitchOverlayState.chatState, positive: twitchOverlayState.chatState.localizedCaseInsensitiveContains("connected"))
                twitchMetricCard(title: "Events", value: twitchOverlayState.eventSubState, positive: twitchOverlayState.eventSubState.localizedCaseInsensitiveContains("connected"))
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("BROADCAST")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.52))
                    Text(twitchStatusText)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(4)
                    HStack(spacing: 10) {
                        twitchSecondaryActionButton(title: "Refresh", systemName: "arrow.clockwise") {
                            Task { @MainActor in await onTwitchHealthRefresh?() }
                        }
                    }
                    Text("Chat and event alerts are shown here inside the unified HUD.")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.54))
                }
                .frame(width: 210, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    Text("MARKERS")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.52))
                    TextField("Describe this moment", text: $twitchMarkerDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    HStack(spacing: 6) {
                        ForEach(["Highlight", "Clutch", "Boss", "Bug"], id: \.self) { preset in
                            Button(preset) { createTwitchMarker(description: preset) }
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.86))
                                .padding(.horizontal, 8)
                                .frame(height: 26)
                                .background(.white.opacity(0.08), in: Capsule())
                                .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 10) {
                        twitchSecondaryActionButton(title: "Create Marker", systemName: "bookmark.fill", action: createTwitchMarker)
                        if !twitchMarkerMessage.isEmpty {
                            Text(twitchMarkerMessage)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 14) {
                twitchChatPanel
                twitchEventsPanel
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func hudMetricCard(title: String, value: String, positive: Bool) -> some View {
        twitchMetricCard(title: title, value: value, positive: positive)
    }

    private var launchOverlay: some View {
        LinearGradient(
            colors: [WebRTCMediaStreamTheme.surface.opacity(0.98), WebRTCMediaStreamTheme.surfaceRaised.opacity(0.98)],
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
                    .foregroundStyle(WebRTCMediaStreamTheme.accentSoft.opacity(0.84))
                ProgressView()
                    .controlSize(.large)
                    .tint(WebRTCMediaStreamTheme.accent)
            }
            .padding(36)
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        }
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
                    .foregroundStyle(WebRTCMediaStreamTheme.accent)
                Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("Dismiss this overlay to resume input, pause the session, or quit the stream. Remote input is paused while this menu is open.")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                HStack(spacing: 12) {
                    Button(action: dismissQuitMenu) {
                        Text("Resume")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .frame(width: 112, height: 44)
                            .background(WebRTCMediaStreamTheme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isEndingStream)
                    Button(action: pauseFromQuitMenu) {
                        Text("Pause Stream")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 112, height: 44)
                            .background(.white.opacity(0.11), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isEndingStream)
                    Button(action: quitStreamFromMenu) {
                        Text(isEndingStream ? "Quitting..." : "Quit")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 112, height: 44)
                            .background(.white.opacity(0.11), in: Capsule())
                            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(isEndingStream)
                }
            }
            .padding(32)
            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(WebRTCMediaStreamTheme.accent.opacity(0.26), lineWidth: 1))
            .shadow(color: .black.opacity(0.62), radius: 42, x: 0, y: 20)
        }
    }

    private var twitchPanelBackground: some ShapeStyle {
        LinearGradient(colors: [.black.opacity(0.86), WebRTCMediaStreamTheme.surfaceRaised.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var twitchLiveBadge: some View {
        let live = broadcastStatus.isLive
        return HStack(spacing: 7) {
            Circle().fill(live ? WebRTCMediaStreamTheme.danger : WebRTCMediaStreamTheme.accent).frame(width: 8, height: 8)
            Text(live ? "LIVE" : (broadcastStatus.isBroadcasting ? "PUBLISHING" : "READY"))
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(.white.opacity(0.10), in: Capsule())
    }

    private var twitchChatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("CHAT")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer()
                Text(twitchOverlayState.chatState)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if twitchOverlayState.chatMessages.isEmpty {
                            Text("Waiting for Twitch chat messages.")
                                .foregroundStyle(.white.opacity(0.48))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                        ForEach(twitchOverlayState.chatMessages.suffix(18)) { message in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(message.author)
                                    .font(.system(size: 10, weight: .black, design: .rounded))
                                    .foregroundStyle(WebRTCMediaStreamTheme.accent)
                                Text(message.text)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(message.id)
                        }
                    }
                }
                .onChange(of: twitchOverlayState.chatMessages.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            .frame(height: 168)
            HStack(spacing: 8) {
                TextField("Send a message", text: $twitchChatDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button("Send") {
                    let message = twitchChatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !message.isEmpty else { return }
                    onTwitchChatSend?(message)
                    twitchChatDraft = ""
                }
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundStyle(.black)
                .frame(width: 54, height: 34)
                .background(WebRTCMediaStreamTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 286, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var twitchEventsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("EVENTS")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                Spacer()
                Text("\(twitchOverlayState.supportedAlertTypes.count) active")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.58))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if twitchOverlayState.eventAlerts.isEmpty {
                        Text(twitchOverlayState.supportedAlertTypes.isEmpty ? "No supported alert subscriptions yet." : "Waiting for Twitch events.")
                            .foregroundStyle(.white.opacity(0.48))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    ForEach(twitchOverlayState.eventAlerts.suffix(12)) { alert in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(alert.title)
                                .font(.system(size: 11, weight: .black, design: .rounded))
                                .foregroundStyle(.white)
                            Text(alert.message)
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(WebRTCMediaStreamTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
            .frame(height: 214)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func twitchMetricCard(title: String, value: String, positive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(positive ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning).frame(width: 6, height: 6)
                Text(title.uppercased())
                    .font(.streamNvidia(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.46))
            }
            Text(value)
                .font(.streamNvidia(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Color.white.opacity(0.055))
        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
    }

    private func twitchPrimaryActionButton(title: String, color: Color, foregroundColor: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.streamNvidia(size: 12, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(color.opacity(isPreparingBroadcast ? 0.58 : 0.96))
        }
        .buttonStyle(.plain)
    }

    private func twitchSecondaryActionButton(title: String, systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.streamNvidia(size: 11, weight: .bold))
                Text(title)
                    .font(.streamNvidia(size: 11, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(Color.white.opacity(0.09))
            .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
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

    private var microphoneStatusText: String {
        guard runtimeSettings.microphoneMode != "disabled" else { return "Disabled" }
        return microphoneEnabled ? "On" : "Muted"
    }

    private var recordingStatusText: String {
        switch recordingStatus {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .recording(_, let elapsedSeconds): return recordingElapsedText(elapsedSeconds)
        case .finishing: return "Saving"
        case .finished: return "Saved"
        case .failed: return "Failed"
        }
    }

    private var broadcastSummaryText: String {
        if isPreparingBroadcast { return "Preparing" }
        switch broadcastStatus {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .publishing: return "Publishing"
        case .live: return "Live"
        case .stopping: return "Stopping"
        case .failed: return "Failed"
        }
    }

    private var twitchStatusText: String {
        if isPreparingBroadcast { return "Updating Twitch title and category before publishing." }
        switch broadcastStatus {
        case .idle: return "Ready"
        case .connecting: return "Connecting"
        case .publishing(_, let elapsedSeconds, let droppedFrames, let videoBitrateKbps):
            let detail = broadcastVerificationMessage.isEmpty ? "Twitch API confirmation pending; RTMP is publishing." : broadcastVerificationMessage
            return "Publishing \(recordingElapsedText(elapsedSeconds)) · \(videoBitrateKbps) Kbps · \(droppedFrames) drops · \(detail)"
        case .live(_, let elapsedSeconds, let droppedFrames, let videoBitrateKbps): return "Live \(recordingElapsedText(elapsedSeconds)) · \(videoBitrateKbps) Kbps · \(droppedFrames) drops"
        case .stopping: return "Stopping"
        case .failed(let message): return message
        }
    }

    private func twitchPanelRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label).foregroundStyle(.white.opacity(0.54))
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }

    private func toggleUnifiedHUD() {
        setUnifiedHUDVisible(!unifiedHUDVisible)
        WebRTCMediaTelemetry.capture("webrtc.ui.hud.toggle", level: .info, message: unifiedHUDVisible ? "Unified HUD shown." : "Unified HUD hidden.", attributes: ["visible": String(unifiedHUDVisible)])
    }

    private func setUnifiedHUDVisible(_ visible: Bool) {
        unifiedHUDVisible = visible
        guard visible else { return }
        nativeView?.setPointerLocked(false)
    }

    private func toggleBroadcast() {
        guard !isPreparingBroadcast else {
            WebRTCMediaTelemetry.capture("webrtc.ui.twitch.start.ignored", level: .info, message: "Twitch broadcast start ignored while metadata preparation is active.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        if broadcastStatus.isBroadcasting {
            transport?.stopBroadcast()
            WebRTCMediaTelemetry.capture("webrtc.ui.twitch.stop", level: .info, message: "Twitch broadcast stop requested.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        guard let broadcastConfigurationProvider,
              let broadcastConfiguration = broadcastConfigurationProvider(configuration.title, configuration.applicationID, runtimeSettings.resolutionWidth, runtimeSettings.resolutionHeight, runtimeSettings.fps) else {
            broadcastStatus = .failed("Twitch is not ready. Connect Twitch in Settings.")
            return
        }
        broadcastLiveVerified = false
        broadcastVerificationMessage = ""
        broadcastForcedFailureMessage = ""
        broadcastVerificationUnavailable = false
        broadcastVerificationTask?.cancel()
        broadcastVerificationTask = nil
        isPreparingBroadcast = true
        twitchMarkerMessage = "Updating Twitch channel..."
        Task { @MainActor in
            switch await prepareBroadcastMetadata(title: configuration.title, applicationID: configuration.applicationID) {
            case .completed(let message):
                WebRTCMediaTelemetry.capture("webrtc.ui.twitch.metadata.completed", level: .info, message: "Twitch broadcast metadata preparation completed.", attributes: ["applicationID": configuration.applicationID])
                if let message, !message.isEmpty { twitchMarkerMessage = message }
            case .unavailable:
                WebRTCMediaTelemetry.capture("webrtc.ui.twitch.metadata.unavailable", level: .info, message: "Twitch broadcast metadata preparation unavailable; publishing with existing Twitch settings.", attributes: ["applicationID": configuration.applicationID])
            case .timedOut:
                twitchMarkerMessage = "Twitch metadata update timed out; publishing with existing settings."
                WebRTCMediaTelemetry.capture("webrtc.ui.twitch.metadata.timeout", level: .warning, message: twitchMarkerMessage, attributes: ["applicationID": configuration.applicationID])
            }
            guard isPreparingBroadcast else { return }
            isPreparingBroadcast = false
            WebRTCMediaTelemetry.capture("webrtc.ui.twitch.publish.start", level: .info, message: "Starting Twitch RTMP publisher after metadata preparation.", attributes: ["applicationID": configuration.applicationID])
            transport?.startBroadcast(configuration: broadcastConfiguration)
        }
        WebRTCMediaTelemetry.capture("webrtc.ui.twitch.start", level: .info, message: "Twitch broadcast metadata preparation started.", attributes: ["applicationID": configuration.applicationID])
    }

    private func prepareBroadcastMetadata(title: String, applicationID: String) async -> WebRTCMediaBroadcastPreparationResult {
        guard let onBroadcastStart else { return .unavailable }
        let gate = WebRTCMediaBroadcastPreparationGate()
        let metadataTask = Task { await gate.resolve(.completed(onBroadcastStart(title, applicationID))) }
        Task {
            try? await Task.sleep(for: .seconds(6))
            metadataTask.cancel()
            await gate.resolve(.timedOut)
        }
        return await gate.wait()
    }

    private func createTwitchMarker() {
        createTwitchMarker(description: twitchMarkerDraft.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func createTwitchMarker(description: String) {
        guard broadcastStatus.isLive else {
            twitchMarkerMessage = "Go live before creating a marker."
            WebRTCMediaTelemetry.capture("webrtc.ui.twitch.marker", level: .info, message: twitchMarkerMessage, attributes: ["applicationID": configuration.applicationID])
            return
        }
        twitchMarkerMessage = "Creating marker..."
        let markerDescription = description.nilIfEmpty ?? configuration.title.nilIfEmpty ?? "OpenNOW stream marker"
        Task { @MainActor in
            twitchMarkerMessage = await onStreamMarker?(configuration.title, configuration.applicationID, markerDescription) ?? "Marker requested at \(Date().formatted(date: .omitted, time: .standard))"
            twitchMarkerDraft = ""
        }
        WebRTCMediaTelemetry.capture("webrtc.ui.twitch.marker", level: .info, message: twitchMarkerMessage, attributes: ["applicationID": configuration.applicationID])
    }

    private func toggleRecording() {
        if recordingCanStop {
            transport?.stopRecording()
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.stop", level: .info, message: "Stream recording stop requested.", attributes: ["applicationID": configuration.applicationID])
            return
        }
        guard !recordingIsBusy else { return }
        guard let transport else {
            WebRTCMediaTelemetry.capture("webrtc.ui.recording.start.unavailable", level: .warning, message: "Stream recording start requested before transport was ready.", attributes: ["applicationID": configuration.applicationID])
            return
        }
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
        recordingStatus = .starting
        transport.startRecording(configuration: recordingConfiguration)
        WebRTCMediaTelemetry.capture("webrtc.ui.recording.start", level: .info, message: "Stream recording start requested.", attributes: ["applicationID": configuration.applicationID, "enhancedVideo": String(recordingConfiguration.enhancedVideoEnabled)])
    }

    private func recordingElapsedText(_ elapsedSeconds: Double) -> String {
        let seconds = max(0, Int(elapsedSeconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func statsRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
        }
    }

    private func settingsRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Text(value)
                .font(.streamNvidia(size: 11, weight: .bold))
                .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func videoStepperRow(_ label: String, value: Int, range: ClosedRange<Int>, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Stepper(value: Binding(get: { value }, set: { action($0) }), in: range) {
                Text(String(value))
                    .font(.streamNvidia(size: 11, weight: .bold))
                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .disabled(!isStreamReady)
        }
    }

    private func updateVideoEnhancement(mode: Int? = nil, sharpness: Int? = nil, denoise: Int? = nil, targetHeight: Int? = nil) {
        runtimeSettings.updateVideoEnhancement(mode: mode, sharpness: sharpness, denoise: denoise, targetHeight: targetHeight)
        onVideoEnhancementChange?(runtimeSettings.upscalingMode, runtimeSettings.upscalingSharpness, runtimeSettings.upscalingDenoise)
        transport?.setLocalVideoEnhancement(mode: runtimeSettings.upscalingMode, sharpness: runtimeSettings.upscalingSharpness, denoise: runtimeSettings.upscalingDenoise, targetHeight: runtimeSettings.upscalingTargetHeight)
        WebRTCMediaTelemetry.capture(
            "webrtc.ui.video_enhancement.update",
            level: .info,
            message: "Video enhancement settings updated.",
            attributes: [
                "mode": String(runtimeSettings.upscalingMode),
                "enhancementPreset": runtimeSettings.upscalingMode == 3 ? "metalfx_m1" : "off",
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
        defer { startTask = nil }
        beginStreamingPerformanceMode()
        let transport = NativeWebRTCTransport(nativeView: nativeView)
        let path = WebRTCStreamingPath(sessionProvider: sessionProvider, transport: transport, signaling: signaling)
        transport.onEnded = { message in
            handleTransportEnded(message: message)
        }
        transport.onRecordingStatusChanged = { status in
            handleRecordingStatusChanged(status)
        }
        transport.onBroadcastStatusChanged = { status in
            handleBroadcastStatusChanged(status)
        }
        nativeView.onInputEvent = { event in
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
                lastAcceptedStreamInputAt = Date()
                refreshAntiAFKMouseMovementTask()
            }
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else {
                statusMessage = "Stream launch cancelled."
                endStreamingPerformanceMode()
                return
            }
            let message = Self.message(for: error)
            statusMessage = message
            endStreamingPerformanceMode()
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

    private func handleRecordingStatusChanged(_ status: WebRTCStreamRecordingStatus) {
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

    private func logRecordingStatusChanged(_ status: WebRTCStreamRecordingStatus, previousStatus: WebRTCStreamRecordingStatus) {
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

    private func handleBroadcastStatusChanged(_ status: WebRTCLiveBroadcastStatus) {
        broadcastNotificationTask?.cancel()
        switch status {
        case .connecting:
            broadcastLiveVerified = false
            broadcastVerificationMessage = ""
            broadcastForcedFailureMessage = ""
            broadcastVerificationUnavailable = false
            broadcastVerificationTask?.cancel()
            broadcastVerificationTask = nil
            broadcastStatus = status
        case .publishing(let startedAt, let elapsedSeconds, let droppedFrames, let videoBitrateKbps):
            if broadcastLiveVerified {
                broadcastStatus = .live(startedAt: startedAt, elapsedSeconds: elapsedSeconds, droppedFrames: droppedFrames, videoBitrateKbps: videoBitrateKbps)
            } else {
                broadcastStatus = status
                startBroadcastLiveVerification()
            }
        case .live:
            broadcastLiveVerified = true
            broadcastVerificationUnavailable = false
            broadcastVerificationMessage = "Twitch confirmed this stream is live."
            broadcastStatus = status
        case .stopping:
            guard broadcastForcedFailureMessage.isEmpty else { return }
            broadcastStatus = status
        case .idle:
            broadcastVerificationTask?.cancel()
            broadcastVerificationTask = nil
            broadcastLiveVerified = false
            broadcastVerificationMessage = ""
            broadcastVerificationUnavailable = false
            if !broadcastForcedFailureMessage.isEmpty {
                let message = broadcastForcedFailureMessage
                broadcastForcedFailureMessage = ""
                broadcastStatus = .failed(message)
                scheduleBroadcastTerminalReset(for: broadcastStatus)
            } else {
                broadcastStatus = status
            }
        case .failed:
            broadcastVerificationTask?.cancel()
            broadcastVerificationTask = nil
            broadcastLiveVerified = false
            broadcastVerificationUnavailable = false
            broadcastStatus = status
            scheduleBroadcastTerminalReset(for: status)
        }
    }

    private func scheduleBroadcastTerminalReset(for status: WebRTCLiveBroadcastStatus) {
        guard status.isTerminal else { return }
        broadcastNotificationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard broadcastStatus == status else { return }
            broadcastStatus = .idle
            broadcastNotificationTask = nil
        }
    }

    private func startBroadcastLiveVerification() {
        guard !broadcastVerificationUnavailable else { return }
        guard broadcastVerificationTask == nil else { return }
        guard let onBroadcastLiveVerification else {
            broadcastVerificationMessage = "Twitch API verification is unavailable."
            broadcastVerificationUnavailable = true
            return
        }
        broadcastVerificationMessage = "Checking Twitch live status."
        broadcastVerificationTask = Task { @MainActor in
            let title = configuration.title
            let applicationID = configuration.applicationID
            let result = await withTaskGroup(of: WebRTCMediaBroadcastLiveVerificationResult.self) { group in
                group.addTask { await onBroadcastLiveVerification(title, applicationID) }
                group.addTask {
                    try? await Task.sleep(for: .seconds(8))
                    return .unavailable("Twitch API verification timed out; RTMP is still publishing.")
                }
                let result = await group.next() ?? .unavailable("Twitch API verification is unavailable.")
                group.cancelAll()
                return result
            }
            guard !Task.isCancelled else { return }
            broadcastVerificationTask = nil
            broadcastVerificationMessage = result.message
            switch result {
            case .verified:
                broadcastLiveVerified = true
                if case .publishing(let startedAt, let elapsedSeconds, let droppedFrames, let videoBitrateKbps) = broadcastStatus {
                    broadcastStatus = .live(startedAt: startedAt, elapsedSeconds: elapsedSeconds, droppedFrames: droppedFrames, videoBitrateKbps: videoBitrateKbps)
                }
            case .unavailable:
                broadcastLiveVerified = false
                broadcastVerificationUnavailable = false
                if case .publishing = broadcastStatus {
                    broadcastVerificationTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled else { return }
                        broadcastVerificationTask = nil
                        startBroadcastLiveVerification()
                    }
                } else {
                    broadcastVerificationUnavailable = true
                }
            case .notLive(let message):
                broadcastLiveVerified = false
                broadcastVerificationUnavailable = false
                broadcastForcedFailureMessage = message
                transport?.stopBroadcast()
                handleBroadcastStatusChanged(.failed(message))
            }
        }
    }

    private func inputAction(for event: UserInputEvent) -> StreamInputAction {
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

    private func shouldAcceptInputWhenInactive() -> Bool {
        guard runtimeSettings.suppressInputWhenInactive else { return true }
        guard let nativeView else { return false }
        return nativeView.window?.isKeyWindow == true && NSApplication.shared.isActive
    }

    private func microphoneToggleAction(for keyboard: KeyboardEvent) -> StreamInputAction? {
        guard keyboard.modifiers.intersection(Self.hotkeyModifierMask) == .command, Int(keyboard.keyCode) == Self.microphoneToggleKeyCode else { return nil }
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
        case .toggleUnifiedHUD:
            toggleUnifiedHUD()
        case .toggleMicrophone:
            toggleMicrophone()
        case .toggleRecording:
            toggleRecording()
        case .toggleAntiAFK:
            toggleAntiAFKMouseMovement()
        case .showQuitMenu:
            showQuitMenu()
        }
    }

    private func toggleAntiAFKMouseMovement() {
        runtimeSettings.antiAFKMouseMovementEnabled.toggle()
        onAntiAFKStateChange?(runtimeSettings.antiAFKMouseMovementEnabled)
        refreshAntiAFKMouseMovementTask()
        showTransientStreamMessage(runtimeSettings.antiAFKMouseMovementEnabled ? "Anti-AFK On" : "Anti-AFK Off")
        WebRTCMediaTelemetry.capture("webrtc.ui.anti_afk.toggle", level: .info, message: runtimeSettings.antiAFKMouseMovementEnabled ? "Anti-AFK mouse movement enabled." : "Anti-AFK mouse movement disabled.", attributes: ["enabled": String(runtimeSettings.antiAFKMouseMovementEnabled)])
    }

    private func refreshAntiAFKMouseMovementTask() {
        guard isStreamReady, runtimeSettings.antiAFKMouseMovementEnabled else {
            antiAFKMouseMovementTask?.cancel()
            antiAFKMouseMovementTask = nil
            return
        }
        guard antiAFKMouseMovementTask == nil else { return }
        antiAFKMouseMovementTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                sendAntiAFKMouseMovement()
            }
        }
    }

    private func sendAntiAFKMouseMovement() {
        guard isStreamReady, runtimeSettings.antiAFKMouseMovementEnabled, !isEndingStream, !didEndStream, !quitMenuVisible, let activeTransport = transport else { return }
        guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= Self.antiAFKIdleThresholdSeconds else { return }
        let delta = Self.randomAntiAFKMouseDelta()
        activeTransport.sendNow(Self.mouseMove(deltaX: delta.x, deltaY: delta.y))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard isStreamReady, runtimeSettings.antiAFKMouseMovementEnabled, !isEndingStream, !didEndStream, !quitMenuVisible, let transport else { return }
            guard Date().timeIntervalSince(lastAcceptedStreamInputAt) >= Self.antiAFKIdleThresholdSeconds else { return }
            transport.sendNow(Self.mouseMove(deltaX: -delta.x, deltaY: -delta.y))
        }
    }

    private func showTransientStreamMessage(_ message: String) {
        transientStreamMessageTask?.cancel()
        transientStreamMessage = message
        transientStreamMessageTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            transientStreamMessage = ""
            transientStreamMessageTask = nil
        }
    }

    private static func randomAntiAFKMouseDelta() -> (x: Int16, y: Int16) {
        var x = Int16(Int.random(in: -5...5))
        let y = Int16(Int.random(in: -5...5))
        if x == 0 && y == 0 { x = 1 }
        return (x, y)
    }

    private static let antiAFKIdleThresholdSeconds: TimeInterval = 210

    private static func mouseMove(deltaX: Int16, deltaY: Int16) -> UserInputEvent {
        .mouse(.moved(deviceID: "mouse", deltaX: deltaX, deltaY: deltaY, timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)))
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
            setUnifiedHUDVisible(false)
        }
    }

    private func registerStreamLifecycle() {
        WebRTCMediaStreamLifecycle.activate(
            configuration.id,
            quitRequestHandler: { completion in
                showQuitMenu(completion: completion)
                return true
            },
            commandHandler: handle
        )
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

    private func dismissQuitMenu() {
        guard !isEndingStream else { return }
        quitMenuVisible = false
        let completion = pendingApplicationQuitCompletion
        pendingApplicationQuitCompletion = nil
        WebRTCMediaTelemetry.capture("webrtc.ui.quit_menu.dismiss", level: .info, message: "Stream quit menu dismissed.", attributes: ["applicationID": configuration.applicationID])
        completion?(false)
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
        antiAFKMouseMovementTask?.cancel()
        antiAFKMouseMovementTask = nil
        guard let path else { return fallbackReport }
        defer { Task { @MainActor in endStreamingPerformanceMode() } }
        do {
            return try await path.stop(reason: reason, message: message)
        } catch {
            return StreamReport(title: configuration.title, success: false, reason: .failed, message: Self.message(for: error), durationSeconds: 0, metadata: ["applicationID": configuration.applicationID])
        }
    }

    private func stopStream() {
        endStreamingPerformanceMode()
        WebRTCMediaStreamLifecycle.deactivate(configuration.id)
        pendingApplicationQuitCompletion?(false)
        pendingApplicationQuitCompletion = nil
        startTask?.cancel()
        startTask = nil
        statsTask?.cancel()
        statsTask = nil
        antiAFKMouseMovementTask?.cancel()
        antiAFKMouseMovementTask = nil
        recordingNotificationTask?.cancel()
        recordingNotificationTask = nil
        broadcastNotificationTask?.cancel()
        broadcastNotificationTask = nil
        broadcastVerificationTask?.cancel()
        broadcastVerificationTask = nil
        transientStreamMessageTask?.cancel()
        transientStreamMessageTask = nil
        transientStreamMessage = ""
        isPreparingBroadcast = false
        nativeView?.setPointerLocked(false)
        microphoneEnabled = false
        transport?.setMicrophoneEnabled(false)
        transport?.stopRecording()
        guard !didEndStream else { return }
        didEndStream = true
        if let path { Task { try? await path.stop(reason: .userRequested, message: "Stream view closed.") } }
    }

    private func beginStreamingPerformanceMode() {
        guard streamingPerformanceActivity == nil else { return }
        streamingPerformanceActivity = ProcessInfo.processInfo.beginActivity(options: streamingPerformanceActivityOptions, reason: "OpenNOW active cloud gaming stream")
        WebRTCMediaTelemetry.capture("webrtc.stream.performance_mode.begin", level: .info, message: "Streaming performance mode enabled.", attributes: ["applicationID": configuration.applicationID, "preventDisplaySleep": String(preventDisplaySleep)])
    }

    private func endStreamingPerformanceMode() {
        guard let streamingPerformanceActivity else { return }
        ProcessInfo.processInfo.endActivity(streamingPerformanceActivity)
        self.streamingPerformanceActivity = nil
        WebRTCMediaTelemetry.capture("webrtc.stream.performance_mode.end", level: .info, message: "Streaming performance mode disabled.", attributes: ["applicationID": configuration.applicationID])
    }

    private func refreshStreamingPerformanceMode() {
        guard streamingPerformanceActivity != nil else { return }
        endStreamingPerformanceMode()
        beginStreamingPerformanceMode()
    }

    private var streamingPerformanceActivityOptions: ProcessInfo.ActivityOptions {
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .latencyCritical, .idleSystemSleepDisabled]
        if preventDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        return options
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription
    }

    private static let hotkeyModifierMask: KeyboardModifiers = [.shift, .control, .option, .command]
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
        VideoEnhancementMode(label: "MetalFX", value: 3),
    ]

    var resolutionWidth = 1920
    var resolutionHeight = 1080
    var fps = 60
    var microphoneMode = "disabled"
    var microphonePushToTalkKeyCode = 9
    var microphonePushToTalkModifierMask = 0
    var suppressInputWhenInactive = true
    var directMouseInput = true
    var antiAFKMouseMovementEnabled = false
    var upscalingMode = 0
    var upscalingSharpness = 10
    var upscalingDenoise = 0
    var upscalingTargetHeight = 2160
    var recordingVideoBitrateMbps = 0
    var recordingAudioBitrateKbps = 160
    var recordingEnhancedVideoEnabled = true

    var upscalingModeLabel: String {
        switch upscalingMode {
        case 0: return "Off"
        case 3: return "MetalFX"
        default: return "Mode \(upscalingMode)"
        }
    }

    init() {}

    mutating func updateVideoEnhancement(mode: Int? = nil, sharpness: Int? = nil, denoise: Int? = nil, targetHeight: Int? = nil) {
        if let mode {
            upscalingMode = Self.normalizedUpscalingMode(mode)
        }
        if let sharpness { upscalingSharpness = min(max(sharpness, 0), 15) }
        if let denoise { upscalingDenoise = min(max(denoise, 0), 20) }
        if let targetHeight { upscalingTargetHeight = targetHeight > 0 ? targetHeight : 2160 }
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
        antiAFKMouseMovementEnabled = Self.bool(dictionary["antiAFKMouseMovementEnabled"])
        upscalingMode = Self.normalizedUpscalingMode(Self.int(dictionary["upscalingMode"]))
        upscalingSharpness = Self.int(dictionary["upscalingSharpness"], fallback: 10)
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

    private static func normalizedUpscalingMode(_ mode: Int) -> Int {
        switch mode {
        case 0: return 0
        case 1...4: return 3
        default: return 0
        }
    }
}

private struct VideoEnhancementMode: Equatable {
    let label: String
    let value: Int
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
