import AVFoundation
import AppKit
import AVFoundation
import Foundation
import GameController
import QuartzCore

private typealias OPNStreamSessionAnswerHandler = @convention(block) (NSString, NSString) -> Void
private typealias OPNStreamSessionLocalIceCandidateHandler = @convention(block) (NSDictionary) -> Void
private typealias OPNStreamSessionStateHandler = @convention(block) (Bool, NSString) -> Void

private final class OPNStreamSendableValue<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

@objc(OPNStreamViewController)
@objcMembers
final class OPNStreamViewController: NSViewController {
    var onStreamEnd: ((Bool, String, OPNSessionReportPayload) -> Void)?
    var onDashboardToggleRequested: (() -> Void)?

    private let gameTitle: String
    private let appId: String
    private let apiToken: String
    private let accountLinked: Bool
    private let selectedStore: String
    private var resumeSessionId: String
    private var resumeServer: String
    private var resumeExistingSession: Bool

    private var streamView: OPNStreamView?
    private var loadingView: OPNLoadingView?
    private var statusLabel: NSTextField?
    private var quitOverlay: OPNQuitGameOverlayView?
    private var statsOverlay: OPNStatsOverlayView?
    private var shortcutLegendOverlay: OPNShortcutLegendView?
    private var statsRefreshTimer: Timer?
    private var inactivityTimer: Timer?
    private var playtimeRefreshTimer: Timer?
    private var signaling: OPNWebSocketSignalingClient?
    private var session = OPNStreamSessionHandle()
    private var initialViewFrame = NSRect(x: 0, y: 0, width: 1, height: 1)
    private var quitKeyMonitor: Any?
    private var streamStarted = false
    private var streamEnded = false
    private var connectedOnce = false
    private var remoteIceReceived = false
    private var recovering = false
    private var recoveryAttempt = 0
    private var launchGeneration: UInt = 0
    private var launchStreamingBaseUrl = ""
    private var stableResetGeneration: UInt = 0
    private var remoteIceGraceTimer: Timer?
    private var recoveryResetTimer: Timer?
    private var connectedToast: NSView?
    private var activeSessionInfo: [String: Any] = [:]
    private var hasActiveSessionInfo = false
    private var remoteStopRequested = false
    private var webRTCBackendName = "libwebrtc"
    private var lastStreamActivityTime: CFTimeInterval = 0
    private var lastIdleDeviceInputTime: CFTimeInterval = 0
    private var idleDeviceInputEnabled = false
    private var remainingPlaytimeHours = 0.0
    private var remainingPlaytimeUnlimited = false
    private var remainingPlaytimeAvailable = false
    private var healthReportStarted = false
    private let healthReport = OPNSessionHealthReportBuilder()
    private var streamLaunchTrace: OPNSentryTransactionBridge?

    init(gameTitle title: String, appId: String, apiToken token: String, accountLinked: Bool, selectedStore: String) {
        self.gameTitle = title
        self.appId = appId
        self.apiToken = token
        self.accountLinked = accountLinked
        self.selectedStore = selectedStore
        self.resumeSessionId = ""
        self.resumeServer = ""
        self.resumeExistingSession = false
        super.init(nibName: nil, bundle: nil)
    }

    init(gameTitle title: String, appId: String, apiToken token: String, accountLinked: Bool, selectedStore: String, resumeSessionId: String, resumeServer: String) {
        self.gameTitle = title
        self.appId = appId
        self.apiToken = token
        self.accountLinked = accountLinked
        self.selectedStore = selectedStore
        self.resumeSessionId = resumeSessionId
        self.resumeServer = resumeServer
        self.resumeExistingSession = !resumeSessionId.isEmpty && !resumeServer.isEmpty
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        self.gameTitle = ""
        self.appId = ""
        self.apiToken = ""
        self.accountLinked = false
        self.selectedStore = ""
        self.resumeSessionId = ""
        self.resumeServer = ""
        self.resumeExistingSession = false
        super.init(coder: coder)
    }

    deinit {
        MainActor.assumeIsolated {
            cleanup()
        }
    }

    func setInitialViewFrame(_ frame: NSRect) {
        guard frame.width > 0, frame.height > 0 else { return }
        initialViewFrame = frame
        if isViewLoaded { view.frame = frame }
    }

    func setRemainingPlaytimeHours(_ hours: Double, unlimited: Bool) {
        remainingPlaytimeUnlimited = unlimited
        remainingPlaytimeAvailable = unlimited || (hours.isFinite && hours >= 0)
        remainingPlaytimeHours = remainingPlaytimeAvailable && !unlimited ? max(0, hours) : 0
        streamView?.setRemainingPlaytimeHours(remainingPlaytimeHours, unlimited: remainingPlaytimeUnlimited)
    }

    func startStreamIfNeeded() {
        guard !streamStarted, !streamEnded else { return }
        streamStarted = true
        startStreamLaunchFlow()
    }

    func setStreamInputSuppressed(_ suppressed: Bool) {
        streamView?.setStreamInputSuppressed(suppressed)
    }

