import AppKit
import CoreVideo
import Foundation
@preconcurrency import WebRTC

typealias OPNLibWebRTCAnswerHandler = @convention(block) (NSString, NSString) -> Void
typealias OPNLibWebRTCIceCandidateHandler = @convention(block) (NSDictionary) -> Void
typealias OPNLibWebRTCStateHandler = @convention(block) (Bool, NSString) -> Void

final class OPNLibWebRTCStreamSession: NSObject, @unchecked Sendable {
    static let maxGamepadControllers = 4

    private let statsQueue = DispatchQueue(label: "io.opencg.opennow.webrtc.stats")
    private var inputController: OPNLibWebRTCInput!
    private var audioController: OPNLibWebRTCAudio!
    private var statsController: OPNLibWebRTCStats!
    private let statsLock = NSLock()

    private var impl: OPNLibWebRTCSessionImpl?
    private var callbackGeneration: UInt64 = 0
    private var disconnectGraceTimer: DispatchSourceTimer?
    private var nativeWindow: UnsafeMutableRawPointer?
    private var settings: [String: Any] = [:]
    private var latestStats = OPNStreamStatsState()
    private var previousStatsTimestampMs: UInt64 = 0
    private var previousBytesReceived: UInt64 = 0
    private var previousPacketsReceived: UInt64 = 0
    private var previousFramesDecoded: UInt64 = 0
    private var previousPacketsLost: Int64 = 0
    private var configuredMaxBitrateMbps = 0
    private var adaptiveBitrateMbps = 0
    private var minAdaptiveBitrateMbps = 0
    private var adaptiveCongestionScore = 0
    private var adaptiveRecoveryScore = 0
    private var lastAdaptiveBitrateChangeMs: UInt64 = 0
    private var microphoneEnabled = false
    private var gameVolume = 1.0
    private var microphoneVolume = 1.0
    private var localEnhancementMode = 1
    private var localEnhancementSharpness = 4
    private var localEnhancementDenoise = 0
    private var localEnhancementTargetHeight = 2160
    private var enhancedVideoFrameCaptureEnabled = false
    private var onAnswer: ((String, String) -> Void)?
    private var onIceCandidate: (([String: Any]) -> Void)?
    private var onState: ((Bool, String) -> Void)?
    var onVideoFrame: ((UnsafeMutableRawPointer?) -> Void)?
    var onEnhancedVideoFrame: ((UnsafeMutableRawPointer?) -> Void)?
    var onGameAudioFrame: ((UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    var onClipboardText: ((String) -> Void)?
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
        extractIceUfrag(from: offerSdp)
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
        let generation = callbackGeneration
        self.settings = settings
        configuredMaxBitrateMbps = max(1, int(settings["maxBitrateMbps"], fallback: 50))
        adaptiveBitrateMbps = configuredMaxBitrateMbps
        minAdaptiveBitrateMbps = min(configuredMaxBitrateMbps, max(8, configuredMaxBitrateMbps * 35 / 100))
        adaptiveCongestionScore = 0
        adaptiveRecoveryScore = 0
        lastAdaptiveBitrateChangeMs = 0
        if string(settings["microphoneMode"]) != "disabled", !microphoneEnabled {
            microphoneEnabled = string(settings["microphoneMode"]) == "voice-activity"
        }
        resetStats(sessionInfo: sessionInfo, settings: settings)

        guard Self.isAvailable() else {
            handleConnectionState(false, error: "WebRTC.framework unavailable")
            return
        }

        let impl = OPNLibWebRTCSessionImpl(owner: self)
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        impl.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        guard let factory = impl.factory else {
            handleConnectionState(false, error: "failed to create libwebrtc factory")
            return
        }

        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers(from: sessionInfo)
        NSLog("[LibWebRTC] configured ICE servers=%d", configuration.iceServers.count)
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.iceConnectionReceivingTimeout = 30_000

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        impl.peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: impl)
        guard let peerConnection = impl.peerConnection else {
            handleConnectionState(false, error: "failed to create libwebrtc peer connection")
            return
        }
        self.impl = impl
        audioController.startAudioDeviceMonitoring()
        inputController.createInputChannel(sessionImpl: impl)

        var processedOfferSdp = offerSdp
        let requestedCodec = normalizedCodec(string(settings["codec"]))
        let requestedCodecSupported = OPNWebRTCCodecSupport.supportsCodec(factory: factory, normalizedCodec: requestedCodec)
        if requestedCodec == "H265", requestedCodecSupported, envFlagEnabled("OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE", defaultValue: true) {
            let support = OPNWebRTCCodecSupport.h265ReceiverSupport(factory: factory)
            processedOfferSdp = rewriteH265OfferForReceiver(processedOfferSdp, maxMainLevelId: int(support["maxMainLevelId"]), maxMain10LevelId: int(support["maxMain10LevelId"]), supportsHighTier: bool(support["supportsHighTier"]))
        }
        if isSupportedCodecPreference(requestedCodec), requestedCodecSupported, envFlagEnabled("OPN_ENABLE_LIBWEBRTC_CODEC_FILTER", defaultValue: false) {
            processedOfferSdp = preferCodecInOffer(processedOfferSdp, normalizedCodec: requestedCodec)
        } else if !requestedCodec.isEmpty, !requestedCodecSupported {
            NSLog("[LibWebRTC] Requested codec %@ is not supported by this WebRTC.framework; retaining full offer", requestedCodec)
        }
        let remoteOfferSdp = processedOfferSdp
        let canRetryOriginalOffer = processedOfferSdp != offerSdp
        logVideoSdpSummary("offer-video", remoteOfferSdp)

        @Sendable func handleRemoteDescriptionSet(impl: OPNLibWebRTCSessionImpl, peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
            self.prepareMicrophoneIfNeeded(impl: impl, factory: factory)
            let answerCodec = normalizedCodec(string(self.settings["codec"]))
            if !answerCodec.isEmpty, !OPNWebRTCCodecSupport.applyVideoCodecPreference(factory: factory, peerConnection: peerConnection, normalizedCodec: answerCodec) {
                NSLog("[LibWebRTC] No video transceiver accepted %@ codec preference before answer", answerCodec)
            }
            peerConnection.answer(for: constraints) { [weak self, weak impl] answer, answerError in
                guard let self, self.callbackGeneration == generation else { return }
                guard let impl, let peerConnection = impl.peerConnection, let answer else {
                    self.handleConnectionState(false, error: "createAnswer failed: \(answerError?.localizedDescription ?? "unknown")")
                    return
                }
                let mungedAnswer = envFlagEnabled("OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE", defaultValue: false) ? mungeAnswerSdp(answer.sdp, maxBitrateKbps: max(1000, int(self.settings["maxBitrateMbps"], fallback: 50) * 1000)) : answer.sdp
                let answerSdp = alignH265AnswerFmtpToOffer(mungedAnswer, offerSdp: remoteOfferSdp)
                logVideoSdpSummary("answer-video", answerSdp)
                guard videoSdpHasMediaCodec(answerSdp) else {
                    self.handleConnectionState(false, error: "createAnswer produced no negotiated video media codec")
                    return
                }
                let localAnswer = RTCSessionDescription(type: .answer, sdp: answerSdp)
                peerConnection.setLocalDescription(localAnswer) { [weak self] localError in
                    guard let self, self.callbackGeneration == generation else { return }
                    if let localError {
                        self.handleConnectionState(false, error: "setLocalDescription failed: \(localError.localizedDescription)")
                        return
                    }
                    self.statsLock.withLock { self.latestStats.videoPipelineMode = "libwebrtc answer sent" }
                    self.onAnswer?(answerSdp, buildNvstSdp(settings: self.settings, credentials: extractIceCredentials(from: answerSdp)))
                }
            }
        }

        let offer = RTCSessionDescription(type: .offer, sdp: remoteOfferSdp)
        peerConnection.setRemoteDescription(offer) { [weak self, weak impl] error in
            guard let self, self.callbackGeneration == generation else { return }
            if let error {
                guard canRetryOriginalOffer else {
                    self.handleConnectionState(false, error: "setRemoteDescription failed: \(error.localizedDescription)")
                    return
                }
                guard let impl, let peerConnection = impl.peerConnection, impl.factory != nil else { return }
                let originalOffer = RTCSessionDescription(type: .offer, sdp: offerSdp)
                peerConnection.setRemoteDescription(originalOffer) { [weak self, weak impl] retryError in
                    guard let self, self.callbackGeneration == generation else { return }
                    guard retryError == nil else {
                        self.handleConnectionState(false, error: "setRemoteDescription failed: \(retryError?.localizedDescription ?? error.localizedDescription)")
                        return
                    }
                    guard let impl, let peerConnection = impl.peerConnection, let factory = impl.factory else { return }
                    handleRemoteDescriptionSet(impl: impl, peerConnection: peerConnection, factory: factory)
                }
                return
            }
            guard let impl, let peerConnection = impl.peerConnection, let factory = impl.factory else { return }
            handleRemoteDescriptionSet(impl: impl, peerConnection: peerConnection, factory: factory)
        }
    }

