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

        let requestedCodec = normalizedCodec(string(settings["codec"]))
        if !requestedCodec.isEmpty, !OPNWebRTCCodecSupport.supportsCodec(factory: factory, normalizedCodec: requestedCodec) {
            NSLog("[LibWebRTC] Requested codec %@ is not supported by this WebRTC.framework; retaining full offer", requestedCodec)
        }
        logVideoSdpSummary("offer-video", offerSdp)
        let offer = RTCSessionDescription(type: .offer, sdp: offerSdp)
        peerConnection.setRemoteDescription(offer) { [weak self, weak impl] error in
            guard let self, self.callbackGeneration == generation else { return }
            guard error == nil else {
                self.handleConnectionState(false, error: "setRemoteDescription failed: \(error?.localizedDescription ?? "unknown")")
                return
            }
            guard let impl, let peerConnection = impl.peerConnection, let factory = impl.factory else { return }
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
                let answerSdp = answer.sdp
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
            DispatchQueue.main.sync { impl.remoteVideoView?.removeFromSuperview() }
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
        onIceCandidate?(["candidate": candidate, "sdpMid": sdpMid, "sdpMLineIndex": Int(sdpMLineIndex), "usernameFragment": ""])
    }

    func handleConnectionState(_ connected: Bool, error: String) {
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
        let framesDelta = framesDecoded >= previousFramesDecoded ? framesDecoded - previousFramesDecoded : 0
        let fps = Double(framesDelta) * 1000.0 / Double(dtMs)
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
    let codec = normalizedCodec(string(settings["codec"]))
    let payload = codec == "H265" || codec == "HEVC" ? 102 : (codec == "AV1" ? 45 : 96)
    return "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=OpenNOW\r\nt=0 0\r\na=ice-ufrag:\(credentials.ufrag)\r\na=ice-pwd:\(credentials.pwd)\r\nm=video 9 UDP/TLS/RTP/SAVPF \(payload)\r\nc=IN IP4 0.0.0.0\r\na=rtcp:9 IN IP4 0.0.0.0\r\na=sendrecv\r\na=rtpmap:\(payload) \(codec.isEmpty ? "H264" : codec)/90000\r\na=framerate:\(fps)\r\na=x-nv-video[0].clientViewportWd:\(width)\r\na=x-nv-video[0].clientViewportHt:\(height)\r\n"
}

private struct OPNIceCredentials { var ufrag = ""; var pwd = "" }

private func extractIceCredentials(from sdp: String) -> OPNIceCredentials {
    var credentials = OPNIceCredentials()
    for line in sdp.components(separatedBy: .newlines) {
        if line.hasPrefix("a=ice-ufrag:") { credentials.ufrag = String(line.dropFirst("a=ice-ufrag:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if line.hasPrefix("a=ice-pwd:") { credentials.pwd = String(line.dropFirst("a=ice-pwd:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    return credentials
}

private func extractIceUfrag(from sdp: String) -> String { extractIceCredentials(from: sdp).ufrag }

private func videoSdpHasMediaCodec(_ sdp: String) -> Bool {
    sdp.components(separatedBy: .newlines).contains { $0.hasPrefix("m=video ") && !$0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(" 0") }
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
private func stringArray(_ value: Any?) -> [String] { if let value = value as? [String] { return value }; return (value as? NSArray)?.compactMap { string($0) }.filter { !$0.isEmpty } ?? [] }
private func emptyNil(_ value: String) -> String? { value.isEmpty ? nil : value }
private func string(_ value: Any?) -> String { if let value = value as? String { return value }; if let value = value as? NSString { return value as String }; if let value = value as? NSNumber { return value.stringValue }; return "" }
private func int(_ value: Any?, fallback: Int = 0) -> Int { if let value = value as? Int { return value }; if let value = value as? NSNumber { return value.intValue }; if let value = value as? String { return Int(value) ?? fallback }; return fallback }
private func int64(_ value: Any?) -> Int64 { if let value = value as? Int64 { return value }; if let value = value as? NSNumber { return value.int64Value }; if let value = value as? String { return Int64(value) ?? 0 }; return 0 }
private func uint64(_ value: Any?) -> UInt64 { if let value = value as? UInt64 { return value }; if let value = value as? NSNumber { return value.uint64Value }; if let value = value as? String { return UInt64(value) ?? 0 }; return 0 }
private func double(_ value: Any?, fallback: Double = 0) -> Double { if let value = value as? Double { return value }; if let value = value as? NSNumber { return value.doubleValue }; if let value = value as? String { return Double(value) ?? fallback }; return fallback }
private func bool(_ value: Any?) -> Bool { if let value = value as? Bool { return value }; if let value = value as? NSNumber { return value.boolValue }; if let value = value as? String { return (value as NSString).boolValue }; return false }

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
