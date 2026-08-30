import AppKit
import CoreVideo
import Darwin
import Foundation
import os
@preconcurrency import WebRTC

typealias OPNLibWebRTCAnswerHandler = @convention(block) (NSString, NSString) -> Void
typealias OPNLibWebRTCIceCandidateHandler = @convention(block) (NSDictionary) -> Void
typealias OPNLibWebRTCStateHandler = @convention(block) (Bool, NSString) -> Void

final class OPNLibWebRTCStreamSession: NSObject, @unchecked Sendable {
    static let maxGamepadControllers = 4

    let statsQueue = DispatchQueue(label: "io.opencg.opennow.webrtc.stats")
    private var inputController: OPNLibWebRTCInput!
    var audioController: OPNLibWebRTCAudio!
    var statsController: OPNLibWebRTCStats!
    var statsLock = os_unfair_lock_s()
    private let remoteIceLock = NSLock()

    var impl: OPNLibWebRTCSessionImpl?
    var callbackGeneration: UInt64 = 0
    private var disconnectGraceTimer: DispatchSourceTimer?
    private var nativeWindow: UnsafeMutableRawPointer?
    var settings: [String: Any] = [:]
    var remoteCandidateOverrideIp = ""
    var remoteCandidateOverridePort = 0
    var latestStats = OPNStreamStatsState()
    var previousStatsTimestampMs: UInt64 = 0
    var previousBytesReceived: UInt64 = 0
    var previousPacketsReceived: UInt64 = 0
    var previousFramesDecoded: UInt64 = 0
    var previousPacketsLost: Int64 = 0
    var configuredMaxBitrateMbps = 0
    var adaptiveBitrateMbps = 0
    var minAdaptiveBitrateMbps = 0
    var adaptiveCongestionScore = 0
    var adaptiveRecoveryScore = 0
    var lastAdaptiveBitrateChangeMs: UInt64 = 0
    var microphoneEnabled = false
    private var gameVolume = 1.0
    var microphoneVolume = 1.0
    private var localEnhancementMode = 0
    private var localEnhancementSharpness = 10
    private var localEnhancementDenoise = 0
    private var localEnhancementTargetHeight = 2160
    private var localPillarboxFillMode = 0
    private var localPillarboxFillDim = 55
    /// Packed 0xRRGGBB. Parsed once here so the render thread never touches a string.
    private var localPillarboxFillColor = 0
    private var enhancedVideoFrameCaptureEnabled = false
    var onAnswer: ((String, String) -> Void)?
    private var onIceCandidate: (([String: Any]) -> Void)?
    private var onState: ((Bool, String) -> Void)?
    private var pendingRemoteIcePayloads: [[AnyHashable: Any]] = []
    private var isRemoteDescriptionReady = false
    var onVideoFrame: ((UnsafeMutableRawPointer?) -> Void)?
    var onEnhancedVideoFrame: ((UnsafeMutableRawPointer?) -> Void)?
    var onGameAudioFrame: ((UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    var onMicrophoneAudioFrame: ((UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    var onClipboardText: ((String) -> Void)?
    var onSessionLimitUpdate: ((StreamSessionLimitUpdate) -> Void)?
    var onHapticEvent: ((_ deviceIndex: Int, _ leftAmplitude: UInt16, _ rightAmplitude: UInt16) -> Void)?
    var onMicrophoneLevel: ((Double) -> Void)?

    override init() {
        super.init()
        inputController = OPNLibWebRTCInput(owner: self)
        audioController = OPNLibWebRTCAudio(owner: self)
        statsController = OPNLibWebRTCStats(owner: self)
    }

    deinit {
        stop()
        inputController.stop()
        audioController.stopAudioDeviceMonitoring()
        audioController.stopMicrophoneLevelPolling()
        statsController.stopPolling()
    }

    static func isAvailable() -> Bool { true }

    static func iceUfrag(fromOfferSdp offerSdp: String) -> String {
        NVSTSessionDescriptionBuilder.iceUsernameFragment(from: offerSdp)
    }

    static func sdpMediaSummary(_ sdp: String, label: String) -> String {
        WebRTCSdp.buildSdpMediaSummary(sdp, label: label)
    }

    func start(sessionInfo: [String: Any], offerSdp: String, settings: [String: Any], answerHandler: @escaping OPNLibWebRTCAnswerHandler, localIceCandidateHandler: @escaping OPNLibWebRTCIceCandidateHandler, stateHandler: @escaping OPNLibWebRTCStateHandler) {
        onAnswer = { sdp, nvstSdp in answerHandler(sdp as NSString, nvstSdp as NSString) }
        onIceCandidate = { candidate in localIceCandidateHandler(candidate as NSDictionary) }
        onState = { connected, error in stateHandler(connected, error as NSString) }
        start(sessionInfo: sessionInfo, offerSdp: offerSdp, settings: settings)
    }

    func start(sessionInfo: [String: Any], offerSdp: String, settings: [String: Any]) {
        stop()
        callbackGeneration &+= 1
        remoteIceLock.withLock {
            pendingRemoteIcePayloads.removeAll()
            isRemoteDescriptionReady = false
        }
        let generation = callbackGeneration
        self.settings = settings
        applyStartSettings(settings)
        resetStats(sessionInfo: sessionInfo, settings: settings)

        guard Self.isAvailable() else {
            handleConnectionState(false, error: "WebRTC.framework unavailable")
            return
        }
        guard let (impl, factory) = makeSessionImpl() else {
            handleConnectionState(false, error: "failed to create libwebrtc factory")
            return
        }

        let remoteNVSTSdp = WebRTCSdp.string(sessionInfo["nvstSdp"])
        let remoteNVSTServerOverrides = WebRTCSdp.string(sessionInfo["nvstServerOverrides"])
        let nvstProfile = NVSTTransportProfile(sdp: remoteNVSTSdp, serverOverrides: remoteNVSTServerOverrides)
        let configuration = makeConfiguration(sessionInfo: sessionInfo, nvstProfile: nvstProfile)

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        impl.peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: impl)
        guard let peerConnection = impl.peerConnection else {
            handleConnectionState(false, error: "failed to create libwebrtc peer connection")
            return
        }
        self.impl = impl
        audioController.startAudioDeviceMonitoring()
        inputController.configureInput(nvstProfile.input)
        inputController.createInputChannel(sessionImpl: impl)

        let manualIceMedia = WebRTCSdp.dictionary(sessionInfo["mediaConnectionInfo"])
        let manualIceIp = extractPublicIp(WebRTCSdp.string(manualIceMedia["ip"]).isEmpty ? WebRTCSdp.string(sessionInfo["serverIp"]) : WebRTCSdp.string(manualIceMedia["ip"]))
        let manualIcePort = WebRTCSdp.int(manualIceMedia["port"], fallback: 47998)
        remoteCandidateOverrideIp = manualIceIp
        remoteCandidateOverridePort = manualIcePort

        let processedOfferSdp = processedOffer(offerSdp, factory: factory, manualIceIp: manualIceIp, manualIcePort: manualIcePort)
        WebRTCSdp.logVideoSdpSummary("offer-video", processedOfferSdp)
        negotiate(impl: impl, peerConnection: peerConnection, context: NegotiationContext(
            generation: generation,
            constraints: constraints,
            offerSdp: offerSdp,
            remoteOfferSdp: processedOfferSdp,
            remoteNVSTSdp: remoteNVSTSdp,
            remoteNVSTServerOverrides: remoteNVSTServerOverrides,
            canRetryOriginalOffer: processedOfferSdp != offerSdp,
            shouldInjectDirectCandidates: configuration.iceServers.isEmpty,
            manualIceIp: manualIceIp
        ))
    }

    /// Bitrate envelope, audio levels and the local video enhancement this session starts with.
    func applyStartSettings(_ settings: [String: Any]) {
        configuredMaxBitrateMbps = max(1, WebRTCSdp.int(settings["maxBitrateMbps"], fallback: 50))
        adaptiveBitrateMbps = configuredMaxBitrateMbps
        minAdaptiveBitrateMbps = min(configuredMaxBitrateMbps, max(8, configuredMaxBitrateMbps * 35 / 100))
        adaptiveCongestionScore = 0
        adaptiveRecoveryScore = 0
        lastAdaptiveBitrateChangeMs = 0
        microphoneEnabled = WebRTCSdp.string(settings["microphoneMode"]) == "voice-activity"
        gameVolume = WebRTCSdp.clampedDouble(settings["gameVolume"], fallback: 1, minimum: 0, maximum: 1)
        microphoneVolume = WebRTCSdp.clampedDouble(settings["microphoneVolume"], fallback: 1, minimum: 0, maximum: 1)
        setLocalVideoEnhancement(
            mode: WebRTCSdp.int(settings["upscalingMode"]),
            sharpness: WebRTCSdp.int(settings["upscalingSharpness"], fallback: 10),
            denoise: WebRTCSdp.int(settings["upscalingDenoise"]),
            targetHeight: WebRTCSdp.int(settings["upscalingTargetHeight"], fallback: 2160),
            pillarboxFillMode: WebRTCSdp.int(settings["pillarboxFillMode"]),
            pillarboxFillDim: WebRTCSdp.int(settings["pillarboxFillDim"], fallback: 55),
            pillarboxFillColor: WebRTCSdp.packedColor(settings["pillarboxFillColor"])
        )
    }

    func stop() {
        callbackGeneration &+= 1
        cancelDisconnectGraceTimer()
        audioController.stopAudioDeviceMonitoring()
        statsController.stopPolling()
        audioController.stopMicrophoneLevelPolling()
        inputController.stop()
        remoteIceLock.withLock {
            pendingRemoteIcePayloads.removeAll()
            isRemoteDescriptionReady = false
        }
        if let impl {
            impl.owner = nil
            impl.reliableInputChannel?.delegate = nil
            impl.partialInputChannel?.delegate = nil
            impl.peerConnection?.delegate = nil
            if let track = impl.remoteVideoTrack, let renderer = impl.remoteVideoRenderer { track.remove(renderer) }
            impl.remoteAudioTrack?.isEnabled = false
            impl.localMicrophoneTrack?.isEnabled = false
            let remoteVideoView = impl.remoteVideoView
            impl.remoteVideoView = nil
            if Thread.isMainThread {
                MainActor.assumeIsolated { remoteVideoView?.removeFromSuperview() }
            } else {
                Task { @MainActor in remoteVideoView?.removeFromSuperview() }
            }
            impl.reliableInputChannel?.close()
            impl.partialInputChannel?.close()
            impl.peerConnection?.close()
            _ = impl.audioDevice?.terminateDevice()
            impl.audioDevice = nil
        }
        impl = nil
    }

    func addRemoteIceCandidatePayload(_ payload: [AnyHashable: Any]) {
        if WebRTCSdp.bool(payload["endOfCandidates"]) { return }
        guard remoteDescriptionReady, let peerConnection = impl?.peerConnection else {
            bufferRemoteIceCandidatePayload(payload)
            return
        }
        addRemoteIceCandidatePayload(payload, peerConnection: peerConnection)
    }

    private var remoteDescriptionReady: Bool {
        remoteIceLock.withLock { isRemoteDescriptionReady }
    }

    private func bufferRemoteIceCandidatePayload(_ payload: [AnyHashable: Any]) {
        let count = remoteIceLock.withLock { () -> Int in
            pendingRemoteIcePayloads.append(payload)
            if pendingRemoteIcePayloads.count > 120 {
                pendingRemoteIcePayloads.removeFirst(pendingRemoteIcePayloads.count - 120)
            }
            return pendingRemoteIcePayloads.count
        }
        WebRTCMediaTelemetry.capture("webrtc.native.remote_ice.buffered", level: .debug, message: "Buffered remote ICE candidate until remote description is ready.", attributes: ["pending": String(count)])
    }

    func markRemoteDescriptionReady() {
        let buffered = remoteIceLock.withLock { () -> [[AnyHashable: Any]] in
            isRemoteDescriptionReady = true
            let payloads = pendingRemoteIcePayloads
            pendingRemoteIcePayloads.removeAll()
            return payloads
        }
        guard let peerConnection = impl?.peerConnection else { return }
        for payload in buffered {
            addRemoteIceCandidatePayload(payload, peerConnection: peerConnection)
        }
        if !buffered.isEmpty {
            WebRTCMediaTelemetry.capture("webrtc.native.remote_ice.flushed", level: .debug, message: "Flushed buffered remote ICE candidates.", attributes: ["count": String(buffered.count)])
        }
    }

    private func addRemoteIceCandidatePayload(_ payload: [AnyHashable: Any], peerConnection: RTCPeerConnection) {
        let candidate = rewrittenRemoteCandidate(WebRTCSdp.string(payload["candidate"]))
        guard !candidate.isEmpty else { return }
        let sdpMid = WebRTCSdp.string(payload["sdpMid"])
        let sdpMLineIndex = Int32(WebRTCSdp.int(payload["sdpMLineIndex"]))
        let rtcCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid.isEmpty ? nil : sdpMid)
        peerConnection.add(rtcCandidate) { error in
            if let error { WebRTCMediaTelemetry.capture("webrtc.native.remote_ice.add.error", level: .warning, message: "Failed to add remote ICE candidate.", attributes: ["error": error.localizedDescription]) }
        }
    }

    func injectManualIceCandidate(offerSdp: String, serverIceUfrag: String, ip: String, port: Int) {
        guard !ip.isEmpty else { return }
        let targets = WebRTCSdp.extractIceTargets(from: offerSdp)
        guard !targets.isEmpty else { return }
        let candidate = "candidate:1 1 udp 2130706431 \(ip) \(port) typ host generation 0 ufrag \(serverIceUfrag) network-cost 999"
        WebRTCMediaTelemetry.capture("webrtc.native.remote_ice.inject", level: .debug, message: "Injecting direct ICE candidates.", attributes: ["count": String(targets.count), "port": String(port)])
        for target in targets {
            addRemoteIceCandidatePayload(["candidate": candidate, "sdpMid": target.mid, "sdpMLineIndex": target.mLineIndex, "usernameFragment": serverIceUfrag])
        }
    }

    var isInputReady: Bool { inputController.isInputReady }
    func setNativeWindow(_ nativeWindow: UnsafeMutableRawPointer?) { self.nativeWindow = nativeWindow }
    func setMicrophoneEnabled(_ enabled: Bool) { microphoneEnabled = enabled; audioController.setMicrophoneEnabled(enabled, sessionImpl: impl) }
    func setGameVolume(_ volume: Double) { gameVolume = min(max(volume, 0), 1); audioController.setGameVolume(gameVolume, sessionImpl: impl) }
    func setMicrophoneVolume(_ volume: Double) { microphoneVolume = min(max(volume, 0), 1); audioController.setMicrophoneVolume(microphoneVolume, sessionImpl: impl) }
    func setMaxBitrateMbps(_ mbps: Int) { configuredMaxBitrateMbps = max(1, mbps); applyRuntimeBitrateLimit(configuredMaxBitrateMbps, reason: "user setting") }
    func setEnhancedVideoFrameCaptureEnabled(_ enabled: Bool) { enhancedVideoFrameCaptureEnabled = enabled }
    func setLocalVideoEnhancement(mode: Int, sharpness: Int, denoise: Int, targetHeight: Int, pillarboxFillMode: Int, pillarboxFillDim: Int, pillarboxFillColor: Int) { localEnhancementMode = mode; localEnhancementSharpness = sharpness; localEnhancementDenoise = denoise; localEnhancementTargetHeight = targetHeight; localPillarboxFillMode = pillarboxFillMode; localPillarboxFillDim = pillarboxFillDim; localPillarboxFillColor = pillarboxFillColor }
    func sendUtf8Text(_ text: String) { inputController.sendUtf8Text(text, sessionImpl: impl) }
    func sendKey(keycode: UInt16, scancode: UInt16, modifiers: UInt16, down: Bool) { inputController.sendKey(keycode: keycode, scancode: scancode, modifiers: modifiers, down: down, sessionImpl: impl) }
    func sendMouseMove(dx: Int16, dy: Int16) { inputController.sendMouseMove(dx: dx, dy: dy, sessionImpl: impl) }
    func sendMouseButton(button: UInt8, down: Bool) { inputController.sendMouseButton(button: button, down: down, sessionImpl: impl) }
    func sendMouseWheel(delta: Int16) { inputController.sendMouseWheel(delta: delta, sessionImpl: impl) }
    func sendGamepadState(controllerId: UInt16, buttons: UInt16, leftTrigger: UInt8, rightTrigger: UInt8, leftStickX: Int16, leftStickY: Int16, rightStickX: Int16, rightStickY: Int16, connected: Bool, bitmap: UInt16, timestampUs: UInt64) {
        inputController.sendGamepadState(controllerId: controllerId, buttons: buttons, leftTrigger: leftTrigger, rightTrigger: rightTrigger, leftStickX: leftStickX, leftStickY: leftStickY, rightStickX: rightStickX, rightStickY: rightStickY, timestampUs: timestampUs, bitmap: bitmap, sessionImpl: impl)
    }

    func latestStatsSnapshot() -> OPNStreamStatsSnapshot {
        os_unfair_lock_lock(&statsLock)
        let stats = latestStats
        os_unfair_lock_unlock(&statsLock)
        return OPNStreamStatsSnapshot(available: stats.available,
                                      transport: stats.transport,
                                      latencyMs: stats.latencyMs,
                                      jitterMs: stats.jitterMs,
                                      inboundBitrateMbps: stats.inboundBitrateMbps,
                                      packetLossPercent: stats.packetLossPercent,
                                      decodeTimeMs: stats.decodeTimeMs,
                                      renderFps: stats.renderFps,
                                      framesReceived: stats.framesReceived,
                                      framesDropped: stats.framesDropped,
                                      packetsLost: stats.packetsLost,
                                      fps: stats.fps,
                                      resolution: stats.resolution,
                                      codec: stats.codec,
                                      videoEnhancementActiveTier: stats.videoEnhancementActiveTier,
                                      videoEnhancementConfiguredTier: stats.videoEnhancementConfiguredTier,
                                      videoEnhancementSourceResolution: stats.videoEnhancementSourceResolution,
                                      videoEnhancementDrawableResolution: stats.videoEnhancementDrawableResolution,
                                      videoEnhancementFallbackReason: stats.videoEnhancementFallbackReason,
                                      videoEnhancementDiagnostics: stats.videoEnhancementDiagnostics,
                                      videoEnhancementFrameTimeMs: stats.videoEnhancementFrameTimeMs,
                                      videoEnhancementDroppedFrames: stats.videoEnhancementDroppedFrames,
                                      videoFrameIntervalMs: stats.videoFrameIntervalMs,
                                      videoMaxFrameIntervalMs: stats.videoMaxFrameIntervalMs)
    }

    var targetFps: Int { WebRTCSdp.int(settings["fps"], fallback: 60) }
    var gameVolumeLevel: Double { gameVolume }
    func localVideoEnhancement() -> (Int32, Int32, Int32, Int32, Int32, Int32, Int32) { (Int32(localEnhancementMode), Int32(localEnhancementSharpness), Int32(localEnhancementDenoise), Int32(localEnhancementTargetHeight), Int32(localPillarboxFillMode), Int32(localPillarboxFillDim), Int32(localPillarboxFillColor)) }
    func wantsEnhancedVideoFrames() -> Bool { enhancedVideoFrameCaptureEnabled }
    func nativeWindowHandle() -> UnsafeMutableRawPointer? { nativeWindow }
    func isMicrophoneCaptureEnabled() -> Bool { microphoneEnabled && impl?.localMicrophoneTrack?.isEnabled == true }
    func handleVideoFrame(_ frame: UnsafeMutableRawPointer?) { onVideoFrame?(frame) }
    func handleEnhancedVideoFrame(_ pixelBuffer: CVPixelBuffer?) { if let pixelBuffer { onEnhancedVideoFrame?(Unmanaged.passUnretained(pixelBuffer).toOpaque()) } }
    func handleClipboardText(_ text: String) { onClipboardText?(text) }
    func handleSessionLimitUpdate(_ update: StreamSessionLimitUpdate) { onSessionLimitUpdate?(update) }
    func handleHapticEvent(deviceIndex: Int, leftAmplitude: UInt16, rightAmplitude: UInt16) { onHapticEvent?(deviceIndex, leftAmplitude, rightAmplitude) }
    func handleCapturedMicrophoneLevel(_ level: Double) { handleMicrophoneLevel(level * microphoneVolume) }
    func handleMicrophoneLevel(_ level: Double) { onMicrophoneLevel?(level) }
    func handleGameAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) { onGameAudioFrame?(audioBufferList, frameCount, sampleRate, channels) }
    func handleMicrophoneAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) { onMicrophoneAudioFrame?(audioBufferList, frameCount, sampleRate, channels) }
    func refreshAudioDevices() { audioController.refreshAudioDevices(sessionImpl: impl) }

