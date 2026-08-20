import AppKit
import Combine
import GameController
import Foundation
import SwiftUI

public typealias WebRTCMediaStreamProgressCallback = @MainActor @Sendable (_ progress: StreamProgress) -> Void
public typealias WebRTCMediaStreamEndCallback = @MainActor @Sendable (_ success: Bool, _ message: String, _ report: StreamReport?) -> Void
public typealias WebRTCMediaAntiAFKStateChangeCallback = @MainActor @Sendable (_ enabled: Bool) -> Void
public typealias WebRTCMediaVideoEnhancementChangeCallback = @MainActor @Sendable (_ mode: Int, _ sharpness: Int, _ denoise: Int) -> Void

@MainActor
public struct WebRTCMediaStreamSurface: View {
    private let configuration: StreamLaunchConfiguration
    private let sessionProvider: any StreamSessionProvider
    private let signaling: (any StreamSignalingChannel)?
    private let onAntiAFKStateChange: WebRTCMediaAntiAFKStateChangeCallback?
    private let onVideoEnhancementChange: WebRTCMediaVideoEnhancementChangeCallback?
    private let preventDisplaySleep: Bool
    private let onProgress: WebRTCMediaStreamProgressCallback?
    private let onEnd: WebRTCMediaStreamEndCallback
    private let sidebarCapabilities = StreamSidebarCapabilities.webRTC

