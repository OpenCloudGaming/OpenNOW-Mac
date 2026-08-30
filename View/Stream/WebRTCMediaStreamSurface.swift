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

    @State var path: WebRTCStreamingPath?
    @State var transport: NativeWebRTCTransport?
    @State var hasStarted = false
    @State var isStreamReady = false
    @State var loadingStepIndex = -1
    @State var pointerLocked = false
    @State var statsVisible = false
    @State var unifiedHUDVisible = false
    @State var restorePointerLockOnHUDHide = false
    @State var quitMenuVisible = false
    @State var showingControllerMapping = false
    @State var isEndingStream = false
    @State var didEndStream = false
    @State var latestStats: OPNStreamStatsSnapshot?
    @State var statsTask: Task<Void, Never>?
    @State var sessionLimitUpdateTask: Task<Void, Never>?
    @State var startTask: Task<Void, Never>?
    @State var nativeView: NativeWebRTCStreamView?
    @State var pendingApplicationQuitCompletion: WebRTCMediaStreamQuitDecisionHandler?
    @State var runtimeSettings = StreamRuntimeSettings()
    @State var microphoneEnabled = false
    @State var recordingStatus = WebRTCStreamRecordingStatus.idle
    @State var recordingNotificationTask: Task<Void, Never>?
    @State var antiAFKMouseMovementTask: Task<Void, Never>?
    @State var lastAcceptedStreamInputAt = Date()
    @State var transientStreamMessage = ""
    @State var transientStreamMessageTask: Task<Void, Never>?
    @State var streamingPerformanceActivity: (any NSObjectProtocol)?
    @State var remoteCoOpHostSession = OPNRemoteCoOpHostSession()
    @State var remoteCoOpHostCoordinator: OPNRemoteCoOpHostCoordinator?
    @State var remoteCoOpSignalingSession: (any OPNRemoteCoOpSignalingSession)?
    @State var remoteCoOpPeerController: OPNRemoteCoOpHostPeerController?
    @State var remoteCoOpVideoRelay = OPNRemoteCoOpHostVideoRelay()
    @State var remoteCoOpAudioRelay = OPNRemoteCoOpHostAudioRelay()
    @State var remoteCoOpListenTask: Task<Void, Never>?
    @State var remoteCoOpSnapshot = OPNRemoteCoOpHostSnapshot(preferences: OPNRemoteCoOpPreferencesStore.load(), invite: nil, participants: [])
    @State var remoteCoOpNetworkConfiguration = OPNRemoteCoOpNetworkConfiguration(transportMode: OPNRemoteCoOpPreferencesStore.load().transportMode, latencyMode: OPNRemoteCoOpPreferencesStore.load().latencyMode)
    @State var remoteCoOpMessage = ""
    @State var controllerBatteries: [ControllerBatteryInfo] = []
    @State var batteryAlertTracker = ControllerBatteryAlertTracker()
    @State var hudFocusID: String?
    @State var quitMenuFocusIndex = 0
    @State var hudGamepadTracker = StreamHUDGamepadTracker()
    @State var onScreenKeyboardVisible = false
    @State var restorePointerLockOnKeyboardHide = false
    @StateObject var onScreenKeyboard = StreamOnScreenKeyboardModel()
    @AppStorage(OpenNOWInterfacePreferences.uiScaleKey) var uiScale = OpenNOWInterfacePreferences.defaultUIScale
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
                .opnInterfaceScale(uiScale)
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
        guard let latestStats, latestStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestStats.renderFps >= 55 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    var latencyColor: Color {
        guard let latestStats, latestStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        if latestStats.latencyMs >= 120 { return WebRTCMediaStreamTheme.danger }
        if latestStats.latencyMs >= 90 { return WebRTCMediaStreamTheme.warning }
        return WebRTCMediaStreamTheme.accent
    }

    var frameLossColor: Color {
        guard let latestStats, latestStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        return latestStats.framesDropped == 0 ? WebRTCMediaStreamTheme.accent : WebRTCMediaStreamTheme.warning
    }

    var packetLossColor: Color {
        guard let latestStats, latestStats.available else { return WebRTCMediaStreamTheme.textTertiary }
        if latestStats.packetLossPercent >= 2 { return WebRTCMediaStreamTheme.danger }
        if latestStats.packetLossPercent >= 1 { return WebRTCMediaStreamTheme.warning }
        return WebRTCMediaStreamTheme.accent
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