    override func loadView() {
        let streamView = OPNStreamView(frame: initialViewFrame)
        streamView.autoresizingMask = [.width, .height]
        streamView.onUserActivity = { [weak self] in self?.recordStreamUserActivity() }
        streamView.onDashboardToggleRequested = { [weak self] in self?.onDashboardToggleRequested?() }
        streamView.onSidebarHUDVisibilityChanged = { [weak self] visible in
            guard let self, self.connectedOnce, !self.streamEnded else { return }
            if visible {
                self.refreshDisplayedPlaytimeFromSessionPoll()
                self.startPlaytimeRefreshTimer()
            } else {
                self.stopPlaytimeRefreshTimer()
            }
        }
        self.view = streamView
        self.streamView = streamView
        configureStreamViewSessionCallbacks()
        streamView.setRecordingGameTitle(gameTitle.isEmpty ? "Stream" : gameTitle)
        if remainingPlaytimeAvailable {
            streamView.setRemainingPlaytimeHours(remainingPlaytimeHours, unlimited: remainingPlaytimeUnlimited)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ensureLoadingView(message: "Starting session...")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installQuitShortcutMonitor()
        startStreamIfNeeded()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        removeQuitShortcutMonitor()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        loadingView?.frame = view.bounds
        statsOverlay?.frame = statsOverlayFrame()
        shortcutLegendOverlay?.frame = shortcutLegendFrame()
    }

    func requestQuitGameConfirmation() {
        guard !streamEnded else { return }
        streamView?.releasePointerLock()
        if let quitOverlay {
            view.window?.makeFirstResponder(quitOverlay)
            return
        }
        let overlay = OPNQuitGameOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onCancel = { [weak self] in self?.dismissQuitGameOverlayAndRefocus(true) }
        overlay.onQuit = { [weak self] in self?.endStreamFromUserQuit() }
        quitOverlay = overlay
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
        view.window?.makeFirstResponder(overlay)
    }

    func shutdownForApplicationTermination() {
        guard !streamEnded else { return }
        streamEnded = true
        cleanup()
        onStreamEnd?(true, "", healthReport.finalize(success: true, terminalError: "", now: CACurrentMediaTime()))
    }

    private func startStreamLaunchFlow() {
        launchGeneration += 1
        let generation = launchGeneration
        setStatus("Preparing stream launch...")
        ensureLoadingView(message: "Preparing stream launch...")
        guard session.isValid else {
            endStream(success: false, errorMessage: "libwebrtc stream session is unavailable")
            return
        }
        guard !appId.isEmpty else {
            endStream(success: false, errorMessage: "Invalid game ID")
            return
        }

        streamLaunchTrace = OPNSentryTransactionBridge.transaction(name: recovering ? "Stream recovery launch" : "Stream launch", operation: "stream.launch")
        streamLaunchTrace?.setTag("backend", value: webRTCBackendName)
        healthReport.reset(gameTitle: gameTitle, appId: appId, backend: webRTCBackendName, now: CACurrentMediaTime())
        healthReportStarted = true

        let settings = streamSettingsDictionary()
        guard ensureMicrophonePermissionIfNeeded(settings: settings, generation: generation) else { return }
        OPNSessionManager.shared.setAccessToken(apiToken)
        let selectedStreamingBaseUrl = OPNStreamPreferences.loadSelectedStreamingBaseUrl(forGame: appId)
        launchStreamingBaseUrl = selectedStreamingBaseUrl
        OPNSessionManager.shared.setStreamingBaseUrl(selectedStreamingBaseUrl)

        let settingsBox = OPNStreamSendableValue(settings)
        let requestedMaxBitrateMbps = int(settings["maxBitrateMbps"], fallback: 50)
        OPNStreamPreferences.fetchCloudVariables(token: apiToken) { [weak self] cloudVariables in
            guard let self else { return }
            OPNStreamPreferences.runNetworkPreflight(token: self.apiToken, providerStreamingBaseUrl: selectedStreamingBaseUrl, requestedMaxBitrateMbps: requestedMaxBitrateMbps) { [weak self] preflight in
                DispatchQueue.main.async {
                    guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                    var launchSettings = self.settingsByApplyingCloudVariables(settingsBox.value, variables: cloudVariables)
                    launchSettings["networkTestSessionId"] = preflight.networkTestSessionId
                    launchSettings["networkType"] = preflight.networkType
                    launchSettings["networkLatencyMs"] = preflight.latencyMs >= 0 ? String(preflight.latencyMs) : "Unknown"
                    if preflight.recommendedMaxBitrateMbps > 0 {
                        launchSettings["maxBitrateMbps"] = min(self.int(launchSettings["maxBitrateMbps"]), preflight.recommendedMaxBitrateMbps)
                    }
                    if !preflight.streamingBaseUrl.isEmpty {
                        self.launchStreamingBaseUrl = preflight.streamingBaseUrl
                        OPNSessionManager.shared.setStreamingBaseUrl(preflight.streamingBaseUrl)
                    }
                    guard self.confirmNetworkPreflightIfNeeded(preflight) else { return }
                    self.apply(settings: launchSettings)
                    if self.resumeExistingSession {
                        self.claimSession(settings: launchSettings, generation: generation)
                    } else {
                        self.launchFreshSession(settings: launchSettings, generation: generation)
                    }
                }
            }
        }
    }

    private func launchFreshSession(settings: [String: Any], generation: UInt) {
        setStatus("Allocating cloud session...")
        let settingsBox = OPNStreamSendableValue(settings)
        OPNGameService.shared.setAccessToken(apiToken)
        let streamingBaseUrl = launchStreamingBaseUrl.isEmpty ? OPNStreamPreferences.loadSelectedStreamingBaseUrl(forGame: appId) : launchStreamingBaseUrl
        OPNGameService.shared.setStreamingBaseUrl(streamingBaseUrl)
        OPNGameService.shared.launchGame(appId: appId, internalTitle: gameTitle.isEmpty ? "OpenNOW" : gameTitle, settings: settings, recoveryMode: recovering, progress: { [weak self] message, session in
            let sessionBox = OPNStreamSendableValue(session)
            DispatchQueue.main.async { [sessionBox] in
                guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                let progressSession = sessionBox.value
                self.setStatus(message.isEmpty ? self.progressMessage(for: progressSession as NSDictionary) : message)
                if !self.string(progressSession["sessionId"]).isEmpty { self.updateLaunchAdState(progressSession as NSDictionary) }
            }
        }, completion: { [weak self] success, sessionInfo, _, error in
            let sessionBox = OPNStreamSendableValue(sessionInfo)
            DispatchQueue.main.async { [sessionBox, settingsBox] in
                guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                if success {
                    self.connect(sessionInfo: sessionBox.value as NSDictionary, settings: settingsBox.value, generation: generation)
                } else {
                    self.endStream(success: false, errorMessage: OPNGFNError.userFacingMessage(errorMessage: error, gameTitle: self.gameTitle))
                }
            }
        })
    }

    private func createSession(settings: [String: Any], generation: UInt) {
        setStatus("Allocating cloud session...")
        OPNSessionManager.shared.createSession(appId: appId, internalTitle: gameTitle.isEmpty ? "OpenNOW" : gameTitle, settings: settings) { [weak self] success, sessionInfo, error in
            DispatchQueue.main.async {
                guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                if success {
                    self.waitForReadySession(sessionInfo as NSDictionary, settings: settings, generation: generation)
                } else {
                    self.endStream(success: false, errorMessage: OPNGFNError.userFacingMessage(errorMessage: error, gameTitle: self.gameTitle))
                }
            }
        }
    }

    private func claimSession(settings: [String: Any], generation: UInt) {
        setStatus("Resuming session...")
        OPNSessionManager.shared.claimSession(sessionId: resumeSessionId, serverIp: resumeServer, appId: appId, settings: settings, recoveryMode: recovering) { [weak self] success, sessionInfo, error in
            DispatchQueue.main.async {
                guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                if success {
                    let returnedSessionId = self.string(sessionInfo["sessionId"])
                    if !self.resumeSessionId.isEmpty, returnedSessionId != self.resumeSessionId {
                        self.endStream(success: false, errorMessage: "Resume returned a different session id")
                        return
                    }
                    self.connect(sessionInfo: sessionInfo as NSDictionary, settings: settings, generation: generation)
                } else if OPNStreamViewControllerSupport.resumeErrorShouldCreateFreshSession(error) {
                    self.resumeExistingSession = false
                    self.resumeSessionId = ""
                    self.resumeServer = ""
                    self.launchFreshSession(settings: settings, generation: generation)
                } else if self.resumeErrorShouldReResolveActiveSession(error) {
                    self.reResolveAndClaimActiveSession(settings: settings, generation: generation)
                } else {
                    self.endStream(success: false, errorMessage: OPNGFNError.userFacingMessage(errorMessage: error, gameTitle: self.gameTitle))
                }
            }
        }
    }

    private func reResolveAndClaimActiveSession(settings: [String: Any], generation: UInt) {
        setStatus("Resuming current active session...")
        let requestedSessionId = resumeSessionId
        OPNSessionManager.shared.getActiveSessions { [weak self] success, sessions, error in
            DispatchQueue.main.async {
                guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                guard success else {
                    self.endStream(success: false, errorMessage: error.isEmpty ? "Unable to resolve active session" : error)
                    return
                }
                guard let selectedSession = sessions.first(where: { self.string($0["sessionId"]) == requestedSessionId && !self.string($0["serverIp"]).isEmpty }) else {
                    self.endStream(success: false, errorMessage: "Requested session is no longer available to resume")
                    return
                }
                self.resumeServer = self.string(selectedSession["serverIp"])
                let selectedAppId = self.int(selectedSession["appId"]) > 0 ? String(self.int(selectedSession["appId"])) : self.appId
                OPNSessionManager.shared.claimSession(sessionId: requestedSessionId, serverIp: self.resumeServer, appId: selectedAppId, settings: settings, recoveryMode: true) { [weak self] retrySuccess, retryInfo, retryError in
                    DispatchQueue.main.async {
                        guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                        if !retrySuccess {
                            if OPNStreamViewControllerSupport.resumeErrorShouldCreateFreshSession(retryError) {
                                self.resumeExistingSession = false
                                self.resumeSessionId = ""
                                self.resumeServer = ""
                                self.launchFreshSession(settings: settings, generation: generation)
                                return
                            }
                            self.endStream(success: false, errorMessage: OPNGFNError.userFacingMessage(errorMessage: retryError, gameTitle: self.gameTitle))
                            return
                        }
                        guard self.string(retryInfo["sessionId"]) == requestedSessionId else {
                            self.endStream(success: false, errorMessage: "Resume returned a different session id")
                            return
                        }
                        self.connect(sessionInfo: retryInfo as NSDictionary, settings: settings, generation: generation)
                    }
                }
            }
        }
    }

    private func resumeErrorShouldReResolveActiveSession(_ error: String) -> Bool {
        error.contains("SESSION_NOT_PAUSED") || error.contains("\"statusCode\":34")
    }

    private func waitForReadySession(_ sessionInfo: NSDictionary, settings: [String: Any], generation: UInt, attempt: Int = 0) {
        let status = int(sessionInfo["status"])
        let serverIp = string(sessionInfo["serverIp"])
        updateActiveSessionInfo(sessionInfo)
        if (status == 2 || status == 3), !serverIp.isEmpty {
            connect(sessionInfo: sessionInfo, settings: settings, generation: generation)
            return
        }
        guard attempt < 60 else {
            endStream(success: false, errorMessage: "Session poll timeout")
            return
        }
        updateLaunchAdState(sessionInfo)
        setStatus(progressMessage(for: sessionInfo))
        let delay = attempt < 12 ? 0.3 : (attempt < 20 ? 0.5 : 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
            OPNSessionManager.shared.pollSession(sessionId: string(sessionInfo["sessionId"]), serverIp: serverIp) { [weak self] success, polledSession, error in
                DispatchQueue.main.async {
                    guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                    if success {
                        var mergedSession = sessionInfo as? [String: Any] ?? [:]
                        for (key, value) in polledSession where !(value is NSNull) {
                            mergedSession[key] = value
                        }
                        self.waitForReadySession(mergedSession as NSDictionary, settings: settings, generation: generation, attempt: attempt + 1)
                    } else {
                        self.endStream(success: false, errorMessage: error)
                    }
                }
            }
        }
    }

    private func connect(sessionInfo: NSDictionary, settings: [String: Any], generation: UInt) {
        activeSessionInfo = sessionInfo as? [String: Any] ?? [:]
        hasActiveSessionInfo = true
        let negotiatedSettings = settingsByApplyingNegotiatedProfile(settings: settings, sessionInfo: sessionInfo)
        setStatus("Connecting to stream...")
        let signaling = OPNWebSocketSignalingClient(signalingServer: string(sessionInfo["signalingServer"]), sessionId: string(sessionInfo["sessionId"]), signalingUrl: string(sessionInfo["signalingUrl"]))
        signaling.setPeerResolution(negotiatedSettings["resolution"] as? String ?? "1920x1080")
        self.signaling = signaling

        signaling.onOffer = { [weak self] offer in
            guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
            self.session.setNativeWindow(Unmanaged.passUnretained(self.streamView?.nativeVideoView() ?? self.view).toOpaque())
            let serverIceUfrag = OPNStreamSessionHandle.iceUfrag(fromOfferSdp: offer)
            self.remoteIceReceived = false
            self.startRemoteIceGraceTimer(generation: generation)
            self.session.start(sessionInfo: sessionInfo, offerSdp: offer, settings: negotiatedSettings as NSDictionary, answerHandler: { [weak self] sdp, nvstSdp in
                DispatchQueue.main.async { self?.signaling?.sendAnswerSdp(sdp as String, nvstSdp: nvstSdp as String) }
            }, localIceCandidateHandler: { [weak self] candidate in
                DispatchQueue.main.async { self?.signaling?.sendIceCandidate(candidate) }
            }, stateHandler: { [weak self] connected, error in
                DispatchQueue.main.async { self?.handleConnectionState(connected: connected, error: error as String, generation: generation, settings: negotiatedSettings) }
            })
            self.session.injectManualIceCandidate(sessionInfo: sessionInfo, offerSdp: offer, serverIceUfrag: serverIceUfrag)
        }
        signaling.onIceCandidate = { [weak self] candidate in
            guard let self else { return }
            self.remoteIceReceived = true
            self.cancelRemoteIceGraceTimer()
            self.session.addRemoteIceCandidatePayload(candidate as? [AnyHashable: Any] ?? [:])
        }
        signaling.onClosed = { [weak self] clean, reason in
            guard let self, !self.streamEnded, self.launchGeneration == generation else { return }
            if clean, self.connectedOnce { return }
            self.endStream(success: false, errorMessage: reason.isEmpty ? "Signaling connection closed" : reason)
        }
        signaling.connect { [weak self] success, error in
            guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
            if !success { self.endStream(success: false, errorMessage: error) }
        }
    }

    private func handleConnectionState(connected: Bool, error: String, generation: UInt, settings: [String: Any]) {
        guard launchGeneration == generation, !streamEnded else { return }
        if connected {
            cancelRemoteIceGraceTimer()
            connectedOnce = true
            recovering = false
            loadingView?.stopAnimating()
            loadingView?.removeFromSuperview()
            loadingView = nil
            streamView?.setStreamActive(true)
            streamView?.startRemainingPlaytimeCountdown()
            streamView?.takeFocus()
            healthReport.markConnected(now: CACurrentMediaTime())
            OPNDiscordPresence.updatePlaying(gameTitle: gameTitle, resolution: settings["resolution"] as? String ?? "", fps: int(settings["fps"]), bitrateMbps: int(settings["maxBitrateMbps"]), codec: settings["codec"] as? String ?? "")
            showConnectedToast(resolution: settings["resolution"] as? String ?? "", fps: int(settings["fps"]), bitrateMbps: int(settings["maxBitrateMbps"]), codec: settings["codec"] as? String ?? "")
            startStatsRefreshTimer()
            startInactivityTimer()
            scheduleRecoveryAttemptReset(generation: generation)
        } else {
            if error.isEmpty {
                endStream(success: true, errorMessage: "")
            } else {
                endStream(success: false, errorMessage: error)
            }
        }
    }

    private func streamSettingsDictionary() -> [String: Any] {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        var profile = OPNStreamPreferences.loadProfile(forGame: appId) ?? OPNStreamPreferences.loadProfile()
        profile = OPNStreamPreferences.effectiveProfile(profile, capabilities: capabilities)
        let display = OPNStreamViewControllerSupport.currentDisplayPixelSize(for: view.window)
        var resolution = profile.resolution
        if profile.enablePowerSaver {
            let aspect = profile.aspectRatio > 0.1 && profile.aspectRatio.isFinite ? profile.aspectRatio : 16.0 / 9.0
            var width = min(profile.resolution.width, 1280)
            var height = Int((Double(width) / aspect).rounded())
            if height > 800 { height = 800; width = Int((Double(height) * aspect).rounded()) }
            resolution = OPNStreamResolutionOption(width: max(640, width - width % 2), height: max(360, height - height % 2))
        } else if profile.aspectIndex == 1, profile.resolutionIndex == 2 {
            let width = max(640, Int(display.width.rounded()) / 2 * 2)
            let height = max(360, Int(display.height.rounded()) / 2 * 2)
            resolution = OPNStreamResolutionOption(width: width, height: height)
        }
        let codec = OPNStreamPreferences.resolveCodec(profile: profile, resolution: resolution, capabilities: capabilities, libWebRTCAvailable: OPNStreamSessionHandle.isBackendAvailable())
        return [
            "resolution": resolution.value,
            "fps": profile.enablePowerSaver ? min(profile.fps, 30) : profile.fps,
            "codec": codec,
            "colorQuality": profile.colorQuality.value.isEmpty ? "8bit_420" : profile.colorQuality.value,
            "maxBitrateMbps": profile.enablePowerSaver ? min(profile.maxBitrateMbps, 15) : profile.maxBitrateMbps,
            "prefilterMode": profile.lowLatencyMode ? 0 : profile.prefilterMode,
            "prefilterSharpness": profile.lowLatencyMode ? 0 : profile.prefilterSharpness,
            "prefilterDenoise": profile.lowLatencyMode ? 0 : profile.prefilterDenoise,
            "prefilterModel": profile.lowLatencyMode ? 0 : profile.prefilterModel,
            "enableL4S": profile.enableL4S,
            "enableHdr": profile.enableHdr,
            "enableReflex": true,
            "lowLatencyMode": profile.lowLatencyMode,
            "microphoneMode": profile.microphoneMode,
            "microphoneDeviceId": profile.microphoneDeviceId,
            "microphonePushToTalkKeyCode": profile.microphonePushToTalkKeyCode,
            "microphonePushToTalkModifierMask": profile.microphonePushToTalkModifierMask,
            "gameVolume": profile.gameVolume,
            "microphoneVolume": profile.microphoneVolume,
            "upscalingMode": profile.lowLatencyMode ? 0 : profile.upscalingMode,
            "upscalingSharpness": profile.lowLatencyMode ? 0 : profile.upscalingSharpness,
            "upscalingDenoise": profile.lowLatencyMode ? 0 : profile.upscalingDenoise,
            "upscalingTargetHeight": profile.upscalingTargetHeight,
            "suppressInputWhenInactive": profile.suppressInputWhenInactive,
            "directMouseInput": profile.directMouseInput,
            "gameLanguage": OPNLocale.currentGFNLocale(),
            "accountLinked": accountLinked,
            "selectedStore": selectedStore,
            "remoteControllersBitmap": connectedControllerBitmap(),
            "availableSupportedControllers": [],
        ]
    }

    private func ensureMicrophonePermissionIfNeeded(settings: [String: Any], generation: UInt) -> Bool {
        guard string(settings["microphoneMode"]) != "disabled" else { return true }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            setStatus("Microphone permission is disabled. Enable it in macOS Settings > Privacy & Security > Microphone.")
            endStream(success: false, errorMessage: "Microphone permission denied")
            return false
        case .notDetermined:
            setStatus("Requesting microphone permission...")
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.launchGeneration == generation, !self.streamEnded else { return }
                    if granted {
                        self.startStreamLaunchFlow()
                    } else {
                        self.setStatus("Microphone permission was denied. Enable it in macOS Settings > Privacy & Security > Microphone.")
                        self.endStream(success: false, errorMessage: "Microphone permission denied")
                    }
                }
            }
            return false
        @unknown default:
            return true
        }
    }

    private func apply(settings: [String: Any]) {
        let resolution = settings["resolution"] as? String ?? "1920x1080"
        let parts = resolution.split(separator: "x").compactMap { Int($0) }
        let width = parts.first ?? 1920
        let height = parts.count > 1 ? parts[1] : 1080
        streamView?.setVideoAspectRatio(height > 0 ? CGFloat(width) / CGFloat(height) : 16.0 / 9.0)
        streamView?.setMaxBitrateMbps(int(settings["maxBitrateMbps"]))
        streamView?.setMicrophoneMode(settings["microphoneMode"] as? String ?? "disabled", pushToTalkKeyCode: UInt16(int(settings["microphonePushToTalkKeyCode"])), modifierMask: UInt16(int(settings["microphonePushToTalkModifierMask"])))
        streamView?.setVideoUpscalingMode(int(settings["upscalingMode"]), sharpness: int(settings["upscalingSharpness"]), denoise: int(settings["upscalingDenoise"]), streamWidth: width, streamHeight: height)
        streamView?.setSuppressInputWhenWindowInactive(bool(settings["suppressInputWhenInactive"]))
        streamView?.setDirectMouseInputEnabled(bool(settings["directMouseInput"], fallback: true))
    }

    private func settingsByApplyingCloudVariables(_ settings: [String: Any], variables: OPNStreamCloudVariables) -> [String: Any] {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        var typed = OPNStreamSettings()
        typed.resolution = string(settings["resolution"], fallback: typed.resolution)
        typed.fps = int(settings["fps"], fallback: typed.fps)
        typed.codec = string(settings["codec"], fallback: typed.codec)
        typed.colorQuality = string(settings["colorQuality"], fallback: typed.colorQuality)
        typed.maxBitrateMbps = int(settings["maxBitrateMbps"], fallback: typed.maxBitrateMbps)
        typed.prefilterMode = int(settings["prefilterMode"])
        typed.prefilterSharpness = int(settings["prefilterSharpness"])
        typed.prefilterDenoise = int(settings["prefilterDenoise"])
        typed.prefilterModel = int(settings["prefilterModel"])
        typed.enableL4S = bool(settings["enableL4S"])
        typed.enableHdr = bool(settings["enableHdr"])
        typed.enableReflex = bool(settings["enableReflex"], fallback: true)
        let applied = OPNStreamPreferences.settingsByApplyingCloudVariables(typed, variables: variables, capabilities: capabilities)
        var result = settings
        result["resolution"] = applied.resolution
        result["fps"] = applied.fps
        result["codec"] = applied.codec
        result["colorQuality"] = applied.colorQuality
        result["maxBitrateMbps"] = applied.maxBitrateMbps
        result["prefilterMode"] = applied.prefilterMode
        result["prefilterSharpness"] = applied.prefilterSharpness
        result["prefilterDenoise"] = applied.prefilterDenoise
        result["prefilterModel"] = applied.prefilterModel
        result["enableL4S"] = applied.enableL4S
        result["enableHdr"] = applied.enableHdr
        result["enableReflex"] = applied.enableReflex
        return result
    }

    private func confirmNetworkPreflightIfNeeded(_ preflight: OPNStreamNetworkPreflightResult) -> Bool {
        guard preflight.serverReportedWarning || !preflight.continueRecommended else { return true }
        let alert = NSAlert()
        alert.messageText = "Network conditions may affect streaming"
        alert.informativeText = preflight.warningMessage.isEmpty ? "OpenNOW detected poor network conditions for this route." : preflight.warningMessage
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { return true }
        endStream(success: false, errorMessage: "Network preflight cancelled")
        return false
    }

    private func configureStreamViewSessionCallbacks() {
        session.configureSurface(streamView: streamView, recordingManager: streamView?.recordingManager)
    }

    private func clearCurrentSessionCallbacks() {
        streamView?.clearStreamCallbacks()
        session.clearSurfaceCallbacks(streamView: streamView)
    }

    private func ensureLoadingView(message: String) {
        if let loadingView {
            loadingView.message = message
            if loadingView.superview == nil { view.addSubview(loadingView, positioned: .above, relativeTo: nil) }
            return
        }
        let loading = OPNLoadingView(frame: view.bounds, message: message)
        loading.autoresizingMask = [.width, .height]
        loading.setSteps(["Check network route", "Allocate cloud session", "Receive stream offer", "Negotiate WebRTC", "Connected"], currentStepIndex: -1)
        loading.startAnimating()
        loadingView = loading
        statusLabel = loading.messageLabel
        loading.adPlaybackEventHandler = { [weak self] adId, action, watchedTimeInMs, pausedTimeInMs, cancelReason in
            guard let self, self.hasActiveSessionInfo else { return }
            OPNSessionManager.shared.reportSessionAd(session: self.activeSessionInfo, adId: adId, action: action, watchedTimeInMs: watchedTimeInMs, pausedTimeInMs: pausedTimeInMs, cancelReason: cancelReason) { [weak self] success, updatedInfo, _ in
                DispatchQueue.main.async {
                    guard let self, success, !updatedInfo.isEmpty else { return }
                    self.activeSessionInfo = updatedInfo
                    self.hasActiveSessionInfo = true
                }
            }
        }
        view.addSubview(loading)
    }

    private func setStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.loadingView?.message = message
            self?.statusLabel?.stringValue = message
        }
    }

    private func updateLaunchAdState(_ session: NSDictionary) {
        updateActiveSessionInfo(session)
        let queuePosition = int(session["queuePosition"])
        loadingView?.updateQueuePosition(queuePosition)
        guard let adState = session["adState"] as? [String: Any], bool(adState["isAdsRequired"]) else {
            loadingView?.clearAdPresentation()
            return
        }
        let ads = adState["sessionAds"] as? [[String: Any]] ?? []
        let ad = ads.first ?? [:]
        loadingView?.updateAdPresentation(visible: true, chipText: bool(adState["isQueuePaused"]) ? "Queue Paused" : "Sponsored Break", title: string(ad["title"], fallback: "Watch to continue"), message: string(adState["message"], fallback: "Your launch will resume automatically after the ad."), adId: string(ad["adId"], fallback: "ad"), mediaUrl: string(ad["mediaUrl"]), durationMs: int(ad["durationMs"], fallback: 30000))
    }

    private func updateActiveSessionInfo(_ session: NSDictionary) {
        guard !string(session["sessionId"]).isEmpty else { return }
        activeSessionInfo = session as? [String: Any] ?? [:]
        hasActiveSessionInfo = true
    }

    private func settingsByApplyingNegotiatedProfile(settings: [String: Any], sessionInfo: NSDictionary) -> [String: Any] {
        guard let profile = sessionInfo["negotiatedStreamProfile"] as? [String: Any], !profile.isEmpty else { return settings }
        var result = settings
        for key in ["resolution", "codec", "colorQuality"] {
            let value = string(profile[key])
            if !value.isEmpty { result[key] = value }
        }
        let fps = int(profile["fps"])
        if fps > 0 {
            result["fps"] = fps
        }
        for key in ["prefilterMode", "prefilterSharpness", "prefilterDenoise", "prefilterModel"] {
            let value = int(profile[key], fallback: -1)
            if value >= 0 {
                result[key] = value
            }
        }
        return result
    }

    private func progressMessage(for session: NSDictionary) -> String {
        if let adState = session["adState"] as? [String: Any], bool(adState["isAdsRequired"]) { return string(adState["message"], fallback: "Watch the ad to continue.") }
        let queuePosition = int(session["queuePosition"])
        if queuePosition > 2 { return "\(queuePosition - 1) gamers ahead of you." }
        if queuePosition == 2 { return "1 gamer ahead of you." }
        if queuePosition == 1 { return "You're next in queue." }
        return "Waiting for cloud session..."
    }

    private func showConnectedToast(resolution: String, fps: Int, bitrateMbps: Int, codec: String) {
        let toast = NSView(frame: NSRect(x: max(24, (view.bounds.width - 360) / 2), y: max(24, view.bounds.height - 92), width: 360, height: 68))
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 16
        toast.layer?.backgroundColor = OPNStreamViewControllerSupport.quitColor(red: 0.05, green: 0.07, blue: 0.06, alpha: 0.86).cgColor
        let title = OPNStreamViewControllerSupport.statsText(text: "Stream Connected", size: 14, weight: NSFont.Weight.semibold.rawValue, color: OPNStreamViewControllerSupport.quitColor(red: 0.92, green: 1, blue: 0.94, alpha: 1), alignment: .center)
        title.frame = NSRect(x: 18, y: 14, width: 324, height: 20)
        let detail = "\(webRTCBackendName) • \(codec.isEmpty ? "unknown" : codec) • \(fps) fps • \(bitrateMbps) Mbps" + (resolution.isEmpty ? "" : " • \(resolution)")
        let subtitle = OPNStreamViewControllerSupport.statsText(text: detail, size: 11, weight: NSFont.Weight.medium.rawValue, color: OPNStreamViewControllerSupport.quitColor(red: 0.78, green: 0.84, blue: 0.78, alpha: 1), alignment: .center)
        subtitle.frame = NSRect(x: 18, y: 40, width: 324, height: 18)
        toast.addSubview(title)
        toast.addSubview(subtitle)
        connectedToast?.removeFromSuperview()
        connectedToast = toast
        view.addSubview(toast, positioned: .above, relativeTo: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self, weak toast] in
            guard let self, self.connectedToast === toast else { return }
            toast?.removeFromSuperview()
            self.connectedToast = nil
        }
    }

    private func installQuitShortcutMonitor() {
        guard quitKeyMonitor == nil else { return }
        quitKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.streamEnded, event.window == self.view.window else { return event }
            if OPNStreamViewControllerSupport.isCommandQEvent(event) { self.requestQuitGameConfirmation(); return nil }
            if OPNStreamViewControllerSupport.isCommandNEvent(event) { self.toggleStatsOverlay(); return nil }
            if OPNStreamViewControllerSupport.isCommandHEvent(event) { self.toggleShortcutLegendOverlay(); return nil }
            if OPNStreamViewControllerSupport.isCommandMEvent(event) { _ = self.streamView?.toggleMicrophoneEnabledShortcut(); return nil }
            if OPNStreamViewControllerSupport.isCommandGEvent(event) { self.streamView?.toggleSidebarHUD(); return nil }
            if OPNStreamViewControllerSupport.isCommandREvent(event) { _ = self.streamView?.toggleRecordingShortcut(); return nil }
            if OPNStreamViewControllerSupport.isCommandLEvent(event) { OPNLogCapture.copyCapturedLogToClipboard("Stream diagnostics copied from Command-L"); return nil }
            if OPNStreamViewControllerSupport.isCommandKEvent(event) { self.toggleIdleDeviceInputMode(); return nil }
            return event
        }
    }

    private func removeQuitShortcutMonitor() {
        if let quitKeyMonitor { NSEvent.removeMonitor(quitKeyMonitor) }
        quitKeyMonitor = nil
    }

    private func toggleStatsOverlay() {
        if let statsOverlay { statsOverlay.removeFromSuperview(); self.statsOverlay = nil; if !connectedOnce { stopStatsRefreshTimer() }; return }
        let overlay = OPNStatsOverlayView(frame: statsOverlayFrame())
        statsOverlay = overlay
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
        updateStatsOverlay()
        startStatsRefreshTimer()
    }

    private func statsOverlayFrame() -> NSRect {
        NSRect(x: 16, y: max(16, view.bounds.height - 54), width: min(620, max(320, view.bounds.width - 32)), height: 32)
    }

    private func updateStatsOverlay() {
        guard let statsOverlay else { return }
        let stats = session.latestStatsSnapshot()
        statsOverlay.update(latencyMs: Int(stats.latencyMs.rounded()), bitrateMbps: stats.inboundBitrateMbps, packetsLost: stats.packetsLost, resolution: stats.resolution, fps: stats.fps, renderFps: stats.renderFps, codec: stats.codec, enhancement: stats.videoEnhancementActiveTier, framesDropped: stats.framesDropped)
    }

    private func startStatsRefreshTimer() {
        guard statsRefreshTimer == nil else { return }
        statsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateStatsOverlay() }
        }
    }

    private func stopStatsRefreshTimer() { statsRefreshTimer?.invalidate(); statsRefreshTimer = nil }

    private func startRemoteIceGraceTimer(generation: UInt) {
        cancelRemoteIceGraceTimer()
        guard recovering, connectedOnce, !streamEnded else { return }
        remoteIceGraceTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.launchGeneration == generation, !self.streamEnded, !self.remoteIceReceived else { return }
                self.remoteIceGraceTimer = nil
                self.endStream(success: false, errorMessage: "No remote ICE received after offer")
            }
        }
    }

    private func cancelRemoteIceGraceTimer() {
        remoteIceGraceTimer?.invalidate()
        remoteIceGraceTimer = nil
    }

    private func scheduleRecoveryAttemptReset(generation: UInt) {
        stableResetGeneration += 1
        let resetGeneration = stableResetGeneration
        recoveryResetTimer?.invalidate()
        recoveryResetTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.stableResetGeneration == resetGeneration, self.launchGeneration == generation, !self.streamEnded, !self.recovering, self.connectedOnce else { return }
                self.recoveryAttempt = 0
            }
        }
    }

    private func toggleShortcutLegendOverlay() {
        if let shortcutLegendOverlay { shortcutLegendOverlay.removeFromSuperview(); self.shortcutLegendOverlay = nil; return }
        let overlay = OPNShortcutLegendView(frame: shortcutLegendFrame())
        shortcutLegendOverlay = overlay
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    private func shortcutLegendFrame() -> NSRect { NSRect(x: max(24, view.bounds.width - 384), y: max(24, (view.bounds.height - 338) / 2), width: 360, height: 338) }

    private func dismissQuitGameOverlayAndRefocus(_ refocus: Bool) { quitOverlay?.removeFromSuperview(); quitOverlay = nil; if refocus { streamView?.takeFocus() } }
    private func recordStreamUserActivity() { lastStreamActivityTime = CACurrentMediaTime() }
    private func startInactivityTimer() { lastStreamActivityTime = CACurrentMediaTime(); inactivityTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.checkInactivity() } } }
    private func stopInactivityTimer() { inactivityTimer?.invalidate(); inactivityTimer = nil }
    private func checkInactivity() {
        guard connectedOnce, !recovering else { return }
        let now = CACurrentMediaTime()
        if lastStreamActivityTime <= 0 { lastStreamActivityTime = now }
        if idleDeviceInputEnabled {
            sendRandomIdleDeviceInputIfNeeded(at: now)
            return
        }
        if now - lastStreamActivityTime > 600 { requestRemoteStopForActiveSession(); endStream(success: false, errorMessage: "Session ended due to inactivity.") }
    }
    private func toggleIdleDeviceInputMode() { idleDeviceInputEnabled.toggle(); showConnectedToast(resolution: idleDeviceInputEnabled ? "Anti-AFK enabled" : "Anti-AFK disabled", fps: 0, bitrateMbps: 0, codec: "") }
    private func sendRandomIdleDeviceInputIfNeeded(at now: CFTimeInterval) {
        guard session.isInputReady, now - lastStreamActivityTime >= 240, now - lastIdleDeviceInputTime >= 240 else { return }
        let deltas: [(Int16, Int16)] = [(8, 0), (-8, 0), (0, 8), (0, -8)]
        let delta = deltas[Int.random(in: 0..<deltas.count)]
        lastIdleDeviceInputTime = now
        lastStreamActivityTime = now
        session.sendMouseMove(dx: delta.0, dy: delta.1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.streamEnded, self.session.isInputReady else { return }
            self.session.sendMouseMove(dx: -delta.0, dy: -delta.1)
        }
    }
    private func endStreamFromUserQuit() { requestRemoteStopForActiveSession(); endStream(success: true, errorMessage: "") }

    private func requestRemoteStopForActiveSession() {
        guard hasActiveSessionInfo, !remoteStopRequested else { return }
        remoteStopRequested = true
        OPNSessionManager.shared.stopSession(sessionId: string(activeSessionInfo["sessionId"]), serverIp: string(activeSessionInfo["serverIp"])) { _, _ in }
    }

    private func endStream(success: Bool, errorMessage: String) {
        guard !streamEnded else { return }
        streamEnded = true
        if !success, connectedOnce, OPNStreamViewControllerSupport.streamErrorIsRecoverable(errorMessage), recoveryAttempt < 2 {
            streamEnded = false
            recovering = true
            recoveryAttempt += 1
            launchGeneration += 1
            resetTransportForRecovery()
            DispatchQueue.main.asyncAfter(deadline: .now() + OPNStreamViewControllerSupport.recoveryDelay(forAttempt: recoveryAttempt)) { [weak self] in self?.startStreamLaunchFlow() }
            return
        }
        let displayError = success ? "" : errorMessage
        let report = healthReport.finalize(success: success, terminalError: displayError, now: CACurrentMediaTime())
        cleanup()
        onStreamEnd?(success, displayError, report)
    }

    private func resetTransportForRecovery() {
        signaling?.disconnect(); signaling = nil
        clearCurrentSessionCallbacks()
        session.stop(); session = OPNStreamSessionHandle()
        configureStreamViewSessionCallbacks()
        streamView?.setStreamActive(false)
    }

    private func startPlaytimeRefreshTimer() {
        guard playtimeRefreshTimer == nil else { return }
        playtimeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshDisplayedPlaytimeFromSessionPoll() }
        }
    }

    private func stopPlaytimeRefreshTimer() {
        playtimeRefreshTimer?.invalidate()
        playtimeRefreshTimer = nil
    }

    private func refreshDisplayedPlaytimeFromSessionPoll() {
        guard connectedOnce, !streamEnded, hasActiveSessionInfo else { return }
        let sessionId = string(activeSessionInfo["sessionId"])
        let serverIp = string(activeSessionInfo["serverIp"])
        guard !sessionId.isEmpty else { return }
        OPNSessionManager.shared.pollSession(sessionId: sessionId, serverIp: serverIp) { [weak self] success, info, _ in
            DispatchQueue.main.async {
                guard let self, success, !self.streamEnded else { return }
                self.updateActiveSessionInfo(info as NSDictionary)
                let hours = (info["remainingPlaytimeHours"] as? NSNumber)?.doubleValue ?? Double(self.string(info["remainingPlaytimeHours"])) ?? 0
                self.setRemainingPlaytimeHours(hours, unlimited: self.bool(info["remainingPlaytimeUnlimited"]))
            }
        }
    }

    private func cleanup() {
        removeQuitShortcutMonitor()
        stopStatsRefreshTimer(); stopInactivityTimer(); playtimeRefreshTimer?.invalidate(); playtimeRefreshTimer = nil
        cancelRemoteIceGraceTimer(); recoveryResetTimer?.invalidate(); recoveryResetTimer = nil
        signaling?.disconnect(); signaling = nil
        clearCurrentSessionCallbacks()
        streamView?.stopRecordingIfNeeded(); streamView?.detachFromPipeline(); streamView?.releasePointerLock()
        loadingView?.stopAnimating(); loadingView?.removeFromSuperview(); loadingView = nil
        quitOverlay?.removeFromSuperview(); quitOverlay = nil
        statsOverlay?.removeFromSuperview(); statsOverlay = nil
        shortcutLegendOverlay?.removeFromSuperview(); shortcutLegendOverlay = nil
        session.stop()
    }

    private func connectedControllerBitmap() -> UInt32 {
        var bitmap: UInt32 = 0
        for (index, controller) in GCController.controllers().prefix(Int(OPNStreamSessionHandle.maxGamepadControllers())).enumerated() where controller.extendedGamepad != nil {
            bitmap |= 1 << UInt32(index)
            bitmap |= 1 << UInt32(index + 8)
        }
        return bitmap
    }

    private func int(_ value: Any?, fallback: Int = 0) -> Int { if let value = value as? Int { return value }; if let value = value as? NSNumber { return value.intValue }; if let value = value as? String { return Int(value) ?? fallback }; return fallback }
    private func bool(_ value: Any?, fallback: Bool = false) -> Bool { if let value = value as? Bool { return value }; if let value = value as? NSNumber { return value.boolValue }; return fallback }
    private func string(_ value: Any?, fallback: String = "") -> String { if let value = value as? String { return value }; if let value = value as? NSNumber { return value.stringValue }; return fallback }
}