    @State private var path: WebRTCStreamingPath?
    @State private var transport: NativeWebRTCTransport?
    @State private var hasStarted = false
    @State private var isStreamReady = false
    @State private var loadingStepIndex = -1
    @State private var pointerLocked = false
    @State private var statsVisible = false
    @State private var unifiedHUDVisible = false
    @State private var restorePointerLockOnHUDHide = false
    @State private var quitMenuVisible = false
    @State private var showingControllerMapping = false
    @State private var isEndingStream = false
    @State private var didEndStream = false
    @State private var latestStats: OPNStreamStatsSnapshot?
    @State private var statsTask: Task<Void, Never>?
    @State private var sessionLimitUpdateTask: Task<Void, Never>?
    @State private var startTask: Task<Void, Never>?
    @State private var nativeView: NativeWebRTCStreamView?
    @State private var pendingApplicationQuitCompletion: WebRTCMediaStreamQuitDecisionHandler?
    @State private var runtimeSettings = StreamRuntimeSettings()
    @State private var microphoneEnabled = false
    @State private var recordingStatus = WebRTCStreamRecordingStatus.idle
    @State private var recordingNotificationTask: Task<Void, Never>?
    @State private var antiAFKMouseMovementTask: Task<Void, Never>?
    @State private var lastAcceptedStreamInputAt = Date()
    @State private var transientStreamMessage = ""
    @State private var transientStreamMessageTask: Task<Void, Never>?
    @State private var streamingPerformanceActivity: (any NSObjectProtocol)?
    @State private var remoteCoOpHostSession = OPNRemoteCoOpHostSession()
    @State private var remoteCoOpHostCoordinator: OPNRemoteCoOpHostCoordinator?
    @State private var remoteCoOpSignalingSession: (any OPNRemoteCoOpSignalingSession)?
    @State private var remoteCoOpPeerController: OPNRemoteCoOpHostPeerController?
    @State private var remoteCoOpVideoRelay = OPNRemoteCoOpHostVideoRelay()
    @State private var remoteCoOpAudioRelay = OPNRemoteCoOpHostAudioRelay()
    @State private var remoteCoOpListenTask: Task<Void, Never>?
    @State private var remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: OPNRemoteCoOpPreferencesStore.load(), invite: nil, participants: [])
    @State private var remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: OPNRemoteCoOpPreferencesStore.load().transportMode, latencyMode: OPNRemoteCoOpPreferencesStore.load().latencyMode)
    @State private var remoteCoOpMessage = ""
    @State private var controllerBatteries: [ControllerBatteryInfo] = []
    @State private var batteryAlertTracker = ControllerBatteryAlertTracker()
    @State private var hudFocusID: String?
    @State private var quitMenuFocusIndex = 0
    @State private var hudGamepadTracker = StreamHUDGamepadTracker()
    @AppStorage(MacForceNowInterfacePreferences.uiScaleKey) private var uiScale = MacForceNowInterfacePreferences.defaultUIScale
    @State private var sessionLimit: StreamSessionSidebarLimit?

    public init(configuration: StreamLaunchConfiguration,
                sessionProvider: any StreamSessionProvider,
                signaling: (any StreamSignalingChannel)? = nil,
                onAntiAFKStateChange: WebRTCMediaAntiAFKStateChangeCallback? = nil,
                onVideoEnhancementChange: WebRTCMediaVideoEnhancementChangeCallback? = nil,
                preventDisplaySleep: Bool = true,
                onProgress: WebRTCMediaStreamProgressCallback? = nil,
                onEnd: @escaping WebRTCMediaStreamEndCallback) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.signaling = signaling
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
                view.shouldHandleCommand = { _ in true }
                view.onCommand = { command in
                    handle(command)
                }
                if startTask == nil {
                    startTask = Task { await startIfNeeded(nativeView: view) }
                }
            }
            hudChrome
                .macForceNowInterfaceScale(uiScale)
        }
        .background(Color.black)
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .onAppear {
            registerStreamLifecycle()
            refreshRemoteCoOpState()
        }
        // A `Timer.publish` stored on the view would be rebuilt on every
        // re-render, resetting the interval before it ever fires.
        .task {
            while !Task.isCancelled {
                refreshControllerBatteries()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onDisappear { stopStream() }
        .onChange(of: preventDisplaySleep) { _, _ in refreshStreamingPerformanceMode() }
        .sheet(isPresented: $showingControllerMapping) {
            SteamControllerMappingView()
        }
    }

    private func openControllerMapping() {
        setUnifiedHUDVisible(false)
        showingControllerMapping = true
    }

    @ViewBuilder
    private var hudChrome: some View {
        if !isStreamReady { launchOverlay }
        if isStreamReady && !quitMenuVisible { microphoneToggleOverlay }
        if statsVisible { statsHUD }
        if unifiedHUDVisible { unifiedHUD }
        if isStreamReady { sessionLimitCountdownOverlay }
        if !transientStreamMessage.isEmpty { transientStreamMessageOverlay }
        if quitMenuVisible { quitMenu }
    }

    private var statsHUD: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                statsCompactBox(value: "--", label: "FPS", color: WebRTCMediaStreamTheme.textPrimary)
                statsVerticalDivider
                statsCompactBox(value: wholeNumber(latestStats?.renderFps), label: "FPS", color: fpsColor)
                statsVerticalDivider
                statsCompactBox(value: wholeNumber(latestStats?.latencyMs), label: "MS", color: latencyColor)
            }
            .frame(height: 48)

            statsHorizontalDivider

            VStack(alignment: .leading, spacing: 5) {
                statsStandardRow(label: "Frame Loss", value: String(latestStats?.framesDropped ?? 0), detail: "(0 Total)", color: frameLossColor)
                statsStandardRow(label: "Packet Loss", value: percentage(latestStats?.packetLossPercent), detail: packetLossTotalText, color: packetLossColor)
                statsStandardRow(label: "Bandwidth Used", value: megabits(latestStats?.inboundBitrateMbps), detail: "Mbps", color: WebRTCMediaStreamTheme.textPrimary)
                statsStandardRow(label: "Resolution", value: nonEmpty(latestStats?.resolution), detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
                statsStandardRow(label: "Codec", value: nonEmpty(latestStats?.codec), detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
                statsStandardRow(label: "Server Location", value: "--", detail: nil, color: WebRTCMediaStreamTheme.textPrimary)
            }
        }
        .padding(10)
        .frame(width: 244, alignment: .topLeading)
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
                        hudInputPanel
                        hudNetworkPanel
                        hudStatsPanel
                        if remoteCoOpSnapshot.preferences.isAlphaOptedIn {
                            hudRemoteCoOpPanel
                        }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white.opacity(0.055))
    }

    private func statsCompactBox(value: String, label: String, color: Color) -> some View {
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

    private var statsVerticalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private var statsHorizontalDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(height: 1)
    }

    private func statsStandardRow(label: String, value: String, detail: String?, color: Color) -> some View {
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

    private var hudDockHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GFN")
                        .font(.streamNvidia(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text("HUD")
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
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(WebRTCMediaStreamTheme.appBar)
    }

    private var hudStatusPanel: some View {
        StreamHUDWrappingRow(minimumItemWidth: 84) {
            hudMetricCard(title: "Mic", value: microphoneStatusText, positive: microphoneEnabled && runtimeSettings.microphoneMode != "disabled")
            hudMetricCard(title: "Rec", value: recordingStatusText, positive: recordingStatus.isRecording)
            hudMetricCard(title: "AFK", value: runtimeSettings.antiAFKMouseMovementEnabled ? "On" : "Off", positive: runtimeSettings.antiAFKMouseMovementEnabled)
            if sessionLimit != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    hudMetricCard(title: "Session", value: sessionLimitHUDText(at: context.date), positive: sessionLimitIsHealthy(at: context.date))
                }
            }
            if remoteCoOpSnapshot.preferences.isAlphaOptedIn {
                hudMetricCard(title: "Co-Op", value: remoteCoOpSummaryText, positive: remoteCoOpSnapshot.invite != nil && remoteCoOpSnapshot.preferences.isAvailable)
            }
            ForEach(controllerBatteries.sorted { $0.label < $1.label }) { battery in
                StreamHUDBatteryCard(label: battery.label, level: battery.level, charging: battery.charging)
            }
        }
    }

    private var sessionLimitCountdownOverlay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let sessionLimit, sessionLimit.remainingSeconds(at: context.date) <= 30 {
                VStack(spacing: 16) {
                    Text("FREE SESSION ENDS IN")
                        .font(.streamNvidia(size: 12, weight: .bold))
                        .tracking(2.2)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text(sessionLimitCountdownText(at: context.date))
                        .font(.system(size: 74, weight: .black, design: .monospaced))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("Save progress now. GeForce NOW may close this session when the timer reaches zero.")
                        .font(.streamNvidia(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 28)
                .background(.black.opacity(0.76), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(WebRTCMediaStreamTheme.accent.opacity(0.42), lineWidth: 1))
                .shadow(color: .black.opacity(0.64), radius: 30, x: 0, y: 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var hudShortcutFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WebRTCMediaStreamTheme.accent)
                Text(Date(), style: .time)
                    .font(.streamNvidia(size: 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Date(), style: .time))
            Text("⌘G HUD   ⌘M Mic   ⌘R Rec   ⌘K AFK   ⌘Q Quit")
                .font(.streamNvidia(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private var hudControlsPanel: some View {
        hudSection(label: "CONTROLS", spacing: 8) {
            StreamHUDWrappingRow(minimumItemWidth: 42, fixedItemWidth: 42) {
                StreamHUDActionRow(
                    title: microphoneEnabled ? "Mute microphone" : "Unmute microphone",
                    subtitle: microphoneStatusText,
                    systemName: microphoneEnabled ? "mic.slash.fill" : "mic.fill",
                    isActive: microphoneEnabled && runtimeSettings.microphoneMode != "disabled",
                    isDisabled: !sidebarCapabilities.supports(.microphone) || runtimeSettings.microphoneMode == "disabled",
                    isFocused: hudFocusID == "microphone",
                    action: toggleMicrophone
                )
                StreamHUDActionRow(
                    title: recordingCanStop ? "Stop Recording" : "Record",
                    subtitle: recordingStatusText,
                    systemName: "record.circle",
                    isActive: recordingStatus.isRecording,
                    isDisabled: !sidebarCapabilities.supports(.recording) || !isStreamReady || recordingIsBusy,
                    isFocused: hudFocusID == "recording",
                    action: toggleRecording
                )
                StreamHUDActionRow(
                    title: runtimeSettings.antiAFKMouseMovementEnabled ? "Disable Anti-AFK" : "Enable Anti-AFK",
                    subtitle: runtimeSettings.antiAFKMouseMovementEnabled ? "Active" : "Idle",
                    systemName: "cursorarrow.motionlines",
                    isActive: runtimeSettings.antiAFKMouseMovementEnabled,
                    isDisabled: !sidebarCapabilities.supports(.antiAFK) || !isStreamReady,
                    isFocused: hudFocusID == "anti-afk",
                    action: toggleAntiAFKMouseMovement
                )
                StreamHUDActionRow(
                    title: statsVisible ? "Hide Floating Stats" : "Show Floating Stats",
                    subtitle: "Detailed overlay",
                    systemName: "chart.line.uptrend.xyaxis",
                    isActive: statsVisible,
                    isDisabled: false,
                    action: toggleStatsHUD
                )
            }
        }
    }

    private var hudInputPanel: some View {
        hudSection(label: "INPUT", spacing: 8) {
            HStack(spacing: 8) {
                StreamHUDActionRow(
                    title: "Paste Clipboard",
                    subtitle: "Send text to stream",
                    systemName: "doc.on.clipboard",
                    isActive: false,
                    isDisabled: !clipboardTextAvailable || !isStreamReady,
                    action: pasteClipboardIntoStream
                )
                StreamHUDActionRow(
                    title: pointerLocked ? "Release Mouse" : "Capture Mouse",
                    subtitle: pointerLocked ? "Pointer locked" : "Click stream also captures",
                    systemName: pointerLocked ? "cursorarrow.slash" : "cursorarrow.click",
                    isActive: pointerLocked,
                    isDisabled: !isStreamReady || !runtimeSettings.directMouseInput,
                    action: togglePointerLockFromHUD
                )
                StreamHUDActionRow(
                    title: "Toggle Full Screen",
                    subtitle: "Window full screen",
                    systemName: "arrow.up.left.and.arrow.down.right",
                    isActive: nativeView?.window?.styleMask.contains(.fullScreen) == true,
                    isDisabled: nativeView?.window == nil,
                    action: toggleFullScreenFromHUD
                )
                StreamHUDActionRow(
                    title: "Controller Mapping",
                    subtitle: "Steam Controller grip binds",
                    systemName: "gamecontroller",
                    isActive: false,
                    isDisabled: false,
                    isFocused: hudFocusID == "controller-mapping",
                    action: openControllerMapping
                )
                StreamHUDActionRow(
                    title: "Quit Menu",
                    subtitle: "End session",
                    systemName: "power",
                    isActive: false,
                    isDisabled: false,
                    isFocused: hudFocusID == "quit",
                    action: { showQuitMenu() }
                )
            }
            settingsRow("Mouse", pointerLocked ? "Captured" : (runtimeSettings.directMouseInput ? "Available" : "Relative input off"))
            settingsRow("Clipboard", clipboardTextAvailable ? "Ready" : "Empty")
        }
    }

    private var hudNetworkPanel: some View {
        hudSection(label: "NETWORK", spacing: 8) {
            StreamHUDWrappingRow(minimumItemWidth: 84) {
                hudMetricCard(title: "Health", value: networkHealthText, positive: networkHealthIsGood)
                hudMetricCard(title: "Latency", value: formatted(latestStats?.latencyMs, suffix: " ms"), positive: (latestStats?.latencyMs ?? 0) < 90)
                hudMetricCard(title: "Loss", value: formatted(latestStats?.packetLossPercent, suffix: "%"), positive: (latestStats?.packetLossPercent ?? 0) < 1)
            }
            if !networkWarningText.isEmpty {
                Text(networkWarningText)
                    .font(.streamNvidia(size: 11, weight: .medium))
                    .foregroundStyle(WebRTCMediaStreamTheme.warning)
                    .lineLimit(2)
            }
        }
    }

    private var hudRemoteCoOpPanel: some View {
        hudSection(label: "CO-OP", spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(remoteCoOpTitle)
                            .font(.streamNvidia(size: 14, weight: .bold))
                            .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        Text(remoteCoOpSubtitle)
                            .font(.streamNvidia(size: 11, weight: .medium))
                            .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(remoteCoOpSnapshot.preferences.transportMode.label.uppercased())
                        .font(.streamNvidia(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(remoteCoOpSnapshot.preferences.transportMode == .relayOnly ? WebRTCMediaStreamTheme.warning : WebRTCMediaStreamTheme.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(Color.white.opacity(0.07))
                        .overlay { Rectangle().stroke(WebRTCMediaStreamTheme.divider, lineWidth: 1) }
                }
                HStack(spacing: 8) {
                    StreamHUDActionRow(
                        title: remoteCoOpSnapshot.invite == nil ? "Create Invite" : "End Invite",
                        subtitle: remoteCoOpInviteActionSubtitle,
                        systemName: remoteCoOpSnapshot.invite == nil ? "person.badge.plus" : "person.crop.circle.badge.xmark",
                        isActive: remoteCoOpSnapshot.invite != nil,
                        isDisabled: !remoteCoOpSnapshot.preferences.isAvailable || remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots == 0 || !isStreamReady,
                        isFocused: hudFocusID == "coop-invite",
                        action: remoteCoOpSnapshot.invite == nil ? startRemoteCoOpInvite : stopRemoteCoOpInvite
                    )
                    if remoteCoOpSnapshot.invite != nil {
                        StreamHUDActionRow(
                            title: "Copy Invite",
                            subtitle: remoteCoOpInviteCode,
                            systemName: "doc.on.doc",
                            isActive: false,
                            isDisabled: false,
                            isFocused: hudFocusID == "coop-copy",
                            action: copyRemoteCoOpInvite
                        )
                    }
                    Spacer(minLength: 0)
                }
                settingsRow("Slots", "\(remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots)")
                settingsRow("Quality", remoteCoOpSnapshot.preferences.qualityPreset.label)
                settingsRow("Latency", remoteCoOpSnapshot.preferences.latencyMode.label)
                settingsRow("Details", remoteCoOpSnapshot.preferences.hideGuestInviteDetails ? "Hidden" : "Visible")
                if !remoteCoOpMessage.isEmpty {
                    Text(remoteCoOpMessage)
                        .font(.streamNvidia(size: 11, weight: .medium))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .lineLimit(1)
                }
                if !remoteCoOpSnapshot.participants.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(remoteCoOpSnapshot.participants) { participant in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(participant.connectionState == .connected ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning)
                                    .frame(width: 7, height: 7)
                                Text(participant.displayName)
                                    .font(.streamNvidia(size: 11, weight: .bold))
                                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                                Spacer(minLength: 8)
                                Text(participant.playerIndex.map { "P\($0 + 1)" } ?? participant.connectionState.rawValue)
                                    .font(.streamNvidia(size: 10, weight: .bold))
                                    .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
                                if participant.connectionState == .waitingForApproval {
                                    participantIconButton(systemName: "checkmark", label: "Approve guest", color: WebRTCMediaStreamTheme.accent) {
                                        approveRemoteCoOpParticipant(participant.id)
                                    }
                                }
                                participantIconButton(systemName: "xmark", label: "Remove guest", color: WebRTCMediaStreamTheme.danger) {
                                    removeRemoteCoOpParticipant(participant.id)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func hudSection<Content: View>(label: String, spacing: CGFloat = 10, @ViewBuilder content: () -> Content) -> some View {
        StreamHUDSection(label: label, spacing: spacing, content: content)
    }

    private func participantIconButton(systemName: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.streamNvidia(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.07))
                .overlay { Rectangle().stroke(color.opacity(0.32), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
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
        hudSection(label: "STATS") {
            VStack(alignment: .leading, spacing: 8) {
                statsRow("Transport", latestStats?.transport.isEmpty == false ? "WebRTC · \(latestStats?.transport ?? "")" : "WebRTC")
                statsRow("Latency", formatted(latestStats?.latencyMs, suffix: " ms"))
                statsRow("Jitter", formatted(latestStats?.jitterMs, suffix: " ms"))
                statsRow("Bitrate", formatted(latestStats?.inboundBitrateMbps, suffix: " Mbps"))
                statsRow("Loss", formatted(latestStats?.packetLossPercent, suffix: "%"))
                statsRow("FPS", formatted(latestStats?.renderFps, suffix: ""))
                statsRow("Decode", formatted(latestStats?.decodeTimeMs, suffix: " ms"))
                statsRow("Drops", String(latestStats?.framesDropped ?? 0))
                statsRow("Codec", latestStats?.codec.isEmpty == false ? latestStats?.codec ?? "-" : "-")
                statsRow("Resolution", latestStats?.resolution.isEmpty == false ? latestStats?.resolution ?? "-" : "-")
                statsRow("Decoded", latestStats?.videoEnhancementSourceResolution.isEmpty == false ? latestStats?.videoEnhancementSourceResolution ?? "-" : "-")
            }
        }
    }

    private var hudVideoPanel: some View {
        hudSection(label: "VIDEO") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("MetalFX Upscaling", selection: Binding(get: { runtimeSettings.upscalingMode }, set: { updateVideoEnhancement(mode: $0) })) {
                    ForEach(StreamRuntimeSettings.upscalingModes, id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .font(.streamNvidia(size: 12, weight: .medium))
                .pickerStyle(.segmented)
                .tint(WebRTCMediaStreamTheme.accent)
                .disabled(!sidebarCapabilities.supports(.videoEnhancement) || !isStreamReady)
                if runtimeSettings.upscalingMode != 0 {
                    videoStepperRow("Clarity", value: runtimeSettings.upscalingSharpness, range: 0...15) { value in updateVideoEnhancement(sharpness: value) }
                    videoStepperRow("Noise Reduction", value: runtimeSettings.upscalingDenoise, range: 0...20) { value in updateVideoEnhancement(denoise: value) }
                }
                StreamHUDDropdown(
                    label: "Pillarbox Fill",
                    options: OPNPillarboxFillMode.pickerCases.map { ($0.rawValue, $0.label) },
                    selection: runtimeSettings.pillarboxFillMode,
                    isDisabled: !isStreamReady,
                    onSelect: { updateVideoEnhancement(pillarboxFillMode: $0) }
                )
                if OPNPillarboxFillMode.from(runtimeSettings.pillarboxFillMode).usesDim {
                    videoStepperRow("Fill Dim", value: runtimeSettings.pillarboxFillDim, range: 0...100, step: 5) { value in
                        updateVideoEnhancement(pillarboxFillDim: value)
                    }
                }
                settingsRow("Active", liveEnhancementValue(latestStats?.videoEnhancementActiveTier, fallback: runtimeSettings.upscalingMode == 0 ? "Native" : "Pending"))
                settingsRow("Target", runtimeSettings.upscalingMode == 0 ? "Native" : "Display")
                settingsRow("Frame", frameTimeValue(latestStats?.videoEnhancementFrameTimeMs))
                settingsRow("Dropped", String(latestStats?.videoEnhancementDroppedFrames ?? 0))
            }
        }
    }

    private func hudMetricCard(title: String, value: String, positive: Bool) -> some View {
        StreamHUDMetricCard(title: title, value: value, positive: positive)
    }

    private var launchOverlay: some View {
        StreamLaunchLoadingScreen(
            title: configuration.title,
            stage: StreamLaunchLoadingStage.label(stepIndex: loadingStepIndex),
            artworkURL: configuration.loadingArtworkURL
        ) { EmptyView() }
    }

    private var quitMenu: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.54))
                .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("STREAM PAUSED")
                        .font(.streamNvidia(size: 10, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(WebRTCMediaStreamTheme.accent)
                    Text(configuration.title.isEmpty ? "GeForce NOW" : configuration.title)
                        .font(.streamNvidia(size: 20, weight: .bold))
                        .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WebRTCMediaStreamTheme.appBar)
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.divider)
                    .frame(height: 1)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Dismiss this overlay to resume input, pause the session, or quit the stream. Remote input is paused while this menu is open.")
                        .font(.streamNvidia(size: 12, weight: .medium))
                        .foregroundStyle(WebRTCMediaStreamTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        StreamQuitMenuButton(
                            title: "Resume",
                            isPrimary: true,
                            isFocused: quitMenuFocusIndex == 0,
                            isDisabled: isEndingStream,
                            action: dismissQuitMenu
                        )
                        .keyboardShortcut(.cancelAction)
                        StreamQuitMenuButton(
                            title: "Pause Stream",
                            isPrimary: false,
                            isFocused: quitMenuFocusIndex == 1,
                            isDisabled: isEndingStream,
                            action: pauseFromQuitMenu
                        )
                        StreamQuitMenuButton(
                            title: isEndingStream ? "Quitting..." : "Quit",
                            isPrimary: false,
                            isFocused: quitMenuFocusIndex == 2,
                            isDisabled: isEndingStream,
                            action: quitStreamFromMenu
                        )
                    }
                }
                .padding(18)
            }
            .frame(width: 440)
            .background(WebRTCMediaStreamTheme.panel.opacity(0.985))
            .overlay {
                Rectangle()
                    .stroke(WebRTCMediaStreamTheme.accent.opacity(0.28), lineWidth: 1)
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(WebRTCMediaStreamTheme.accent)
                    .frame(height: 2)
            }
            .shadow(color: .black.opacity(0.58), radius: 28, x: 0, y: 20)
        }
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

    private var fpsColor: Color {
        guard let latestStats, latestStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestStats.renderFps >= 55 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    private var latencyColor: Color {
        guard let latestStats, latestStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        if latestStats.latencyMs >= 120 { return WebRTCMediaStreamTheme.danger }
        if latestStats.latencyMs >= 90 { return WebRTCMediaStreamTheme.warning }
        return WebRTCMediaStreamTheme.accent
    }

    private var frameLossColor: Color {
        guard let latestStats, latestStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestStats.framesDropped == 0 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    private var packetLossColor: Color {
        guard let latestStats, latestStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        if latestStats.packetLossPercent >= 2 { return WebRTCMediaStreamTheme.danger }
        if latestStats.packetLossPercent >= 1 { return WebRTCMediaStreamTheme.warning }
        return WebRTCMediaStreamTheme.accent
    }

    private var packetLossTotalText: String {
        "(\(latestStats?.packetsLost ?? 0) Total)"
    }

    private func wholeNumber(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    private func percentage(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.1f%%", value)
    }

    private func megabits(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    private func nonEmpty(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "--" }
        return value
    }

    private func sessionLimitHUDText(at date: Date) -> String {
        guard let sessionLimit else { return "Unlimited" }
        return sessionLimitDurationText(sessionLimit.remainingSeconds(at: date))
    }

    private func sessionLimitCountdownText(at date: Date) -> String {
        guard let sessionLimit else { return "0:00" }
        return sessionLimitDurationText(sessionLimit.remainingSeconds(at: date))
    }

    private func sessionLimitIsHealthy(at date: Date) -> Bool {
        guard let sessionLimit else { return true }
        return sessionLimit.remainingSeconds(at: date) > 300
    }

    private func sessionLimitDurationText(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let remainingSeconds = clamped % 60
        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }

    private var remoteCoOpSummaryText: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Off" }
        guard remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots > 0 else { return "No Slot" }
        guard let invite = remoteCoOpSnapshot.invite else { return "Ready" }
        if invite.isExpired { return "Expired" }
        return remoteCoOpSnapshot.connectedParticipantCount > 0 ? "Active" : "Invite"
    }

    private var remoteCoOpTitle: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Disabled" }
        guard remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots > 0 else { return "No Slot" }
        if let invite = remoteCoOpSnapshot.invite, !invite.isExpired { return "Invite Ready" }
        if remoteCoOpSnapshot.invite?.isExpired == true { return "Expired" }
        return "Ready"
    }

    private var remoteCoOpSubtitle: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Enable in Settings" }
        guard remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots > 0 else { return "Reserve slot before launch" }
        if let invite = remoteCoOpSnapshot.invite, !invite.isExpired { return "Code \(invite.code)" }
        return "Create invite"
    }

    private var remoteCoOpInviteCode: String {
        remoteCoOpSnapshot.invite?.code ?? "No active invite"
    }

    private var remoteCoOpInviteActionSubtitle: String {
        guard remoteCoOpSnapshot.preferences.isAvailable else { return "Enable in Settings" }
        guard isStreamReady else { return "Stream not ready" }
        if let invite = remoteCoOpSnapshot.invite {
            return invite.isExpired ? "Refresh" : invite.code
        }
        return "Create + copy"
    }

    private func refreshRemoteCoOpState() {
        let preferences = remoteCoOpLaunchPreferences
        remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: preferences.transportMode, latencyMode: preferences.latencyMode)
        remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: preferences, invite: remoteCoOpSnapshot.invite, participants: remoteCoOpSnapshot.participants)
        Task { @MainActor in
            await remoteCoOpHostSession.updatePreferences(preferences)
            await remoteCoOpPeerController?.updateNetworkConfiguration(remoteCoOpNetworkConfiguration)
            await remoteCoOpPeerController?.updateQualityPreset(preferences.qualityPreset)
            await remoteCoOpPeerController?.updateLatencyMode(preferences.latencyMode)
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
        }
    }

    private func startRemoteCoOpInvite() {
        let preferences = remoteCoOpLaunchPreferences
        guard preferences.isAlphaOptedIn else { return }
        remoteCoOpMessage = "Creating..."
        Task { @MainActor in
            let neutralEvents = await stopRemoteCoOpSession()
            neutralEvents.forEach { transport?.sendNow($0) }
            await remoteCoOpHostSession.updatePreferences(preferences)
            do {
                let coordinator = makeRemoteCoOpCoordinator(preferences: preferences)
                let invite = try await coordinator.startInvite(applicationID: configuration.applicationID, title: configuration.title, joinBaseURL: remoteCoOpJoinBaseURL(preferences), signalingServerURL: preferences.signalingServerURL)
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                copyRemoteCoOpInvite(invite)
                remoteCoOpMessage = invite.joinURL == nil ? "Copied \(invite.code)" : "Link copied"
                showTransientStreamMessage("Remote Co-Op invite copied")
                WebRTCMediaTelemetry.capture("webrtc.remote_coop.invite.created", level: .info, message: "Remote Co-Op invite created.", attributes: ["applicationID": configuration.applicationID, "reservedSlots": String(preferences.effectiveReservedGuestSlots), "transportMode": preferences.transportMode.rawValue, "latencyMode": preferences.latencyMode.rawValue])
            } catch {
                _ = await stopRemoteCoOpSession()
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                remoteCoOpMessage = Self.message(for: error)
                WebRTCMediaTelemetry.capture("webrtc.remote_coop.invite.failed", level: .warning, message: remoteCoOpMessage, attributes: ["applicationID": configuration.applicationID])
            }
        }
    }

    private func stopRemoteCoOpInvite() {
        Task { @MainActor in
            let neutralEvents = await stopRemoteCoOpSession()
            neutralEvents.forEach { transport?.sendNow($0) }
            remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
            remoteCoOpMessage = "Ended"
            showTransientStreamMessage("Remote Co-Op invite ended")
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.invite.ended", level: .info, message: "Remote Co-Op invite ended.", attributes: ["applicationID": configuration.applicationID])
        }
    }

    private func copyRemoteCoOpInvite() {
        guard let invite = remoteCoOpSnapshot.invite else { return }
        copyRemoteCoOpInvite(invite)
        remoteCoOpMessage = invite.joinURL == nil ? "Token copied" : "Link copied"
        showTransientStreamMessage("Remote Co-Op invite copied")
    }

    private func copyRemoteCoOpInvite(_ invite: OPNRemoteCoOpInvite) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(remoteCoOpClipboardText(invite), forType: .string)
    }

    private func remoteCoOpClipboardText(_ invite: OPNRemoteCoOpInvite) -> String {
        if let joinURL = invite.joinURL {
            return joinURL.absoluteString
        }
        return invite.token
    }

    private func approveRemoteCoOpParticipant(_ participantID: UUID) {
        Task { @MainActor in
            do {
                let participant: OPNRemoteCoOpParticipant
                if let remoteCoOpHostCoordinator {
                    participant = try await remoteCoOpHostCoordinator.approveParticipant(participantID)
                } else {
                    participant = try await remoteCoOpHostSession.approveParticipant(participantID)
                }
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                try await syncRemoteCoOpPeers()
                remoteCoOpMessage = "Approved \(participant.displayName) for player \((participant.playerIndex ?? 0) + 1)."
                showTransientStreamMessage("Remote Co-Op guest approved")
            } catch {
                remoteCoOpMessage = Self.message(for: error)
            }
        }
    }

    private func removeRemoteCoOpParticipant(_ participantID: UUID) {
        Task { @MainActor in
            do {
                let neutralEvents: [UserInputEvent]
                if let remoteCoOpHostCoordinator {
                    neutralEvents = try await remoteCoOpHostCoordinator.removeParticipant(participantID)
                } else {
                    neutralEvents = try await remoteCoOpHostSession.removeParticipant(participantID)
                }
                neutralEvents.forEach { transport?.sendNow($0) }
                await remoteCoOpPeerController?.removePeer(participantID: participantID)
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                remoteCoOpMessage = "Remote Co-Op guest removed."
                showTransientStreamMessage("Remote Co-Op guest removed")
            } catch {
                remoteCoOpMessage = Self.message(for: error)
            }
        }
    }

    private var remoteCoOpLaunchPreferences: OPNRemoteCoOpPreferences {
        OPNRemoteCoOpPreferences.launchPreferences(from: configuration.metadata, fallback: OPNRemoteCoOpPreferencesStore.load())
    }

    private func makeRemoteCoOpCoordinator(preferences: OPNRemoteCoOpPreferences) -> OPNRemoteCoOpHostCoordinator {
        if let remoteCoOpHostCoordinator {
            if remoteCoOpPeerController == nil, let remoteCoOpSignalingSession {
                remoteCoOpPeerController = makeRemoteCoOpPeerController(signaling: remoteCoOpSignalingSession, coordinator: remoteCoOpHostCoordinator)
            }
            return remoteCoOpHostCoordinator
        }
        let signaling = makeRemoteCoOpSignalingSession(preferences: preferences)
        let coordinator = OPNRemoteCoOpHostCoordinator(hostSession: remoteCoOpHostSession, signaling: signaling)
        remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: preferences.transportMode, latencyMode: preferences.latencyMode)
        remoteCoOpSignalingSession = signaling
        remoteCoOpHostCoordinator = coordinator
        remoteCoOpPeerController = makeRemoteCoOpPeerController(signaling: signaling, coordinator: coordinator)
        remoteCoOpListenTask?.cancel()
        remoteCoOpListenTask = Task { @MainActor in
            for await event in signaling.events() {
                switch event {
                case .peerSignal(let participantID, let signal):
                    do {
                        try await remoteCoOpPeerController?.receiveSignal(participantID: participantID, signal: signal)
                    } catch {
                        remoteCoOpMessage = Self.message(for: error)
                    }
                case .networkConfiguration(let configuration):
                    remoteCoOpNetworkConfiguration = configuration
                    await remoteCoOpPeerController?.updateNetworkConfiguration(configuration)
                default:
                    let routedEvents = await coordinator.handle(event)
                    for routedEvent in routedEvents { transport?.sendNow(routedEvent) }
                }
                remoteCoOpSnapshot = await remoteCoOpHostSession.snapshot()
                try? await syncRemoteCoOpPeers()
            }
        }
        return coordinator
    }

    private func makeRemoteCoOpPeerController(signaling: any OPNRemoteCoOpSignalingSession, coordinator: OPNRemoteCoOpHostCoordinator) -> OPNRemoteCoOpHostPeerController {
        let inputTransport = transport
        return OPNRemoteCoOpHostPeerController(
            signaling: signaling,
            coordinator: coordinator,
            networkConfiguration: remoteCoOpNetworkConfiguration,
            qualityPreset: remoteCoOpLaunchPreferences.qualityPreset,
            latencyMode: remoteCoOpLaunchPreferences.latencyMode,
            videoRelay: remoteCoOpVideoRelay,
            audioRelay: remoteCoOpAudioRelay,
            forwardInput: { event in inputTransport?.sendNow(event) }
        )
    }

    private func syncRemoteCoOpPeers() async throws {
        guard let remoteCoOpPeerController else { return }
        do {
            try await remoteCoOpPeerController.sync(participants: remoteCoOpSnapshot.participants)
        } catch {
            remoteCoOpMessage = Self.message(for: error)
            WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer_sync.failed", level: .warning, message: remoteCoOpMessage, attributes: ["applicationID": configuration.applicationID])
            throw error
        }
    }

    private func makeRemoteCoOpSignalingSession(preferences: OPNRemoteCoOpPreferences) -> any OPNRemoteCoOpSignalingSession {
        if let serverURL = URL(string: preferences.signalingServerURL.trimmingCharacters(in: .whitespacesAndNewlines)), serverURL.scheme?.hasPrefix("ws") == true {
            return OPNRemoteCoOpWebSocketSignalingSession(serverURL: serverURL)
        }
        return OPNInProcessRemoteCoOpSignalingSession()
    }

    private func remoteCoOpJoinBaseURL(_ preferences: OPNRemoteCoOpPreferences) -> URL? {
        URL(string: preferences.guestJoinBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stopRemoteCoOpSession() async -> [UserInputEvent] {
        let neutralEvents: [UserInputEvent]
        if let remoteCoOpHostCoordinator {
            neutralEvents = await remoteCoOpHostCoordinator.stopInvite()
        } else {
            neutralEvents = await remoteCoOpHostSession.stopInvite()
        }
        remoteCoOpListenTask?.cancel()
        remoteCoOpListenTask = nil
        await remoteCoOpPeerController?.removeAll()
        remoteCoOpVideoRelay.removeAll()
        remoteCoOpAudioRelay.removeAll()
        remoteCoOpPeerController = nil
        await remoteCoOpSignalingSession?.close()
        remoteCoOpSignalingSession = nil
        remoteCoOpHostCoordinator = nil
        return neutralEvents
    }

    private func toggleUnifiedHUD() {
        setUnifiedHUDVisible(!unifiedHUDVisible)
        WebRTCMediaTelemetry.capture("webrtc.ui.hud.toggle", level: .info, message: unifiedHUDVisible ? "Unified HUD shown." : "Unified HUD hidden.", attributes: ["visible": String(unifiedHUDVisible)])
    }

    private var hudFocusEntries: [StreamHUDFocusEntry] {
        var entries: [StreamHUDFocusEntry] = [
            StreamHUDFocusEntry(id: "microphone", isDisabled: runtimeSettings.microphoneMode == "disabled", action: toggleMicrophone),
            StreamHUDFocusEntry(id: "recording", isDisabled: !isStreamReady || recordingIsBusy, action: toggleRecording),
            StreamHUDFocusEntry(id: "anti-afk", isDisabled: !isStreamReady, action: toggleAntiAFKMouseMovement),
            StreamHUDFocusEntry(id: "controller-mapping", isDisabled: false, action: openControllerMapping),
            StreamHUDFocusEntry(id: "quit", isDisabled: false, action: { showQuitMenu() }),
        ]
        if remoteCoOpSnapshot.preferences.isAlphaOptedIn {
            entries.append(StreamHUDFocusEntry(
                id: "coop-invite",
                isDisabled: !remoteCoOpSnapshot.preferences.isAvailable || remoteCoOpSnapshot.preferences.effectiveReservedGuestSlots == 0 || !isStreamReady,
                action: remoteCoOpSnapshot.invite == nil ? startRemoteCoOpInvite : stopRemoteCoOpInvite
            ))
            if remoteCoOpSnapshot.invite != nil {
                entries.append(StreamHUDFocusEntry(id: "coop-copy", isDisabled: false, action: copyRemoteCoOpInvite))
            }
        }
        return entries
    }

    private func handleHUDGamepad(_ state: GamepadState) {
        guard let step = hudGamepadTracker.navigationStep(state) else { return }
        switch step {
        case .move(let delta):
            moveHUDFocus(by: delta)
        case .activate:
            StreamHUDFocusEntry.activatable(hudFocusID, in: hudFocusEntries)?.action()
        case .back:
            setUnifiedHUDVisible(false)
        }
    }

    private func moveHUDFocus(by step: Int) {
        guard let next = StreamHUDFocusEntry.focusID(after: hudFocusID, in: hudFocusEntries, step: step) else { return }
        hudFocusID = next
    }

    private func handleQuitMenuGamepad(_ state: GamepadState) {
        guard let step = hudGamepadTracker.navigationStep(state) else { return }
        switch step {
        case .move(let delta):
            quitMenuFocusIndex = (quitMenuFocusIndex + delta + 3) % 3
        case .activate:
            switch quitMenuFocusIndex {
            case 0: dismissQuitMenu()
            case 1: pauseFromQuitMenu()
            default: quitStreamFromMenu()
            }
        case .back:
            dismissQuitMenu()
        }
    }

    private func setUnifiedHUDVisible(_ visible: Bool) {
        unifiedHUDVisible = visible
        hudGamepadTracker.reset()
        guard visible else {
            hudFocusID = nil
            if restorePointerLockOnHUDHide {
                restorePointerLockOnHUDHide = false
                if NSApplication.shared.isActive, nativeView?.window?.isKeyWindow == true {
                    nativeView?.setPointerLocked(true)
                }
            }
            return
        }
        restorePointerLockOnHUDHide = pointerLocked
        hudFocusID = hudFocusEntries.first(where: { !$0.isDisabled })?.id
        nativeView?.setPointerLocked(false)
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

    private func videoStepperRow(_ label: String, value: Int, range: ClosedRange<Int>, step: Int = 1, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.streamNvidia(size: 11, weight: .medium))
                .foregroundStyle(WebRTCMediaStreamTheme.textTertiary)
            Spacer(minLength: 8)
            Stepper(value: Binding(get: { value }, set: { action($0) }), in: range, step: step) {
                Text(String(value))
                    .font(.streamNvidia(size: 11, weight: .bold))
                    .foregroundStyle(WebRTCMediaStreamTheme.textPrimary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .disabled(!isStreamReady)
        }
    }


    private func updateVideoEnhancement(mode: Int? = nil, sharpness: Int? = nil, denoise: Int? = nil, targetHeight: Int? = nil, pillarboxFillMode: Int? = nil, pillarboxFillDim: Int? = nil, pillarboxFillColor: Int? = nil) {
        runtimeSettings.updateVideoEnhancement(mode: mode, sharpness: sharpness, denoise: denoise, targetHeight: targetHeight, pillarboxFillMode: pillarboxFillMode, pillarboxFillDim: pillarboxFillDim, pillarboxFillColor: pillarboxFillColor)
        onVideoEnhancementChange?(runtimeSettings.upscalingMode, runtimeSettings.upscalingSharpness, runtimeSettings.upscalingDenoise)
        transport?.setLocalVideoEnhancement(mode: runtimeSettings.upscalingMode, sharpness: runtimeSettings.upscalingSharpness, denoise: runtimeSettings.upscalingDenoise, targetHeight: runtimeSettings.upscalingTargetHeight, pillarboxFillMode: runtimeSettings.pillarboxFillMode, pillarboxFillDim: runtimeSettings.pillarboxFillDim, pillarboxFillColor: runtimeSettings.pillarboxFillColor)
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

    private var clipboardTextAvailable: Bool {
        guard let text = NSPasteboard.general.string(forType: .string) else { return false }
        return !text.isEmpty
    }

    private var networkHealthText: String {
        guard let latestStats, latestStats.available else { return "No stats" }
        return networkWarningText.isEmpty ? "Good" : "Watch"
    }

    private var networkHealthIsGood: Bool {
        guard let latestStats, latestStats.available else { return false }
        return networkWarningText.isEmpty
    }

    private var networkWarningText: String {
        guard let latestStats else { return "Waiting for WebRTC stats." }
        guard latestStats.available else { return "Stats are not available yet." }
        if latestStats.packetLossPercent >= 2 { return "Packet loss is high; expect visible artifacts or input delay." }
        if latestStats.latencyMs >= 120 { return "Latency is high; input may feel delayed." }
        if latestStats.jitterMs >= 35 { return "Network jitter is unstable; gameplay may stutter." }
        if latestStats.inboundBitrateMbps >= 0 && latestStats.inboundBitrateMbps < 5 { return "Inbound bitrate is low for cloud gaming quality." }
        if latestStats.videoMaxFrameIntervalMs >= 80 { return "Frame pacing spikes detected in the video pipeline." }
        return ""
    }

    private func toggleStatsHUD() {
        statsVisible.toggle()
        WebRTCMediaTelemetry.capture("webrtc.ui.stats.toggle", level: .info, message: statsVisible ? "Stats HUD shown." : "Stats HUD hidden.", attributes: ["visible": String(statsVisible)])
    }

    private func pasteClipboardIntoStream() {
        guard isStreamReady, !isEndingStream, !didEndStream else { return }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            showTransientStreamMessage("Clipboard is empty")
            return
        }
        transport?.sendNow(.text(deviceID: "keyboard", value: text, timestamp: MediaTimestamp(nanoseconds: DispatchTime.now().uptimeNanoseconds)))
        lastAcceptedStreamInputAt = Date()
        showTransientStreamMessage("Clipboard sent")
        WebRTCMediaTelemetry.capture("webrtc.ui.clipboard.paste", level: .info, message: "Clipboard text sent to stream.", attributes: ["applicationID": configuration.applicationID, "characters": String(text.count)])
    }

    private func togglePointerLockFromHUD() {
        guard isStreamReady, runtimeSettings.directMouseInput else { return }
        nativeView?.setPointerLocked(!pointerLocked)
    }

    private func toggleFullScreenFromHUD() {
        guard let window = nativeView?.window else { return }
        window.toggleFullScreen(nil)
        showTransientStreamMessage(window.styleMask.contains(.fullScreen) ? "Leaving full screen" : "Entering full screen")
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
        self.transport = transport
        self.path = path
        startStatsPolling(transport: transport)
        startSessionLimitUpdatePolling(transport: transport)
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
            if let sessionError = error as? MacForceNowStreamSessionError, case .activeSessionConflict(let conflict) = sessionError {
                metadata.merge(conflict.reportMetadata) { current, _ in current }
            }
            onEnd(false, message, StreamReport(title: configuration.title, success: false, reason: .failed, message: message, durationSeconds: 0, metadata: metadata))
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

    private func startSessionLimitUpdatePolling(transport: NativeWebRTCTransport) {
        sessionLimitUpdateTask?.cancel()
        sessionLimitUpdateTask = Task {
            for await update in transport.sessionLimitUpdates() {
                await MainActor.run { applySessionLimitUpdate(update) }
            }
        }
    }

    private func applySessionLimitUpdate(_ update: StreamSessionLimitUpdate) {
        guard let limit = StreamSessionSidebarLimit(update: update) else { return }
        sessionLimit = limit
        publishSessionLimitProgress()
        WebRTCMediaTelemetry.capture("webrtc.ui.session_limit.update", level: .info, message: "Session limit timer updated from stream message.", attributes: ["applicationID": configuration.applicationID, "remainingSeconds": String(update.remainingSeconds), "timerType": update.timerType])
    }

    private func publishSessionLimitProgress() {
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

    private func inputAction(for event: UserInputEvent) -> StreamInputAction {
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

    private func isMouseButtonRelease(_ event: MouseEvent) -> Bool {
        guard case .button(_, _, let isPressed, _) = event else { return false }
        return !isPressed
    }

    private func handle(_ command: WebRTCMediaStreamCommand) {
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
                try? await Task.sleep(for: StreamAntiAFKInputPolicy.pollInterval)
                guard !Task.isCancelled else { return }
                sendAntiAFKMouseMovement()
            }
        }
    }

    private func sendAntiAFKMouseMovement() {
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

    private func refreshControllerBatteries() {
        let batteries = ControllerBatteryInfo.currentSnapshot()
        for message in batteryAlertTracker.messages(for: batteries) {
            showTransientStreamMessage(message)
        }
        controllerBatteries = batteries
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
        quitMenuFocusIndex = 0
        hudGamepadTracker.reset()
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

    private func stopStream() {
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

    private func beginStreamingPerformanceMode() {
        guard streamingPerformanceActivity == nil else { return }
        streamingPerformanceActivity = ProcessInfo.processInfo.beginActivity(options: streamingPerformanceActivityOptions, reason: "MacForce Now active cloud gaming stream")
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
