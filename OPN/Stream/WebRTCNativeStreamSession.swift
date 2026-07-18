import AppKit
import CoreVideo
import Darwin
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
    private let remoteIceLock = NSLock()

    private var impl: OPNLibWebRTCSessionImpl?
    private var callbackGeneration: UInt64 = 0
    private var disconnectGraceTimer: DispatchSourceTimer?
    private var nativeWindow: UnsafeMutableRawPointer?
    private var settings: [String: Any] = [:]
    private var remoteCandidateOverrideIp = ""
    private var remoteCandidateOverridePort = 0
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
    private var localEnhancementMode = 0
    private var localEnhancementSharpness = 10
    private var localEnhancementDenoise = 0
    private var localEnhancementTargetHeight = 2160
    private var enhancedVideoFrameCaptureEnabled = false
    private var onAnswer: ((String, String) -> Void)?
    private var onIceCandidate: (([String: Any]) -> Void)?
    private var onState: ((Bool, String) -> Void)?
    private var pendingRemoteIcePayloads: [[AnyHashable: Any]] = []
    private var isRemoteDescriptionReady = false
    var onVideoFrame: ((UnsafeMutableRawPointer?) -> Void)?
    var onEnhancedVideoFrame: ((UnsafeMutableRawPointer?) -> Void)?
    var onGameAudioFrame: ((UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
    var onMicrophoneAudioFrame: ((UnsafeRawPointer?, UInt32, Double, UInt32) -> Void)?
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
        NVSTSessionDescriptionBuilder.iceUsernameFragment(from: offerSdp)
    }

    static func sdpMediaSummary(_ sdp: String, label: String) -> String {
        buildSdpMediaSummary(sdp, label: label)
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
        configuredMaxBitrateMbps = max(1, int(settings["maxBitrateMbps"], fallback: 50))
        adaptiveBitrateMbps = configuredMaxBitrateMbps
        minAdaptiveBitrateMbps = min(configuredMaxBitrateMbps, max(8, configuredMaxBitrateMbps * 35 / 100))
        adaptiveCongestionScore = 0
        adaptiveRecoveryScore = 0
        lastAdaptiveBitrateChangeMs = 0
        microphoneEnabled = string(settings["microphoneMode"]) == "voice-activity"
        gameVolume = clampedDouble(settings["gameVolume"], fallback: 1, minimum: 0, maximum: 1)
        microphoneVolume = clampedDouble(settings["microphoneVolume"], fallback: 1, minimum: 0, maximum: 1)
        setLocalVideoEnhancement(
            mode: int(settings["upscalingMode"]),
            sharpness: int(settings["upscalingSharpness"], fallback: 10),
            denoise: int(settings["upscalingDenoise"]),
            targetHeight: int(settings["upscalingTargetHeight"], fallback: 2160)
        )
        resetStats(sessionInfo: sessionInfo, settings: settings)

        guard Self.isAvailable() else {
            handleConnectionState(false, error: "WebRTC.framework unavailable")
            return
        }

        let impl = OPNLibWebRTCSessionImpl(owner: self)
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let audioDevice = OPNCoreAudioRTCDevice(owner: self)
        impl.audioDevice = audioDevice
        impl.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory, audioDevice: audioDevice)
        if impl.factory == nil {
            WebRTCMediaTelemetry.capture("webrtc.native.factory.audio_device_fallback", level: .warning, message: "CoreAudio RTC device factory failed; using default WebRTC audio device.")
            impl.audioDevice = nil
            impl.factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory)
        } else {
            WebRTCMediaTelemetry.capture("webrtc.native.factory.audio_device", level: .debug, message: "CoreAudio RTC audio device enabled.")
        }
        guard let factory = impl.factory else {
            handleConnectionState(false, error: "failed to create libwebrtc factory")
            return
        }

        let remoteNVSTSdp = string(sessionInfo["nvstSdp"])
        let remoteNVSTServerOverrides = string(sessionInfo["nvstServerOverrides"])
        let nvstProfile = NVSTTransportProfile(sdp: remoteNVSTSdp, serverOverrides: remoteNVSTServerOverrides)
        let configuration = RTCConfiguration()
        let configuredIceServers = iceServers(from: sessionInfo)
        let nvstIceServers = configuredIceServers.isEmpty ? iceServers(from: nvstProfile.turnServers) : []
        configuration.iceServers = configuredIceServers
        if configuration.iceServers.isEmpty {
            configuration.iceServers = nvstIceServers
        }
        configuration.iceTransportPolicy = nvstProfile.iceTransportPolicy == .relay ? .relay : .all
        let iceSource = configuredIceServers.isEmpty ? (nvstIceServers.isEmpty ? "manualDirect" : "nvstSdp") : "sessionInfo"
        WebRTCMediaTelemetry.capture("webrtc.native.ice_servers", level: .debug, message: "Configured ICE servers.", attributes: ["count": String(configuration.iceServers.count), "source": iceSource, "policy": nvstProfile.iceTransportPolicy == .relay ? "relay" : "all"])
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .disabled
        configuration.continualGatheringPolicy = envFlagEnabled("OPN_ENABLE_WEBRTC_CONTINUAL_ICE_GATHERING", defaultValue: false) ? .gatherContinually : .gatherOnce
        configuration.iceConnectionReceivingTimeout = 30_000

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

        let manualIceMedia = dictionary(sessionInfo["mediaConnectionInfo"])
        let manualIceIp = extractPublicIp(string(manualIceMedia["ip"]).isEmpty ? string(sessionInfo["serverIp"]) : string(manualIceMedia["ip"]))
        let manualIcePort = int(manualIceMedia["port"], fallback: 47998)
        let directIcePort = 47998
        remoteCandidateOverrideIp = manualIceIp
        remoteCandidateOverridePort = manualIcePort

        var processedOfferSdp = offerSdp
        let requestedCodec = normalizedCodec(string(settings["codec"]))
        let requestedCodecSupported = OPNWebRTCCodecSupport.supportsCodec(factory: factory, normalizedCodec: requestedCodec)
        OPNLogCapture.appendEvent("[LibWebRTC] Start settings resolution=\(string(settings["resolution"], fallback: "unknown")) fps=\(int(settings["fps"])) codec=\(requestedCodec.isEmpty ? "unknown" : requestedCodec) requestedCodecSupported=\(requestedCodecSupported ? "yes" : "no") bitrate=\(int(settings["maxBitrateMbps"]))Mbps h265Rewrite=\(envFlagEnabled("OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE", defaultValue: true) ? "on" : "off") codecFilter=\(envFlagEnabled("OPN_ENABLE_LIBWEBRTC_CODEC_FILTER", defaultValue: false) ? "on" : "off") answerMunge=\(envFlagEnabled("OPN_ENABLE_LIBWEBRTC_ANSWER_MUNGE", defaultValue: false) ? "on" : "off") receiverCapabilities=\(OPNWebRTCCodecSupport.receiverCapabilitiesSummary(factory: factory))")
        if requestedCodec == "H265", requestedCodecSupported, envFlagEnabled("OPN_ENABLE_LIBWEBRTC_H265_OFFER_REWRITE", defaultValue: true) {
            let support = OPNWebRTCCodecSupport.h265ReceiverSupport(factory: factory)
            processedOfferSdp = rewriteH265OfferForReceiver(processedOfferSdp, maxMainLevelId: int(support["maxMainLevelId"]), maxMain10LevelId: int(support["maxMain10LevelId"]), supportsHighTier: bool(support["supportsHighTier"]))
        }
        if isSupportedCodecPreference(requestedCodec), requestedCodecSupported, envFlagEnabled("OPN_ENABLE_LIBWEBRTC_CODEC_FILTER", defaultValue: false) {
            processedOfferSdp = preferCodecInOffer(processedOfferSdp, normalizedCodec: requestedCodec)
        } else if !requestedCodec.isEmpty, !requestedCodecSupported {
            WebRTCMediaTelemetry.capture("webrtc.native.codec.unsupported_offer", level: .warning, message: "Requested codec is not supported; retaining full offer.", attributes: ["codec": requestedCodec])
        }
        processedOfferSdp = rewriteEmbeddedIceCandidates(processedOfferSdp, ip: manualIceIp, port: manualIcePort)
        let remoteOfferSdp = processedOfferSdp
        let canRetryOriginalOffer = processedOfferSdp != offerSdp
        logVideoSdpSummary("offer-video", remoteOfferSdp)
        let shouldInjectDirectCandidates = configuration.iceServers.isEmpty

        @Sendable func handleRemoteDescriptionSet(impl: OPNLibWebRTCSessionImpl, peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
            self.prepareMicrophoneIfNeeded(impl: impl, factory: factory)
            let answerCodec = normalizedCodec(string(self.settings["codec"]))
            let codecPreferenceApplied: Bool
            if !answerCodec.isEmpty {
                if videoSdpContainsCodec(remoteOfferSdp, normalizedCodec: answerCodec) {
                    codecPreferenceApplied = OPNWebRTCCodecSupport.applyVideoCodecPreference(factory: factory, peerConnection: peerConnection, normalizedCodec: answerCodec)
                    if !codecPreferenceApplied {
                        WebRTCMediaTelemetry.capture("webrtc.native.codec.preference_unaccepted", level: .warning, message: "No video transceiver accepted codec preference before answer.", attributes: ["codec": answerCodec])
                    }
                } else {
                    WebRTCMediaTelemetry.capture("webrtc.native.codec.preference_skipped", level: .debug, message: "Skipping codec preference because the remote offer does not include it.", attributes: ["codec": answerCodec])
                    codecPreferenceApplied = false
                }
            } else {
                codecPreferenceApplied = false
            }

            @Sendable func createAndSendAnswer(retriedWithoutCodecPreference: Bool) {
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
                        if codecPreferenceApplied, !retriedWithoutCodecPreference, OPNWebRTCCodecSupport.resetVideoCodecPreferences(peerConnection: peerConnection) {
                            let message = "[LibWebRTC] createAnswer rejected video after codec preference; retrying with default codec preferences"
                            OPNLogCapture.appendEvent(message)
                            createAndSendAnswer(retriedWithoutCodecPreference: true)
                            return
                        }
                        OPNLogCapture.appendEvent("[LibWebRTC] createAnswer produced no video codec failureContext retriedWithoutCodecPreference=\(retriedWithoutCodecPreference ? "yes" : "no") codecPreferenceApplied=\(codecPreferenceApplied ? "yes" : "no") offer=\(buildSdpMediaSummary(remoteOfferSdp, label: "failure-offer")) answer=\(buildSdpMediaSummary(answerSdp, label: "failure-answer"))")
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
                        self.onAnswer?(answerSdp, NVSTSessionDescriptionBuilder.buildAnswerExtension(settings: self.settings, credentials: NVSTSessionDescriptionBuilder.iceCredentials(from: answerSdp), remoteNVSTSdp: remoteNVSTSdp, serverOverrides: remoteNVSTServerOverrides))
                    }
                }
            }

            createAndSendAnswer(retriedWithoutCodecPreference: false)
        }

        @Sendable func injectDirectCandidatesIfNeeded(offerSdp: String) {
            guard shouldInjectDirectCandidates, !manualIceIp.isEmpty else { return }
            let serverIceUfrag = Self.iceUfrag(fromOfferSdp: offerSdp)
            guard !serverIceUfrag.isEmpty else { return }
            self.injectManualIceCandidate(offerSdp: offerSdp, serverIceUfrag: serverIceUfrag, ip: manualIceIp, port: directIcePort)
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
                    self.markRemoteDescriptionReady()
                    injectDirectCandidatesIfNeeded(offerSdp: offerSdp)
                    handleRemoteDescriptionSet(impl: impl, peerConnection: peerConnection, factory: factory)
                }
                return
            }
            guard let impl, let peerConnection = impl.peerConnection, let factory = impl.factory else { return }
            self.markRemoteDescriptionReady()
            injectDirectCandidatesIfNeeded(offerSdp: remoteOfferSdp)
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
                DispatchQueue.main.async { remoteVideoView?.removeFromSuperview() }
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
        if bool(payload["endOfCandidates"]) { return }
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

    private func markRemoteDescriptionReady() {
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
        let candidate = rewrittenRemoteCandidate(string(payload["candidate"]))
        guard !candidate.isEmpty else { return }
        let sdpMid = string(payload["sdpMid"])
        let sdpMLineIndex = Int32(int(payload["sdpMLineIndex"]))
        let rtcCandidate = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid.isEmpty ? nil : sdpMid)
        peerConnection.add(rtcCandidate) { error in
            if let error { WebRTCMediaTelemetry.capture("webrtc.native.remote_ice.add.error", level: .warning, message: "Failed to add remote ICE candidate.", attributes: ["error": error.localizedDescription]) }
        }
    }

    func injectManualIceCandidate(offerSdp: String, serverIceUfrag: String, ip: String, port: Int) {
        guard !ip.isEmpty else { return }
        let targets = extractIceTargets(from: offerSdp)
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
    func setLocalVideoEnhancement(mode: Int, sharpness: Int, denoise: Int, targetHeight: Int) { localEnhancementMode = mode; localEnhancementSharpness = sharpness; localEnhancementDenoise = denoise; localEnhancementTargetHeight = targetHeight }
    func sendUtf8Text(_ text: String) { inputController.sendUtf8Text(text, sessionImpl: impl) }
    func sendKey(keycode: UInt16, scancode: UInt16, modifiers: UInt16, down: Bool) { inputController.sendKey(keycode: keycode, scancode: scancode, modifiers: modifiers, down: down, sessionImpl: impl) }
    func sendMouseMove(dx: Int16, dy: Int16) { inputController.sendMouseMove(dx: dx, dy: dy, sessionImpl: impl) }
    func sendMouseButton(button: UInt8, down: Bool) { inputController.sendMouseButton(button: button, down: down, sessionImpl: impl) }
    func sendMouseWheel(delta: Int16) { inputController.sendMouseWheel(delta: delta, sessionImpl: impl) }
    func sendGamepadState(controllerId: UInt16, buttons: UInt16, leftTrigger: UInt8, rightTrigger: UInt8, leftStickX: Int16, leftStickY: Int16, rightStickX: Int16, rightStickY: Int16, connected: Bool, bitmap: UInt16, timestampUs: UInt64) {
        inputController.sendGamepadState(controllerId: controllerId, buttons: buttons, leftTrigger: leftTrigger, rightTrigger: rightTrigger, leftStickX: leftStickX, leftStickY: leftStickY, rightStickX: rightStickX, rightStickY: rightStickY, timestampUs: timestampUs, bitmap: bitmap, sessionImpl: impl)
    }

    func latestStatsSnapshot() -> OPNStreamStatsSnapshot {
        let stats = statsLock.withLock { latestStats }
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

    var targetFps: Int { int(settings["fps"], fallback: 60) }
    var gameVolumeLevel: Double { gameVolume }
    func localVideoEnhancement() -> (Int32, Int32, Int32, Int32) { (Int32(localEnhancementMode), Int32(localEnhancementSharpness), Int32(localEnhancementDenoise), Int32(localEnhancementTargetHeight)) }
    func wantsEnhancedVideoFrames() -> Bool { enhancedVideoFrameCaptureEnabled }
    func nativeWindowHandle() -> UnsafeMutableRawPointer? { nativeWindow }
    func isMicrophoneCaptureEnabled() -> Bool { microphoneEnabled && impl?.localMicrophoneTrack?.isEnabled == true }
    func handleVideoFrame(_ frame: UnsafeMutableRawPointer?) { onVideoFrame?(frame) }
    func handleEnhancedVideoFrame(_ pixelBuffer: CVPixelBuffer?) { if let pixelBuffer { onEnhancedVideoFrame?(Unmanaged.passUnretained(pixelBuffer).toOpaque()) } }
    func handleClipboardText(_ text: String) { onClipboardText?(text) }
    func handleCapturedMicrophoneLevel(_ level: Double) { handleMicrophoneLevel(level * microphoneVolume) }
    func handleMicrophoneLevel(_ level: Double) { onMicrophoneLevel?(level) }
    func handleGameAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) { onGameAudioFrame?(audioBufferList, frameCount, sampleRate, channels) }
    func handleMicrophoneAudioFrame(_ audioBufferList: UnsafeRawPointer?, frameCount: UInt32, sampleRate: Double, channels: UInt32) { onMicrophoneAudioFrame?(audioBufferList, frameCount, sampleRate, channels) }
    func refreshAudioDevices() { audioController.refreshAudioDevices(sessionImpl: impl) }

    func handleLocalIceCandidate(candidate: String, sdpMid: String, sdpMLineIndex: Int32) {
        guard !isTCPIceCandidate(candidate) else { return }
        onIceCandidate?(["candidate": candidate, "sdpMid": sdpMid, "sdpMLineIndex": Int(sdpMLineIndex), "usernameFragment": iceUsernameFragment(fromCandidate: candidate)])
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
        timer.schedule(deadline: .now() + .milliseconds(10000))
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

    func setVideoRenderDiagnostics(pixelFormat: String, renderMode: String, frameSource: String, renderPath: String, fallback: String, enhancementConfiguredTier: String, enhancementActiveTier: String, enhancementFallbackReason: String, enhancementSourceResolution: String, enhancementDrawableResolution: String, enhancementDiagnostics: String, enhancementFrameTimeMs: Double, enhancementDroppedFrames: UInt64, frameIntervalMs: Double, maxFrameIntervalMs: Double) {
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
            latestStats.videoFrameIntervalMs = frameIntervalMs
            latestStats.videoMaxFrameIntervalMs = maxFrameIntervalMs
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
            let decodedResolution = string(report["resolution"])
            if !decodedResolution.isEmpty {
                if latestStats.resolution.isEmpty { latestStats.resolution = decodedResolution }
                latestStats.videoEnhancementSourceResolution = decodedResolution
            }
            latestStats.codec = string(report["codec"]).isEmpty ? latestStats.codec : string(report["codec"])
            latestStats.videoDecoder = string(report["videoDecoder"]).isEmpty ? latestStats.videoDecoder : string(report["videoDecoder"])
            latestStats.videoSink = string(report["videoSink"]).isEmpty ? latestStats.videoSink : string(report["videoSink"])
            latestStats.videoPipelineMode = string(report["videoPipelineMode"]).isEmpty ? latestStats.videoPipelineMode : string(report["videoPipelineMode"])
        }
        updateAdaptiveBitrate(report)
    }

    private func resetStats(sessionInfo: [String: Any], settings: [String: Any]) {
        statsLock.withLock {
            latestStats = OPNStreamStatsState()
            latestStats.transport = string(sessionInfo["transport"], fallback: "WebRTC")
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
            if impl.audioDevice == nil {
                audioController.startMicrophoneLevelPolling(sessionImpl: impl, statsQueue: statsQueue)
            }
        } else {
            WebRTCMediaTelemetry.capture("webrtc.native.microphone.attach.error", level: .warning, message: "Failed to attach local microphone track.")
        }
    }

    private func attachMicrophoneTrack(impl: OPNLibWebRTCSessionImpl, audioTrack: RTCAudioTrack) -> Bool {
        guard let peerConnection = impl.peerConnection else { return false }
        if let transceiver = findMicrophoneTransceiver(peerConnection: peerConnection) {
            var target = transceiver.direction
            if transceiver.direction == .recvOnly { target = .sendRecv }
            else if transceiver.direction == .inactive { target = .sendOnly }
            if target != transceiver.direction {
                var directionError: NSError?
                transceiver.setDirection(target, error: &directionError)
                if let directionError { WebRTCMediaTelemetry.capture("webrtc.native.microphone.direction.error", level: .warning, message: "Failed to set microphone transceiver direction.", attributes: ["error": directionError.localizedDescription]) }
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

    private func findMicrophoneTransceiver(peerConnection: RTCPeerConnection) -> RTCRtpTransceiver? {
        var firstAvailableAudio: RTCRtpTransceiver?
        var firstSendableAudio: RTCRtpTransceiver?
        for transceiver in peerConnection.transceivers where transceiver.mediaType == .audio && !transceiver.isStopped {
            if transceiver.mid == "3" { return transceiver }
            if firstAvailableAudio == nil, transceiver.sender.track == nil { firstAvailableAudio = transceiver }
            if firstSendableAudio == nil, transceiver.direction == .sendRecv || transceiver.direction == .recvOnly || transceiver.direction == .inactive { firstSendableAudio = transceiver }
        }
        return firstAvailableAudio ?? firstSendableAudio
    }

    private func iceServers(from sessionInfo: [String: Any]) -> [RTCIceServer] {
        array(sessionInfo["iceServers"]).compactMap { item in
            guard let dictionary = item as? [String: Any] else { return nil }
            let urls = stringArray(dictionary["urls"])
            guard !urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: urls, username: emptyNil(string(dictionary["username"])), credential: emptyNil(string(dictionary["credential"])))
        }
    }

    private func iceServers(from turnServers: [NVSTTurnServer]) -> [RTCIceServer] {
        turnServers.compactMap { server in
            guard !server.urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: server.urls, username: emptyNil(server.username), credential: emptyNil(server.credential))
        }
    }

    private func rewrittenRemoteCandidate(_ candidate: String) -> String {
        rewriteIceCandidateLine(candidate, ip: remoteCandidateOverrideIp, port: remoteCandidateOverridePort)
    }

}

private struct OPNStreamStatsState {
    var available = false
    var transport = "WebRTC"
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
    var videoFrameIntervalMs = -1.0
    var videoMaxFrameIntervalMs = -1.0
    var fps = 0
}

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
        switch codec {
        case "H264":
            if upper.contains(" H264/") { payloads.insert(payload) }
        case "H265":
            if upper.contains(" H265/") || upper.contains(" HEVC/") { payloads.insert(payload) }
        case "AV1":
            if upper.contains(" AV1/") { payloads.insert(payload) }
        default:
            break
        }
    }
    return payloads
}