    func stop() {
        callbackGeneration &+= 1
        cancelDisconnectGraceTimer()
        audioController.stopAudioDeviceMonitoring()
        statsController.stopPolling()
        audioController.stopMicrophoneLevelPolling()
        inputController.stop()
        if let impl {
            impl.owner = nil
            impl.reliableInputChannel?.delegate = nil
            impl.partialInputChannel?.delegate = nil
            impl.peerConnection?.delegate = nil
            if let track = impl.remoteVideoTrack, let renderer = impl.remoteVideoRenderer { track.remove(renderer) }
            impl.remoteAudioTrack?.isEnabled = false
            impl.localMicrophoneTrack?.isEnabled = false
            if Thread.isMainThread {
                MainActor.assumeIsolated { impl.remoteVideoView?.removeFromSuperview() }
            } else {
                DispatchQueue.main.sync { impl.remoteVideoView?.removeFromSuperview() }
            }
            impl.reliableInputChannel?.close()
            impl.partialInputChannel?.close()
            impl.peerConnection?.close()
        }
        impl = nil
    }

    func addRemoteIceCandidatePayload(_ payload: [AnyHashable: Any]) {
        guard let peerConnection = impl?.peerConnection else { return }
        let candidate = string(payload["candidate"])
        guard !candidate.isEmpty else { return }
        let sdpMid = string(payload["sdpMid"])
        let sdpMLineIndex = Int32(int(payload["sdpMLineIndex"]))
        let rtcCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid.isEmpty ? nil : sdpMid)
        peerConnection.add(rtcCandidate) { error in
            if let error { NSLog("[LibWebRTC] addIceCandidate failed: %@", error.localizedDescription) }
        }
    }

    func injectManualIceCandidate(sessionInfo: [String: Any], offerSdp: String, serverIceUfrag: String) {
        let media = dictionary(sessionInfo["mediaConnectionInfo"])
        let ip = extractPublicIp(string(media["ip"]).isEmpty ? string(sessionInfo["serverIp"]) : string(media["ip"]))
        guard !ip.isEmpty else { return }
        let target = extractVideoIceTarget(from: offerSdp)
        guard target.mLineIndex >= 0 else { return }
        let candidate = "candidate:1 1 udp 2130706431 \(ip) \(int(media["port"], fallback: 47998)) typ host generation 0 ufrag \(serverIceUfrag) network-cost 999"
        addRemoteIceCandidatePayload(["candidate": candidate, "sdpMid": target.mid, "sdpMLineIndex": target.mLineIndex, "usernameFragment": serverIceUfrag])
    }

    var isInputReady: Bool { inputController.isInputReady }
    func setNativeWindow(_ nativeWindow: UnsafeMutableRawPointer?) { self.nativeWindow = nativeWindow }
    func setMicrophoneEnabled(_ enabled: Bool) { microphoneEnabled = enabled; audioController.setMicrophoneEnabled(enabled, sessionImpl: impl) }
    func setGameVolume(_ volume: Double) { gameVolume = min(max(volume, 0), 1); audioController.setGameVolume(gameVolume, sessionImpl: impl) }
    func setMicrophoneVolume(_ volume: Double) { microphoneVolume = min(max(volume, 0), 1); audioController.setMicrophoneVolume(microphoneVolume, sessionImpl: impl) }
    func setMaxBitrateMbps(_ mbps: Int) { configuredMaxBitrateMbps = max(1, mbps); applyRuntimeBitrateLimit(configuredMaxBitrateMbps, reason: "user setting") }
    func setEnhancedVideoFrameCaptureEnabled(_ enabled: Bool) { enhancedVideoFrameCaptureEnabled = enabled }
    func setLocalVideoEnhancement(mode: Int, sharpness: Int, denoise: Int, targetHeight: Int) { localEnhancementMode = mode; localEnhancementSharpness = sharpness; localEnhancementDenoise = denoise; localEnhancementTargetHeight = targetHeight }
    func sendUtf8Text(_ text: String) { inputController.sendUtf8Text(text, sessionImpl: impl) }
    func sendKey(keycode: UInt16, scancode: UInt16, modifiers: UInt16, down: Bool) { inputController.sendKey(keycode: keycode, scancode: scancode, modifiers: modifiers, down: down, sessionImpl: impl) }
    func sendMouseMove(dx: Int16, dy: Int16) { inputController.sendMouseMove(dx: dx, dy: dy, lowLatencyMode: lowLatencyMode, sessionImpl: impl) }
    func sendMouseButton(button: UInt8, down: Bool) { inputController.sendMouseButton(button: button, down: down, sessionImpl: impl) }
    func sendMouseWheel(delta: Int16) { inputController.sendMouseWheel(delta: delta, sessionImpl: impl) }
    func sendGamepadState(controllerId: UInt16, buttons: UInt16, leftTrigger: UInt8, rightTrigger: UInt8, leftStickX: Int16, leftStickY: Int16, rightStickX: Int16, rightStickY: Int16, connected: Bool, bitmap: UInt16, timestampUs: UInt64) {
        guard connected else { return }
        inputController.sendGamepadState(controllerId: controllerId, buttons: buttons, leftTrigger: leftTrigger, rightTrigger: rightTrigger, leftStickX: leftStickX, leftStickY: leftStickY, rightStickX: rightStickX, rightStickY: rightStickY, timestampUs: timestampUs, bitmap: bitmap, lowLatencyMode: lowLatencyMode, sessionImpl: impl)
    }

    @MainActor func configureSurface(streamView: OPNStreamView?, recordingManager: OPNStreamRecordingManager?) {
        OPNLibWebRTCSessionSurface.configure(session: self, streamView: streamView, recordingManager: recordingManager)
    }

    @MainActor func clearSurfaceCallbacks(streamView: OPNStreamView?) { streamView?.clearStreamCallbacks() }

    func latestStatsSnapshot() -> OPNStreamStatsSnapshot {
        let stats = statsLock.withLock { latestStats }
        return OPNStreamStatsSnapshot(available: stats.available,
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
                                      videoEnhancementDroppedFrames: stats.videoEnhancementDroppedFrames)
    }

    var lowLatencyMode: Bool { bool(settings["lowLatencyMode"]) }
    var targetFps: Int { int(settings["fps"], fallback: 60) }
    var gameVolumeLevel: Double { gameVolume }
    func localVideoEnhancement() -> (Int32, Int32, Int32, Int32) { (Int32(localEnhancementMode), Int32(localEnhancementSharpness), Int32(localEnhancementDenoise), Int32(localEnhancementTargetHeight)) }
    func wantsEnhancedVideoFrames() -> Bool { enhancedVideoFrameCaptureEnabled }
    func nativeWindowHandle() -> UnsafeMutableRawPointer? { nativeWindow }
    func handleVideoFrame(_ frame: UnsafeMutableRawPointer?) { onVideoFrame?(frame) }
    func handleEnhancedVideoFrame(_ pixelBuffer: CVPixelBuffer?) { if let pixelBuffer { onEnhancedVideoFrame?(Unmanaged.passUnretained(pixelBuffer).toOpaque()) } }
    func handleClipboardText(_ text: String) { onClipboardText?(text) }
    func handleMicrophoneLevel(_ level: Double) { onMicrophoneLevel?(level) }
    func handleGameAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) { onGameAudioFrame?(audioBufferList, frameCount, sampleRate, channels) }
    func refreshAudioDevices() { audioController.refreshAudioDevices(sessionImpl: impl) }

    func handleLocalIceCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32) {
        onIceCandidate?(["candidate": candidate, "sdpMid": sdpMid, "sdpMLineIndex": Int(sdpMLineIndex)])
    }

    func handleConnectionState(_ connected: Bool, error: String) {
        if connected {
            statsLock.withLock {
                latestStats.available = true
                latestStats.videoPipelineMode = "libwebrtc connected"
            }
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
        timer.schedule(deadline: .now() + .milliseconds(3000))
        timer.setEventHandler { [weak self] in
            guard let self, self.callbackGeneration == generation else { return }
            self.handleConnectionState(false, error: reason)
        }
        disconnectGraceTimer = timer
        timer.resume()
    }

    func setVideoRendererState(sink: String, pipelineMode: String) {
        statsLock.withLock { latestStats.videoSink = sink; latestStats.videoPipelineMode = pipelineMode }
    }

    func setVideoRenderDiagnostics(pixelFormat: String, renderMode: String, frameSource: String, renderPath: String, fallback: String, enhancementConfiguredTier: String, enhancementActiveTier: String, enhancementFallbackReason: String, enhancementSourceResolution: String, enhancementDrawableResolution: String, enhancementDiagnostics: String, enhancementFrameTimeMs: Double, enhancementDroppedFrames: UInt64) {
        statsLock.withLock {
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
        }
    }

    func handleStatsReport(_ report: [String: Any]) {
        statsLock.withLock {
            latestStats.available = bool(report["available"])
            latestStats.latencyMs = double(report["latencyMs"], fallback: latestStats.latencyMs)
            latestStats.jitterMs = double(report["jitterMs"], fallback: latestStats.jitterMs)
            latestStats.inboundBitrateMbps = double(report["inboundBitrateMbps"], fallback: latestStats.inboundBitrateMbps)
            latestStats.packetLossPercent = double(report["packetLossPercent"], fallback: latestStats.packetLossPercent)
            latestStats.decodeTimeMs = double(report["decodeTimeMs"], fallback: latestStats.decodeTimeMs)
            latestStats.renderFps = double(report["renderFps"], fallback: latestStats.renderFps)
            latestStats.framesReceived = uint64(report["framesReceived"])
            latestStats.framesDropped = uint64(report["framesDropped"])
            latestStats.packetsLost = int64(report["packetsLost"])
            latestStats.videoDecoder = string(report["videoDecoder"]).isEmpty ? latestStats.videoDecoder : string(report["videoDecoder"])
            latestStats.videoSink = string(report["videoSink"]).isEmpty ? latestStats.videoSink : string(report["videoSink"])
            latestStats.videoPipelineMode = string(report["videoPipelineMode"]).isEmpty ? latestStats.videoPipelineMode : string(report["videoPipelineMode"])
        }
        updateAdaptiveBitrate(report)
    }

    private func resetStats(sessionInfo: [String: Any], settings: [String: Any]) {
        statsLock.withLock {
            latestStats = OPNStreamStatsState()
            latestStats.gpuType = string(sessionInfo["gpuType"])
            latestStats.zone = string(sessionInfo["zone"])
            latestStats.resolution = string(settings["resolution"])
            latestStats.codec = string(settings["codec"])
            latestStats.fps = int(settings["fps"], fallback: 60)
            latestStats.videoDecoder = "libwebrtc"
            latestStats.videoSink = "OPNMetalVideoView"
            latestStats.videoPipelineMode = "libwebrtc Metal display"
        }
        previousStatsTimestampMs = 0
        previousBytesReceived = 0
        previousPacketsReceived = 0
        previousFramesDecoded = 0
        previousPacketsLost = 0
    }

    private func updateAdaptiveBitrate(_ report: [String: Any]) {
        let timestampMs = uint64(report["timestampMs"])
        guard timestampMs > 0 else { return }
        let bytesReceived = uint64(report["bytesReceived"])
        let packetsReceived = uint64(report["packetsReceived"])
        let framesDecoded = uint64(report["framesDecoded"])
        let packetsLost = int64(report["packetsLost"])
        guard previousStatsTimestampMs > 0 else {
            previousStatsTimestampMs = timestampMs
            previousBytesReceived = bytesReceived
            previousPacketsReceived = packetsReceived
            previousFramesDecoded = framesDecoded
            previousPacketsLost = packetsLost
            return
        }
        let dtMs = max(1, timestampMs - previousStatsTimestampMs)
        let lostDelta = max(0, packetsLost - previousPacketsLost)
        let packetDelta = max(0, Int64(packetsReceived >= previousPacketsReceived ? packetsReceived - previousPacketsReceived : 0))
        let lossPercent = packetDelta + lostDelta > 0 ? Double(lostDelta) * 100.0 / Double(packetDelta + lostDelta) : 0
        let byteDelta = bytesReceived >= previousBytesReceived ? bytesReceived - previousBytesReceived : 0
        let bitrateMbps = Double(byteDelta) * 8.0 / Double(dtMs) / 1000.0
        let framesDelta = framesDecoded >= previousFramesDecoded ? framesDecoded - previousFramesDecoded : 0
        let fps = Double(framesDelta) * 1000.0 / Double(dtMs)
        statsLock.withLock {
            latestStats.inboundBitrateMbps = bitrateMbps
            latestStats.packetLossPercent = lossPercent
            if fps > 0 { latestStats.fps = Int(fps.rounded()) }
        }
        previousStatsTimestampMs = timestampMs
        previousBytesReceived = bytesReceived
        previousPacketsReceived = packetsReceived
        previousFramesDecoded = framesDecoded
        previousPacketsLost = packetsLost
        guard configuredMaxBitrateMbps > 0, timestampMs - lastAdaptiveBitrateChangeMs > 4000 else { return }
        if lossPercent > 3.0 || fps < Double(max(15, targetFps / 2)) {
            adaptiveCongestionScore += 1
            adaptiveRecoveryScore = 0
        } else {
            adaptiveRecoveryScore += 1
            adaptiveCongestionScore = 0
        }
        if adaptiveCongestionScore >= 2, adaptiveBitrateMbps > minAdaptiveBitrateMbps {
            adaptiveBitrateMbps = max(minAdaptiveBitrateMbps, adaptiveBitrateMbps * 85 / 100)
            applyRuntimeBitrateLimit(adaptiveBitrateMbps, reason: "adaptive congestion")
            lastAdaptiveBitrateChangeMs = timestampMs
            adaptiveCongestionScore = 0
        } else if adaptiveRecoveryScore >= 5, adaptiveBitrateMbps < configuredMaxBitrateMbps {
            adaptiveBitrateMbps = min(configuredMaxBitrateMbps, adaptiveBitrateMbps * 110 / 100 + 1)
            applyRuntimeBitrateLimit(adaptiveBitrateMbps, reason: "adaptive recovery")
            lastAdaptiveBitrateChangeMs = timestampMs
            adaptiveRecoveryScore = 0
        }
    }

    private func applyRuntimeBitrateLimit(_ mbps: Int, reason: String) {
        statsController.applyRuntimeBitrateLimit(mbps: mbps, reason: reason, sessionImpl: impl)
    }

    private func prepareMicrophoneIfNeeded(impl: OPNLibWebRTCSessionImpl, factory: RTCPeerConnectionFactory) {
        guard string(settings["microphoneMode"]) != "disabled", impl.localMicrophoneTrack == nil else { return }
        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        audioSource.volume = microphoneVolume
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "opennow-microphone")
        audioTrack.isEnabled = microphoneEnabled
        if attachMicrophoneTrack(impl: impl, audioTrack: audioTrack) {
            impl.localMicrophoneTrack = audioTrack
            audioController.startMicrophoneLevelPolling(sessionImpl: impl, statsQueue: statsQueue)
        } else {
            NSLog("[LibWebRTC] failed to attach local microphone track")
        }
    }

    private func attachMicrophoneTrack(impl: OPNLibWebRTCSessionImpl, audioTrack: RTCAudioTrack) -> Bool {
        guard let peerConnection = impl.peerConnection else { return false }
        if let transceiver = peerConnection.transceivers.first(where: { $0.mediaType == .audio }) {
            var target = transceiver.direction
            if transceiver.direction == .recvOnly { target = .sendRecv }
            else if transceiver.direction == .inactive { target = .sendOnly }
            if target != transceiver.direction {
                var directionError: NSError?
                transceiver.setDirection(target, error: &directionError)
                if let directionError { NSLog("[LibWebRTC] failed to set microphone transceiver direction: %@", directionError.localizedDescription) }
            }
            transceiver.sender.track = audioTrack
            transceiver.sender.streamIds = ["mic"]
            impl.localMicrophoneSender = transceiver.sender
            return true
        }
        guard let sender = peerConnection.add(audioTrack, streamIds: ["mic"]) else { return false }
        impl.localMicrophoneSender = sender
        return true
    }

    private func iceServers(from sessionInfo: [String: Any]) -> [RTCIceServer] {
        array(sessionInfo["iceServers"]).compactMap { item in
            guard let dictionary = item as? [String: Any] else { return nil }
            let urls = stringArray(dictionary["urls"])
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: emptyNil(string(dictionary["username"])), credential: emptyNil(string(dictionary["credential"])))
        }
    }

}

