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
    let configuration: StreamLaunchConfiguration
    let sessionProvider: any StreamSessionProvider
    let signaling: (any StreamSignalingChannel)?
    let onAntiAFKStateChange: WebRTCMediaAntiAFKStateChangeCallback?
    let onVideoEnhancementChange: WebRTCMediaVideoEnhancementChangeCallback?
    let preventDisplaySleep: Bool
    let onProgress: WebRTCMediaStreamProgressCallback?
    let onEnd: WebRTCMediaStreamEndCallback
    let sidebarCapabilities = StreamSidebarCapabilities.webRTC

    @State var path: StreamingPath?
    @State var transport: NativeWebRTCTransport?
    @State var hasStarted = false
    @State var isStreamReady = false
    @State var loadingStepIndex = -1
    @State var pointerLocked = false
    @State var statsVisible = false
    /// The overlay's stored shape, chosen in the unified HUD: how much detail it shows and which
    /// corner it occupies. The visible toggle above is per-session; these two persist.
    @State var statsDetail = OPNStreamStatsHUDSettings.detailLevel
    @State var statsPosition = OPNStreamStatsHUDSettings.position
    @State var unifiedHUDVisible = false
    @State var restorePointerLockOnHUDHide = false
    @State var quitMenuVisible = false
    @State var showingControllerMapping = false
    @State var showingControllerOrder = false
    @State var isEndingStream = false
    @State var didEndStream = false
    @State var latestStats: OPNStreamStatsSnapshot?
    @State var statsTask: Task<Void, Never>?
    @State var sessionLimitUpdateTask: Task<Void, Never>?
    @State var startTask: Task<Void, Never>?
    @State var nativeView: NativeWebRTCStreamView?
    @State var pendingApplicationQuitCompletion: StreamSessionQuitDecisionHandler?
    @State var runtimeSettings = StreamRuntimeSettings()
    /// Read once when the surface appears, not per HUD frame. Remote Co-Op cannot be hosted on this
    /// transport at all, so this only decides whether the HUD explains that - and it is a
    /// launch-time value, which is why reading it inside `body` was a synchronous store hit on every
    /// tick.
    @State var remoteCoOpEnabled = false
    @State var microphoneEnabled = false
    @State var recordingStatus = StreamRecordingStatus.idle
    @State var replayBufferState = StreamReplayBufferState()
    @State var recordingNotificationTask: Task<Void, Never>?
    @State var screenshotTask: Task<Void, Never>?
    @State var antiAFKMouseMovementTask: Task<Void, Never>?
    @State var lastAcceptedStreamInputAt = Date()
    @State var transientStreamMessage = ""
    @State var transientStreamMessageTask: Task<Void, Never>?
    @State var streamingPerformanceActivity: (any NSObjectProtocol)?
    /// Set only while OpenNOW is hosting the signaling itself, and stopped with the invite.
    /// Held so Transport and Latency changes reach it mid-session. Handed only to the composite
    /// session, its concrete `updateNetworkConfiguration` had no caller on this path and a native
    /// guest joining after a settings change was greeted with the invite-time configuration.
    @State var controllerBatteries: [ControllerBatteryInfo] = []
    @State var batteryAlertTracker = ControllerBatteryAlertTracker()
    @State var hudFocusID: String?
    @State var quitMenuFocusIndex = 0
    @State var hudGamepadTracker = StreamHUDGamepadTracker()
    @State var onScreenKeyboardVisible = false
    @State var restorePointerLockOnKeyboardHide = false
    @StateObject var onScreenKeyboard = StreamOnScreenKeyboardModel()
    @AppStorage(OPNInterfacePreferences.uiScaleKey) var uiScale = OPNInterfacePreferences.defaultUIScale
    @State var sessionLimit: StreamSessionSidebarLimit?

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
                view.onScreenKeyboardCapture = { deviceID, snapshot in
                    guard onScreenKeyboardVisible else { return false }
                    onScreenKeyboard.handleSteamSnapshot(deviceID: deviceID, snapshot: snapshot)
                    return true
                }
                onScreenKeyboard.onOutput = { output in
                    sendOnScreenKeyboardOutput(output)
                }
                onScreenKeyboard.onDismiss = {
                    setOnScreenKeyboardVisible(false)
                }
                if startTask == nil {
                    startTask = Task { await startIfNeeded(nativeView: view) }
                }
            }
            hudChrome
                .opnMotion(OPNDesign.Motion.panel, value: statsVisible)
                .opnMotion(OPNDesign.Motion.panel, value: unifiedHUDVisible)
                .opnMotion(OPNDesign.Motion.panel, value: quitMenuVisible)
                .opnInterfaceScale(uiScale)
        }
        .background(Color.black)
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .onAppear {
            registerStreamLifecycle()
            remoteCoOpEnabled = OPNRemoteCoOpPreferencesStore.load().isEnabled
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
            ControllerMappingView()
        }
        .sheet(isPresented: $showingControllerOrder) {
            ControllerOrderView()
        }
    }

    func openControllerOrder() {
        nativeView?.releasePressedInputs()
        setUnifiedHUDVisible(false)
        showingControllerOrder = true
    }

    func openControllerMapping() {
        setUnifiedHUDVisible(false)
        showingControllerMapping = true
    }

    var recordingIsBusy: Bool {
        if case .finishing = recordingStatus { return true }
        return false
    }

    var recordingCanStop: Bool {
        if case .starting = recordingStatus { return true }
        return recordingStatus.isRecording
    }

    var microphoneStatusText: String {
        guard runtimeSettings.microphoneMode != "disabled" else { return "Disabled" }
        return microphoneEnabled ? "On" : "Muted"
    }

    var recordingStatusText: String {
        switch recordingStatus {
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .recording(_, let elapsedSeconds): return recordingElapsedText(elapsedSeconds)
        case .finishing: return "Saving"
        case .finished: return "Saved"
        case .failed: return "Failed"
        }
    }

    var fpsColor: Color {
        guard let latestStats, latestStats.available else { return StreamHUDTheme.textTertiary }
        return latestStats.renderFps >= 55 ? StreamHUDTheme.accent : StreamHUDTheme.warning
    }

    var latencyColor: Color {
        guard let latestStats, latestStats.available else { return StreamHUDTheme.textTertiary }
        if latestStats.latencyMs >= 120 { return StreamHUDTheme.danger }
        if latestStats.latencyMs >= 90 { return StreamHUDTheme.warning }
        return StreamHUDTheme.accent
    }

    var frameLossColor: Color {
        guard let latestStats, latestStats.available else { return StreamHUDTheme.textTertiary }
        return latestStats.framesDropped == 0 ? StreamHUDTheme.accent : StreamHUDTheme.warning
    }

    var packetLossColor: Color {
        guard let latestStats, latestStats.available else { return StreamHUDTheme.textTertiary }
        if latestStats.packetLossPercent >= 2 { return StreamHUDTheme.danger }
        if latestStats.packetLossPercent >= 1 { return StreamHUDTheme.warning }
        return StreamHUDTheme.accent
    }

    var packetLossTotalText: String {
        "(\(latestStats?.packetsLost ?? 0) Total)"
    }

    func wholeNumber(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.0f", value)
    }

    func percentage(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.1f%%", value)
    }

    func megabits(_ value: Double?) -> String {
        guard let value, value >= 0 else { return "--" }
        return String(format: "%.1f", value)
    }

    func nonEmpty(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "--" }
        return value
    }

    func sessionLimitHUDText(at date: Date) -> String {
        guard let sessionLimit else { return "Unlimited" }
        return sessionLimitDurationText(sessionLimit.remainingSeconds(at: date))
    }

    func sessionLimitCountdownText(at date: Date) -> String {
        guard let sessionLimit else { return "0:00" }
        return sessionLimitDurationText(sessionLimit.remainingSeconds(at: date))
    }

    func sessionLimitIsHealthy(at date: Date) -> Bool {
        guard let sessionLimit else { return true }
        return sessionLimit.remainingSeconds(at: date) > 300
    }

    private func sessionLimitDurationText(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let minutes = clamped / 60
        let remainingSeconds = clamped % 60
        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }

}