private func videoSdpContainsCodec(_ sdp: String, normalizedCodec: String) -> Bool {
    !videoPayloads(forCodec: normalizedCodec, in: sdp).isEmpty
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

func rewriteEmbeddedIceCandidates(_ sdp: String, ip: String, port: Int) -> String {
    guard !ip.isEmpty, port > 0 else { return sdp }
    let lines = sdpLines(sdp).map { line in
        if line.hasPrefix("a=candidate:") {
            return "a=" + rewriteIceCandidateLine(String(line.dropFirst(2)), ip: ip, port: port)
        }
        return line
    }
    return joinSdpLinesLike(lines, original: sdp)
}

func rewriteIceCandidateLine(_ candidate: String, ip: String, port: Int) -> String {
    guard !ip.isEmpty, port > 0 else { return candidate }
    let prefix = candidate.hasPrefix("a=") ? "a=" : ""
    let body = prefix.isEmpty ? candidate : String(candidate.dropFirst(2))
    var parts = body.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard parts.count > 5 else { return candidate }
    parts[4] = ip
    return prefix + parts.joined(separator: " ")
}

func iceUsernameFragment(fromCandidate candidate: String) -> String {
    let parts = candidate.split(separator: " ").map(String.init)
    guard let index = parts.firstIndex(of: "ufrag"), index + 1 < parts.count else { return "" }
    return parts[index + 1]
}

private func isTCPIceCandidate(_ candidate: String) -> Bool {
    let fields = candidate.lowercased().split(separator: " ").map(String.init)
    return fields.count > 2 && fields[2] == "tcp"
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
    let message = "[LibWebRTC] \(buildSdpMediaSummary(sdp, label: label))"
    OPNLogCapture.appendEvent(message)
}

private func buildSdpMediaSummary(_ sdp: String, label: String) -> String {
    var mediaLines: [String] = []
    var videoLines: [String] = []
    var inVideo = false
    for line in sdpLines(sdp) {
        if line.hasPrefix("m=") {
            mediaLines.append(line)
            inVideo = line.hasPrefix("m=video")
            if inVideo { videoLines.append(line) }
            continue
        }
        guard inVideo else { continue }
        if line.hasPrefix("a=mid:") || line == "a=sendrecv" || line == "a=sendonly" || line == "a=recvonly" || line == "a=inactive" || line.hasPrefix("a=rtpmap:") || line.hasPrefix("a=fmtp:") || line.hasPrefix("a=rtcp-fb:") {
            videoLines.append(line)
        }
    }
    let codecs = videoCodecDescriptions(in: sdp).joined(separator: ",")
    let media = mediaLines.isEmpty ? "none" : mediaLines.joined(separator: " | ")
    let video = limitedDiagnosticText(videoLines.isEmpty ? "none" : videoLines.joined(separator: " | "), limit: 1400)
    return "\(label) hash=\(sdpStableHash(sdp)) bytes=\(sdp.utf8.count) media=\(media) videoCodecs=\(codecs.isEmpty ? "none" : codecs) video=\(video)"
}

private func limitedDiagnosticText(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    let end = text.index(text.startIndex, offsetBy: limit)
    return String(text[..<end]) + "...[truncated]"
}

private func sdpStableHash(_ sdp: String) -> String {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in sdp.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return String(format: "%016llx", hash)
}

private func videoCodecDescriptions(in sdp: String) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    var inVideo = false
    for line in sdpLines(sdp) {
        if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video"); continue }
        guard inVideo, line.hasPrefix("a=rtpmap:") else { continue }
        let text = String(line.dropFirst("a=rtpmap:".count))
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count >= 2 else { continue }
        let codec = parts[1].split(separator: "/").first.map(String.init) ?? parts[1]
        let normalized = codec.uppercased()
        guard !seen.contains(normalized) else { continue }
        seen.insert(normalized)
        result.append(normalized)
    }
    return result
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

private func extractIceTargets(from sdp: String) -> [OPNIceMediaTarget] {
    var targets: [OPNIceMediaTarget] = []
    var index: Int32 = -1
    var currentMid = "0"
    var hasOpenMediaSection = false
    for line in sdp.components(separatedBy: .newlines) {
        if line.hasPrefix("m=") {
            if hasOpenMediaSection { targets.append(OPNIceMediaTarget(mid: currentMid, mLineIndex: index)) }
            index += 1
            currentMid = String(index)
            hasOpenMediaSection = true
        } else if hasOpenMediaSection, line.hasPrefix("a=mid:") {
            currentMid = String(line.dropFirst("a=mid:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    if hasOpenMediaSection { targets.append(OPNIceMediaTarget(mid: currentMid, mLineIndex: index)) }
    return targets.filter { $0.mLineIndex >= 0 && !$0.mid.isEmpty }
}

func extractPublicIp(_ hostOrIp: String) -> String {
    let host = extractHost(from: hostOrIp)
    guard !host.isEmpty else { return "" }
    if isIPv4Address(host) { return host }
    if let dashedAddress = dashedIPv4Prefix(from: host) { return dashedAddress }
    return resolvedIPv4Address(for: host) ?? ""
}

private func extractHost(from hostOrIp: String) -> String {
    let trimmed = hostOrIp.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed), let host = url.host(percentEncoded: false), !host.isEmpty { return host }
    return trimmed.split(separator: ":").first.map(String.init) ?? trimmed
}

private func isIPv4Address(_ value: String) -> Bool {
    let parts = value.split(separator: ".")
    guard parts.count == 4 else { return false }
    return parts.allSatisfy { part in
        guard !part.isEmpty, let byte = Int(part), byte >= 0, byte <= 255 else { return false }
        return String(byte) == part || part == "0"
    }
}

private func dashedIPv4Prefix(from host: String) -> String? {
    let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
    let parts = firstLabel.split(separator: "-")
    guard parts.count == 4 else { return nil }
    let address = parts.joined(separator: ".")
    return isIPv4Address(address) ? address : nil
}

private func resolvedIPv4Address(for host: String) -> String? {
    var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_DGRAM, ai_protocol: IPPROTO_UDP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let result else { return nil }
    defer { freeaddrinfo(result) }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var current: UnsafeMutablePointer<addrinfo>? = result
    while let info = current {
        if info.pointee.ai_family == AF_INET, let address = info.pointee.ai_addr?.withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0 }) {
            var ipv4 = address.pointee.sin_addr
            if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                let length = buffer.firstIndex(of: 0) ?? buffer.count
                let bytes = buffer.prefix(length).map { UInt8(bitPattern: $0) }
                return String(decoding: bytes, as: UTF8.self)
            }
        }
        current = info.pointee.ai_next
    }
    return nil
}

private func dictionary(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
private func dictionary(_ value: NSDictionary) -> [String: Any] { value as? [String: Any] ?? [:] }
private func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
private func stringArray(_ value: Any?) -> [String] { if let value = value as? String { return value.isEmpty ? [] : [value] }; if let value = value as? [String] { return value }; return (value as? NSArray)?.compactMap { string($0) }.filter { !$0.isEmpty } ?? [] }
private func emptyNil(_ value: String) -> String? { value.isEmpty ? nil : value }
private func string(_ value: Any?) -> String { if let value = value as? String { return value }; if let value = value as? NSString { return value as String }; if let value = value as? NSNumber { return value.stringValue }; return "" }
private func string(_ value: Any?, fallback: String) -> String { let text = string(value); return text.isEmpty ? fallback : text }
private func int(_ value: Any?, fallback: Int = 0) -> Int { if let value = value as? Int { return value }; if let value = value as? NSNumber { return value.intValue }; if let value = value as? String { return Int(value) ?? fallback }; return fallback }
private func int64(_ value: Any?) -> Int64 { if let value = value as? Int64 { return value }; if let value = value as? NSNumber { return value.int64Value }; if let value = value as? String { return Int64(value) ?? 0 }; return 0 }
private func uint64(_ value: Any?) -> UInt64 { if let value = value as? UInt64 { return value }; if let value = value as? NSNumber { return value.uint64Value }; if let value = value as? String { return UInt64(value) ?? 0 }; return 0 }
private func double(_ value: Any?, fallback: Double = 0) -> Double { if let value = value as? Double { return value }; if let value = value as? NSNumber { return value.doubleValue }; if let value = value as? String { return Double(value) ?? fallback }; return fallback }
private func clampedDouble(_ value: Any?, fallback: Double, minimum: Double, maximum: Double) -> Double { min(max(double(value, fallback: fallback), minimum), maximum) }
private func bool(_ value: Any?) -> Bool { if let value = value as? Bool { return value }; if let value = value as? NSNumber { return value.boolValue }; if let value = value as? String { return (value as NSString).boolValue }; return false }

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