    func handleLocalIceCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32) {
        guard !WebRTCSdp.isTCPIceCandidate(candidate) else { return }
        onIceCandidate?(["candidate": candidate, "sdpMid": sdpMid, "sdpMLineIndex": Int(sdpMLineIndex), "usernameFragment": iceUsernameFragment(fromCandidate: candidate)])
    }

    func handleConnectionState(_ connected: Bool, error: String) {
        if connected {
            os_unfair_lock_lock(&statsLock)
            latestStats.available = true
            latestStats.videoPipelineMode = "libwebrtc connected"
            os_unfair_lock_unlock(&statsLock)
            statsController.startPolling(sessionImpl: impl, queue: statsQueue)
        } else {
            statsController.stopPolling()
        }
        onState?(connected, error)
    }

    func handleDataChannelState(label: String, open: Bool) {
        inputController.handleDataChannelState(label: label, open: open)
    }

    func handleDataChannelMessage(label: String, data: Data) {
        inputController.handleDataChannelMessage(label: label, data: data, sessionImpl: impl)
    }

    func cancelDisconnectGraceTimer() {
        disconnectGraceTimer?.cancel()
        disconnectGraceTimer = nil
    }

    func startDisconnectGraceTimer(reason: String) {
        cancelDisconnectGraceTimer()
        let generation = callbackGeneration
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(10000))
        timer.setEventHandler { [weak self] in
            guard let self, self.callbackGeneration == generation else { return }
            self.handleConnectionState(false, error: reason)
        }
        disconnectGraceTimer = timer
        timer.resume()
    }

    func setVideoRendererState(sink: String, pipelineMode: String) {
        os_unfair_lock_lock(&statsLock)
        latestStats.videoSink = sink
        latestStats.videoPipelineMode = pipelineMode
        os_unfair_lock_unlock(&statsLock)
    }

    func setVideoRenderDiagnostics(pixelFormat: String, renderMode: String, frameSource: String, renderPath: String, fallback: String, enhancementConfiguredTier: String, enhancementActiveTier: String, enhancementFallbackReason: String, enhancementSourceResolution: String, enhancementDrawableResolution: String, enhancementDiagnostics: String, enhancementFrameTimeMs: Double, enhancementDroppedFrames: UInt64, frameIntervalMs: Double, maxFrameIntervalMs: Double) {
        os_unfair_lock_lock(&statsLock)
        latestStats.videoPixelFormat = pixelFormat
        latestStats.videoRenderMode = renderMode
        latestStats.videoFrameSource = frameSource
        latestStats.videoRenderPath = renderPath
        latestStats.videoRendererFallback = fallback
        latestStats.videoEnhancementConfiguredTier = enhancementConfiguredTier
        latestStats.videoEnhancementActiveTier = enhancementActiveTier
        latestStats.videoEnhancementFallbackReason = enhancementFallbackReason
        latestStats.videoEnhancementSourceResolution = enhancementSourceResolution
        latestStats.videoEnhancementDrawableResolution = enhancementDrawableResolution
        latestStats.videoEnhancementDiagnostics = enhancementDiagnostics
        latestStats.videoEnhancementFrameTimeMs = enhancementFrameTimeMs
        latestStats.videoEnhancementDroppedFrames = enhancementDroppedFrames
        latestStats.videoFrameIntervalMs = frameIntervalMs
        latestStats.videoMaxFrameIntervalMs = maxFrameIntervalMs
        os_unfair_lock_unlock(&statsLock)
    }

}