private struct OPNStreamStatsState {
    var available = false
    var latencyMs = -1.0
    var jitterMs = -1.0
    var inboundBitrateMbps = -1.0
    var packetLossPercent = -1.0
    var decodeTimeMs = -1.0
    var renderFps = -1.0
    var bytesReceived: UInt64 = 0
    var packetsReceived: UInt64 = 0
    var packetsLost: Int64 = 0
    var framesReceived: UInt64 = 0
    var framesDecoded: UInt64 = 0
    var framesDropped: UInt64 = 0
    var timestampMs: UInt64 = 0
    var gpuType = ""
    var zone = ""
    var resolution = ""
    var codec = ""
    var videoDecoder = "libwebrtc"
    var videoSink = "OPNMetalVideoView"
    var videoPipelineMode = "libwebrtc Metal display"
    var videoPixelFormat = "pending"
    var videoRenderMode = "pending"
    var videoFrameSource = "pending"
    var videoRenderPath = "pending"
    var videoRendererFallback = ""
    var videoEnhancementConfiguredTier = "pending"
    var videoEnhancementActiveTier = "pending"
    var videoEnhancementFallbackReason = ""
    var videoEnhancementSourceResolution = "pending"
    var videoEnhancementDrawableResolution = "pending"
    var videoEnhancementDiagnostics = ""
    var videoEnhancementFrameTimeMs = -1.0
    var videoEnhancementDroppedFrames: UInt64 = 0
    var fps = 0
}

private func buildNvstSdp(settings: [String: Any], credentials: OPNIceCredentials) -> String {
    let resolution = string(settings["resolution"])
    let parts = resolution.split(separator: "x").compactMap { Int($0) }
    let width = parts.first ?? 1920
    let height = parts.count > 1 ? parts[1] : 1080
    let fps = int(settings["fps"], fallback: 60)
    let maxBitrateKbps = max(1000, int(settings["maxBitrateMbps"], fallback: 50) * 1000)
    let minBitrateKbps = max(5000, maxBitrateKbps * 35 / 100)
    let initialBitrateKbps = max(minBitrateKbps, maxBitrateKbps * 70 / 100)
    let bitDepth = string(settings["colorQuality"]).hasPrefix("10bit") ? 10 : 8
    let codec = normalizedCodec(string(settings["codec"]))
    let prefilterMode = max(0, min(int(settings["prefilterMode"]), 2))
    let prefilterSharpness = max(0, min(int(settings["prefilterSharpness"]), 10))
    let prefilterDenoise = max(0, min(int(settings["prefilterDenoise"]), 10))
    let prefilterModel = max(0, int(settings["prefilterModel"]))
    let isAv1 = codec == "AV1"
    let isHighFps = fps >= 90
    let is120Fps = fps == 120
    let is240Fps = fps >= 240
    var lines = [
        "v=0",
        "o=SdpTest test_id_13 14 IN IPv4 127.0.0.1",
        "s=-",
        "t=0 0",
        "a=general.icePassword:\(credentials.pwd)",
        "a=general.iceUserNameFragment:\(credentials.ufrag)",
        "a=general.dtlsFingerprint:\(credentials.fingerprint)",
        "m=video 0 RTP/AVP",
        "a=msid:fbc-video-0",
        "a=vqos.fec.rateDropWindow:10",
        "a=vqos.fec.minRequiredFecPackets:2",
        "a=vqos.fec.repairMinPercent:5",
        "a=vqos.fec.repairPercent:5",
        "a=vqos.fec.repairMaxPercent:35",
        "a=vqos.dynamicStreamingMode:0",
        "a=vqos.drc.enable:0",
        "a=vqos.dfc.enable:0",
        "a=vqos.dfc.adjustResAndFps:0",
        "a=video.dx9EnableNv12:1",
        "a=video.dx9EnableHdr:1",
        "a=vqos.qpg.enable:1",
        "a=vqos.resControl.qp.qpg.featureSetting:7",
        "a=bwe.useOwdCongestionControl:1",
        "a=video.enableRtpNack:1",
        "a=vqos.bw.txRxLag.minFeedbackTxDeltaMs:200",
        "a=vqos.drc.bitrateIirFilterFactor:18",
        "a=video.packetSize:1140",
        "a=packetPacing.minNumPacketsPerGroup:15",
    ]
    if isHighFps {
        lines.append(contentsOf: [
            "a=bwe.iirFilterFactor:8",
            "a=video.encoderFeatureSetting:47",
            "a=video.encoderPreset:6",
            "a=vqos.resControl.cpmRtc.badNwSkipFramesCount:600",
            "a=vqos.resControl.cpmRtc.decodeTimeThresholdMs:9",
            "a=video.fbcDynamicFpsGrabTimeoutMs:\(is120Fps ? 6 : 18)",
            "a=vqos.resControl.cpmRtc.serverResolutionUpdateCoolDownCount:\(is120Fps ? 6000 : 12000)",
        ])
    }
    if is240Fps {
        lines.append(contentsOf: [
            "a=video.enableNextCaptureMode:1",
            "a=vqos.maxStreamFpsEstimate:240",
            "a=video.videoSplitEncodeStripsPerFrame:3",
            "a=video.updateSplitEncodeStateDynamically:1",
        ])
    }
    lines.append(contentsOf: [
        "a=vqos.adjustStreamingFpsDuringOutOfFocus:1",
        "a=vqos.resControl.cpmRtc.ignoreOutOfFocusWindowState:1",
        "a=vqos.resControl.perfHistory.rtcIgnoreOutOfFocusWindowState:1",
        "a=vqos.resControl.cpmRtc.featureMask:0",
        "a=vqos.resControl.cpmRtc.enable:0",
        "a=vqos.resControl.cpmRtc.minResolutionPercent:100",
        "a=vqos.resControl.cpmRtc.resolutionChangeHoldonMs:999999",
        "a=packetPacing.numGroups:\(is120Fps ? 3 : 5)",
        "a=packetPacing.maxDelayUs:1000",
        "a=packetPacing.minNumPacketsFrame:10",
        "a=video.rtpNackQueueLength:1024",
        "a=video.rtpNackQueueMaxPackets:512",
        "a=video.rtpNackMaxPacketCount:25",
        "a=vqos.drc.qpMaxResThresholdAdj:4",
        "a=vqos.grc.qpMaxResThresholdAdj:4",
        "a=vqos.drc.iirFilterFactor:100",
    ])
    if isAv1 {
        lines.append(contentsOf: [
            "a=vqos.drc.minQpHeadroom:20",
            "a=vqos.drc.lowerQpThreshold:100",
            "a=vqos.drc.upperQpThreshold:200",
            "a=vqos.drc.minAdaptiveQpThreshold:180",
            "a=vqos.drc.qpCodecThresholdAdj:0",
            "a=vqos.drc.qpMaxResThresholdAdj:20",
            "a=vqos.dfc.minQpHeadroom:20",
            "a=vqos.dfc.qpLowerLimit:100",
            "a=vqos.dfc.qpMaxUpperLimit:200",
            "a=vqos.dfc.qpMinUpperLimit:180",
            "a=vqos.dfc.qpMaxResThresholdAdj:20",
            "a=vqos.dfc.qpCodecThresholdAdj:0",
            "a=vqos.grc.minQpHeadroom:20",
            "a=vqos.grc.lowerQpThreshold:100",
            "a=vqos.grc.upperQpThreshold:200",
            "a=vqos.grc.minAdaptiveQpThreshold:180",
            "a=vqos.grc.qpMaxResThresholdAdj:20",
            "a=vqos.grc.qpCodecThresholdAdj:0",
            "a=video.minQp:25",
            "a=video.enableAv1RcPrecisionFactor:1",
        ])
    }
    lines.append(contentsOf: [
        "a=video.clientViewportWd:\(width)",
        "a=video.clientViewportHt:\(height)",
        "a=video.maxFPS:\(fps)",
        "a=video.initialBitrateKbps:\(initialBitrateKbps)",
        "a=video.initialPeakBitrateKbps:\(maxBitrateKbps)",
        "a=vqos.bw.maximumBitrateKbps:\(maxBitrateKbps)",
        "a=vqos.bw.minimumBitrateKbps:\(minBitrateKbps)",
        "a=vqos.bw.peakBitrateKbps:\(maxBitrateKbps)",
        "a=vqos.bw.serverPeakBitrateKbps:\(maxBitrateKbps)",
        "a=vqos.bw.enableBandwidthEstimation:1",
        "a=vqos.bw.disableBitrateLimit:0",
        "a=vqos.grc.maximumBitrateKbps:\(maxBitrateKbps)",
        "a=vqos.grc.enable:0",
        "a=video.maxNumReferenceFrames:4",
        "a=video.mapRtpTimestampsToFrames:1",
        "a=video.encoderCscMode:3",
        "a=video.dynamicRangeMode:0",
        "a=video.bitDepth:\(bitDepth)",
        "a=video.scalingFeature1:\(isAv1 ? 1 : 0)",
        "a=video.prefilterParams.prefilterMode:\(prefilterMode)",
        "a=video.prefilterParams.prefilterModel:\(prefilterModel)",
        "a=video.prefilterParams.sharpnessLevel:\(prefilterSharpness)",
        "a=video.prefilterParams.denoiseLevel:\(prefilterDenoise)",
        "m=audio 0 RTP/AVP",
        "a=msid:audio",
        "m=mic 0 RTP/AVP",
        "a=msid:mic",
        "a=rtpmap:0 PCMU/8000",
        "m=application 0 RTP/AVP",
        "a=msid:input_1",
        "a=ri.partialReliableThresholdMs:5",
        "a=ri.hidDeviceMask:4294967295",
        "a=ri.enablePartiallyReliableTransferGamepad:15",
        "a=ri.enablePartiallyReliableTransferHid:4294967295",
        "",
    ])
    return lines.joined(separator: "\n") + "\n"
}

private struct OPNIceCredentials { var ufrag = ""; var pwd = ""; var fingerprint = "" }

private func extractIceCredentials(from sdp: String) -> OPNIceCredentials {
    var credentials = OPNIceCredentials()
    for line in sdp.components(separatedBy: .newlines) {
        if line.hasPrefix("a=ice-ufrag:") { credentials.ufrag = String(line.dropFirst("a=ice-ufrag:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if line.hasPrefix("a=ice-pwd:") { credentials.pwd = String(line.dropFirst("a=ice-pwd:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if line.hasPrefix("a=fingerprint:") { credentials.fingerprint = String(line.dropFirst("a=fingerprint:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    return credentials
}

private func extractIceUfrag(from sdp: String) -> String { extractIceCredentials(from: sdp).ufrag }

private func rewriteH265OfferForReceiver(_ sdp: String, maxMainLevelId: Int, maxMain10LevelId: Int, supportsHighTier: Bool) -> String {
    let h265Payloads = videoPayloads(forCodec: "H265", in: sdp)
    guard !h265Payloads.isEmpty else { return sdp }
    var lines = sdpLines(sdp)
    var changed = false
    for index in lines.indices where lines[index].hasPrefix("a=fmtp:") {
        guard let payload = payloadType(lines[index], prefix: "a=fmtp:"), h265Payloads.contains(payload) else { continue }
        var parameters = fmtpParameters(fmtpText(lines[index]))
        let profileId = Int(parameterValue(parameters, "profile-id")) ?? 1
        let maxLevel = profileId == 2 ? maxMain10LevelId : maxMainLevelId
        var lineChanged = false
        if !supportsHighTier, parameterValue(parameters, "tier-flag") == "1" {
            parameters = setParameter(parameters, key: "tier-flag", value: "0")
            lineChanged = true
        }
        let offeredLevel = Int(parameterValue(parameters, "level-id")) ?? -1
        if maxLevel > 0, offeredLevel > maxLevel {
            parameters = setParameter(parameters, key: "level-id", value: String(maxLevel))
            lineChanged = true
        }
        guard lineChanged else { continue }
        lines[index] = "a=fmtp:\(payload) " + parameters.map { $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }.joined(separator: ";")
        changed = true
    }
    return changed ? joinSdpLinesLike(lines, original: sdp) : sdp
}

private func preferCodecInOffer(_ sdp: String, normalizedCodec: String) -> String {
    let preferredPayloads = videoPayloads(forCodec: normalizedCodec, in: sdp)
    guard !preferredPayloads.isEmpty else { return sdp }
    let rtxApt = rtxAptByPayload(in: sdp)
    let rtxPayloads = Set(rtxApt.compactMap { preferredPayloads.contains($0.value) ? $0.key : nil })
    let keptPayloads = preferredPayloads.union(rtxPayloads)
    var lines = sdpLines(sdp)
    var inVideo = false
    for index in lines.indices {
        let line = lines[index]
        if line.hasPrefix("m=video") {
            let parts = line.split(separator: " ").map(String.init)
            if parts.count > 3 {
                lines[index] = Array(parts.prefix(3) + keptPayloads.sorted().map(String.init)).joined(separator: " ")
            }
            inVideo = true
            continue
        }
        if line.hasPrefix("m=") { inVideo = false; continue }
        guard inVideo else { continue }
        if let payload = payloadType(line, prefix: "a=rtpmap:"), !keptPayloads.contains(payload) { lines[index] = "" }
        else if let payload = payloadType(line, prefix: "a=fmtp:"), !keptPayloads.contains(payload) { lines[index] = "" }
        else if let payload = payloadType(line, prefix: "a=rtcp-fb:"), !keptPayloads.contains(payload) { lines[index] = "" }
    }
    return joinSdpLinesLike(lines.filter { !$0.isEmpty }, original: sdp)
}

private func rtxAptByPayload(in sdp: String) -> [Int: Int] {
    var result: [Int: Int] = [:]
    for (payload, text) in videoFmtpByPayload(in: sdp) {
        for parameter in fmtpParameters(text) where parameter.key == "apt" {
            if let apt = Int(parameter.value) { result[payload] = apt }
        }
    }
    return result
}

private func mungeAnswerSdp(_ sdp: String, maxBitrateKbps: Int) -> String {
    let lines = sdpLines(sdp)
    var result: [String] = []
    for index in lines.indices {
        var line = lines[index]
        if line.hasPrefix("a=fmtp:"), line.contains("minptime="), !line.contains("stereo=1") { line += ";stereo=1" }
        result.append(line)
        if line.hasPrefix("m=video") || line.hasPrefix("m=audio") {
            let nextHasBandwidth = index + 1 < lines.count && lines[index + 1].hasPrefix("b=")
            if !nextHasBandwidth { result.append("b=AS:\(line.hasPrefix("m=video") ? max(1000, maxBitrateKbps) : 128)") }
        }
    }
    return joinSdpLinesLike(result, original: sdp)
}

private func alignH265AnswerFmtpToOffer(_ answerSdp: String, offerSdp: String) -> String {
    let answerPayloads = videoPayloads(forCodec: "H265", in: answerSdp)
    guard !answerPayloads.isEmpty else { return answerSdp }
    let offerPayloads = videoPayloads(forCodec: "H265", in: offerSdp)
    let offerFmtp = videoFmtpByPayload(in: offerSdp)
    var lines = sdpLines(answerSdp)
    var inVideo = false
    var changed = false
    for index in lines.indices {
        let line = lines[index]
        if line.hasPrefix("m=") {
            inVideo = line.hasPrefix("m=video")
            continue
        }
        guard inVideo, line.hasPrefix("a=fmtp:"), let payload = payloadType(line, prefix: "a=fmtp:"), answerPayloads.contains(payload), offerPayloads.contains(payload), let offerParameters = offerFmtp[payload] else { continue }
        var answerParameters = fmtpParameters(fmtpText(line))
        let offered = fmtpParameters(offerParameters)
        var lineChanged = false
        if parameterValue(answerParameters, "profile-id").isEmpty, let value = parameterValue(offered, "profile-id").nilIfEmpty { answerParameters = setParameter(answerParameters, key: "profile-id", value: value); lineChanged = true }
        if parameterValue(answerParameters, "tier-flag").isEmpty, let value = parameterValue(offered, "tier-flag").nilIfEmpty { answerParameters = setParameter(answerParameters, key: "tier-flag", value: value); lineChanged = true }
        let answerLevel = Int(parameterValue(answerParameters, "level-id")) ?? -1
        let offerLevelText = parameterValue(offered, "level-id")
        let offerLevel = Int(offerLevelText) ?? -1
        if !offerLevelText.isEmpty, parameterValue(answerParameters, "level-id").isEmpty || (answerLevel >= 0 && offerLevel > answerLevel) {
            answerParameters = setParameter(answerParameters, key: "level-id", value: offerLevelText)
            lineChanged = true
        }
        guard lineChanged else { continue }
        lines[index] = "a=fmtp:\(payload) " + answerParameters.map { $0.value.isEmpty ? $0.key : "\($0.key)=\($0.value)" }.joined(separator: ";")
        changed = true
    }
    return changed ? joinSdpLinesLike(lines, original: answerSdp) : answerSdp
}

private func videoPayloads(forCodec codec: String, in sdp: String) -> Set<Int> {
    var payloads = Set<Int>()
    var inVideo = false
    for line in sdpLines(sdp) {
        if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video"); continue }
        guard inVideo, line.hasPrefix("a=rtpmap:"), let payload = payloadType(line, prefix: "a=rtpmap:") else { continue }
        let upper = line.uppercased()
        if codec == "H265", upper.contains(" H265/") || upper.contains(" HEVC/") { payloads.insert(payload) }
    }
    return payloads
}

private func videoFmtpByPayload(in sdp: String) -> [Int: String] {
    var result: [Int: String] = [:]
    var inVideo = false
    for line in sdpLines(sdp) {
        if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video"); continue }
        guard inVideo, line.hasPrefix("a=fmtp:"), let payload = payloadType(line, prefix: "a=fmtp:") else { continue }
        result[payload] = fmtpText(line)
    }
    return result
}

private func payloadType(_ line: String, prefix: String) -> Int? {
    guard line.hasPrefix(prefix) else { return nil }
    let text = String(line.dropFirst(prefix.count))
    let token = text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" }).first.map(String.init) ?? ""
    return Int(token)
}

private func fmtpText(_ line: String) -> String {
    guard let range = line.rangeOfCharacter(from: .whitespaces) else { return "" }
    return String(line[range.upperBound...])
}

private func fmtpParameters(_ text: String) -> [(key: String, value: String)] {
    text.split(separator: ";").compactMap { item in
        let token = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let parts = token.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        return (key: parts[0].lowercased(), value: parts.count > 1 ? parts[1] : "")
    }
}

private func parameterValue(_ parameters: [(key: String, value: String)], _ key: String) -> String {
    parameters.first { $0.key == key.lowercased() }?.value ?? ""
}

private func setParameter(_ parameters: [(key: String, value: String)], key: String, value: String) -> [(key: String, value: String)] {
    var result = parameters
    if let index = result.firstIndex(where: { $0.key == key.lowercased() }) { result[index].value = value }
    else { result.append((key: key.lowercased(), value: value)) }
    return result
}

private func sdpLines(_ sdp: String) -> [String] {
    sdp.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
}

private func joinSdpLinesLike(_ lines: [String], original: String) -> String {
    let newline = original.contains("\r\n") ? "\r\n" : "\n"
    var text = lines.joined(separator: newline)
    if original.hasSuffix("\n"), !text.hasSuffix(newline) { text += newline }
    return text
}

private func videoSdpHasMediaCodec(_ sdp: String) -> Bool {
    var inVideo = false
    for line in sdp.components(separatedBy: .newlines) {
        if line.hasPrefix("m=video") {
            inVideo = true
            continue
        }
        if line.hasPrefix("m="), inVideo { break }
        guard inVideo, line.hasPrefix("a=rtpmap:") else { continue }
        let upper = line.uppercased()
        if upper.contains(" H264/") || upper.contains(" H265/") || upper.contains(" HEVC/") || upper.contains(" AV1/") || upper.contains(" VP8/") || upper.contains(" VP9/") {
            return true
        }
    }
    return false
}

private func logVideoSdpSummary(_ label: String, _ sdp: String) {
    let videoLines = sdp.components(separatedBy: .newlines).filter { $0.hasPrefix("m=video") || $0.hasPrefix("a=rtpmap:") }
    NSLog("[LibWebRTC] %@ lines=%d", label, videoLines.count)
}

private func normalizedCodec(_ codec: String) -> String {
    let upper = codec.uppercased()
    if upper == "HEVC" { return "H265" }
    if ["H264", "H265", "AV1"].contains(upper) { return upper }
    return ""
}

private func isSupportedCodecPreference(_ codec: String) -> Bool {
    codec == "H264" || codec == "H265" || codec == "AV1"
}

private func envFlagEnabled(_ name: String, defaultValue: Bool) -> Bool {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else { return defaultValue }
    let lower = value.lowercased()
    if ["0", "false", "no", "off"].contains(lower) { return false }
    if ["1", "true", "yes", "on"].contains(lower) { return true }
    return defaultValue
}

private struct OPNIceMediaTarget { var mid = "0"; var mLineIndex: Int32 = -1 }

private func extractVideoIceTarget(from sdp: String) -> OPNIceMediaTarget {
    var index: Int32 = -1
    var currentMid = "0"
    var inVideo = false
    for line in sdp.components(separatedBy: .newlines) {
        if line.hasPrefix("m=") { index += 1; inVideo = line.hasPrefix("m=video") }
        else if inVideo, line.hasPrefix("a=mid:") { currentMid = String(line.dropFirst("a=mid:".count)).trimmingCharacters(in: .whitespacesAndNewlines); return OPNIceMediaTarget(mid: currentMid, mLineIndex: index) }
    }
    return OPNIceMediaTarget(mid: currentMid, mLineIndex: index >= 0 ? index : 0)
}

private func extractPublicIp(_ hostOrIp: String) -> String {
    guard !hostOrIp.isEmpty else { return "" }
    if hostOrIp.allSatisfy({ $0.isNumber || $0 == "." }) { return hostOrIp }
    return hostOrIp.split(separator: ":").first.map(String.init) ?? hostOrIp
}

private func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func dictionary(_ value: NSDictionary) -> [String: Any] { value as? [String: Any] ?? [:] }
private func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
private func stringArray(_ value: Any?) -> [String] { if let value = value as? String { return value.isEmpty ? [] : [value] }; if let value = value as? [String] { return value }; return (value as? NSArray)?.compactMap { string($0) }.filter { !$0.isEmpty } ?? [] }
private func emptyNil(_ value: String) -> String? { value.isEmpty ? nil : value }
private func string(_ value: Any?) -> String { if let value = value as? String { return value }; if let value = value as? NSString { return value as String }; if let value = value as? NSNumber { return value.stringValue }; return "" }
private func int(_ value: Any?, fallback: Int = 0) -> Int { if let value = value as? Int { return value }; if let value = value as? NSNumber { return value.intValue }; if let value = value as? String { return Int(value) ?? fallback }; return fallback }
private func int64(_ value: Any?) -> Int64 { if let value = value as? Int64 { return value }; if let value = value as? NSNumber { return value.int64Value }; if let value = value as? String { return Int64(value) ?? 0 }; return 0 }
private func uint64(_ value: Any?) -> UInt64 { if let value = value as? UInt64 { return value }; if let value = value as? NSNumber { return value.uint64Value }; if let value = value as? String { return UInt64(value) ?? 0 }; return 0 }
private func double(_ value: Any?, fallback: Double = 0) -> Double { if let value = value as? Double { return value }; if let value = value as? NSNumber { return value.doubleValue }; if let value = value as? String { return Double(value) ?? fallback }; return fallback }
private func bool(_ value: Any?) -> Bool { if let value = value as? Bool { return value }; if let value = value as? NSNumber { return value.boolValue }; if let value = value as? String { return (value as NSString).boolValue }; return false }

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
