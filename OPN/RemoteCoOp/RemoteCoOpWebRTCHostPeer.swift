import Dispatch
import Foundation
@preconcurrency import WebRTC

public struct OPNRemoteCoOpWebRTCHostPeerFactory: OPNRemoteCoOpHostPeerFactory {
    public init() {}

    public func makePeer(participantID: UUID,
                         networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                         qualityPreset: OPNRemoteCoOpQualityPreset,
                         latencyMode: OPNRemoteCoOpLatencyMode,
                         callbacks: OPNRemoteCoOpHostPeerCallbacks) -> any OPNRemoteCoOpHostPeer {
        OPNRemoteCoOpWebRTCHostPeer(participantID: participantID, networkConfiguration: networkConfiguration, qualityPreset: qualityPreset, latencyMode: latencyMode, callbacks: callbacks)
    }
}

public final class OPNRemoteCoOpWebRTCHostPeer: NSObject, OPNRemoteCoOpHostPeer, OPNRemoteCoOpHostVideoSink, OPNRemoteCoOpHostAudioSink, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    public let participantID: UUID
    private static let inputChannelLabel = OPNRemoteCoOpDataChannelLabel.input
    let networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    /// Mutable: the host can retarget one guest mid-session. Guarded by `stateLock`.
    var qualityPreset: OPNRemoteCoOpQualityPreset
    let latencyMode: OPNRemoteCoOpLatencyMode
    let callbacks: OPNRemoteCoOpHostPeerCallbacks
    let stateLock = NSLock()
    let videoQueue: DispatchQueue
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    var videoSource: RTCVideoSource?
    var videoCapturer: RTCVideoCapturer?
    private var videoTrack: RTCVideoTrack?
    private var videoSender: RTCRtpSender?
    private var audioDevice: OPNRemoteCoOpHostAudioDevice?
    private var audioSource: RTCAudioSource?
    private var audioTrack: RTCAudioTrack?
    private var audioSender: RTCRtpSender?
    private var inputChannels: [RTCDataChannel] = []
    /// Owned by `videoQueue`. See `OPNRemoteCoOpVideoRateLimiter` for why frames are never delayed.
    var videoRateLimiter: OPNRemoteCoOpVideoRateLimiter
    /// Published copies of the limiter's counters, for readers that are not on `videoQueue`. Reading
    /// the limiter itself from the stats task raced the per-frame mutation.
    var publishedRelayCounts = (forwarded: UInt64(0), dropped: UInt64(0))
    var senderStatsTask: Task<Void, Never>?
    /// Previous outbound sample, so rates can be differenced rather than reported as lifetime sums.
    var previousSenderStats: (framesEncoded: Int, framesSent: Int, encodeTime: Double, timestamp: Date)?
    var previousSendDelay: Double?
    var previousPacketsSent: Int?
    /// The size of the last frame handed to this peer, which is the ceiling on what its guest can be
    /// sent. Recorded here rather than asked of the relay because the peer already sees every frame,
    /// and it is what separates "the link is slow" from "the preset is above what the seat produces".
    var lastSourceWidth = 0
    var lastSourceHeight = 0
    /// What was last handed to `adaptOutputFormat`, so a re-request only happens when it would differ.
    var appliedAdaptBox = (width: 0, height: 0, fps: 0)
    private var isClosed = false

    public init(participantID: UUID,
                networkConfiguration: OPNRemoteCoOpNetworkConfiguration,
                qualityPreset: OPNRemoteCoOpQualityPreset,
                latencyMode: OPNRemoteCoOpLatencyMode,
                callbacks: OPNRemoteCoOpHostPeerCallbacks) {
        self.participantID = participantID
        self.networkConfiguration = networkConfiguration
        self.qualityPreset = qualityPreset
        self.latencyMode = latencyMode
        self.callbacks = callbacks
        self.videoQueue = DispatchQueue(label: "io.github.opencloudgaming.opennow.remote-coop.video.\(participantID.uuidString)")
        self.videoRateLimiter = OPNRemoteCoOpVideoRateLimiter(targetFps: qualityPreset.fps)
        super.init()
    }

    public func start() async throws {
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.start", level: .info, message: "Starting WebRTC Remote Co-Op host peer.", attributes: ["participantID": participantID.uuidString])
        let peerConnection = try makePeerConnection()
        createInputChannel(peerConnection: peerConnection)
        try await createAndSendOffer(peerConnection: peerConnection)
        startSenderStatsPolling(peerConnection: peerConnection)
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.started", level: .info, message: "WebRTC Remote Co-Op host peer started.", attributes: ["participantID": participantID.uuidString])
    }

    public func apply(_ signal: OPNRemoteCoOpWirePeerSignal) async throws {
        switch signal.kind {
        case .answer:
            guard let sdp = signal.sdp, !sdp.isEmpty else { throw OPNRemoteCoOpHostPeerError.invalidSignal }
            try await setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp))
        case .iceCandidate:
            guard let candidate = signal.candidate, !candidate.isEmpty else { throw OPNRemoteCoOpHostPeerError.invalidSignal }
            // `Int32(_:)` traps on anything a 32-bit integer cannot hold, and this value is decoded
            // straight out of a guest's JSON, so an m-line index of 2147483648 crashed the whole
            // process from the far side of the wire.
            guard let mLineIndex = Int32(exactly: signal.sdpMLineIndex ?? 0) else { throw OPNRemoteCoOpHostPeerError.invalidSignal }
            try await addIceCandidate(RTCIceCandidate(sdp: candidate, sdpMLineIndex: mLineIndex, sdpMid: signal.sdpMid))
        case .offer:
            throw OPNRemoteCoOpHostPeerError.invalidSignal
        }
    }

    /// What `close()` carries out of the lock so libwebrtc is never called while it is held.
    private struct ClosingState {
        var peerConnection: RTCPeerConnection?
        var inputChannels: [RTCDataChannel] = []
        var videoTrack: RTCVideoTrack?
        var videoSender: RTCRtpSender?
        var audioTrack: RTCAudioTrack?
        var audioSender: RTCRtpSender?
        var audioDevice: OPNRemoteCoOpHostAudioDevice?
    }

    public func close() async {
        // Everything libwebrtc runs OUTSIDE the lock, deliberately.
        //
        // `removeTrack` is a proxy method that blocks onto libwebrtc's signaling thread, and that same
        // thread delivers `didGenerate` / `didOpen dataChannel` / `didReceiveMessageWith`
        // synchronously - all of which take `stateLock` (via `closed` and `bindInputChannel`). Calling
        // it while holding the lock is a two-party deadlock that wedges this peer and, because
        // `close()` is awaited from `OPNRemoteCoOpHostPeerController`, the whole peer-controller actor
        // behind it. ICE gathering and SCTP open overlap teardown routinely - a guest's Wi-Fi blip is
        // enough - so this is reachable, not theoretical. The sibling
        // `OPNRemoteCoOpNativeGuestPeer.close()` and `NvstWebRtcBundle.close()` already snapshot then
        // release; this was the one place that did not.
        let state = stateLock.withLock { () -> ClosingState in
            guard !isClosed else { return ClosingState() }
            isClosed = true
            let state = ClosingState(
                peerConnection: peerConnection,
                inputChannels: inputChannels,
                videoTrack: videoTrack,
                videoSender: videoSender,
                audioTrack: audioTrack,
                audioSender: audioSender,
                audioDevice: audioDevice
            )
            self.peerConnection = nil
            self.inputChannels = []
            self.videoSource = nil
            self.videoCapturer = nil
            self.videoTrack = nil
            self.videoSender = nil
            self.audioDevice = nil
            self.audioSource = nil
            self.audioTrack = nil
            self.audioSender = nil
            factory = nil
            return state
        }
        if let videoSender = state.videoSender { _ = state.peerConnection?.removeTrack(videoSender) }
        if let audioSender = state.audioSender { _ = state.peerConnection?.removeTrack(audioSender) }
        state.videoTrack?.isEnabled = false
        state.audioTrack?.isEnabled = false
        state.audioDevice?.shutdown()
        // Under the lock like every other member: `start()` writes this from whatever task called it
        // while `close()` reads it from another, and a torn `Task?` is a reference-count race rather
        // than merely a stale read.
        let statsTask = stateLock.withLock { () -> Task<Void, Never>? in
            let statsTask = senderStatsTask
            senderStatsTask = nil
            return statsTask
        }
        statsTask?.cancel()
        // Nothing is buffered on the video queue any more - frames are forwarded or dropped on
        // arrival - so close only has to stop accepting them, which `isClosed` above already did.
        for inputChannel in state.inputChannels {
            inputChannel.delegate = nil
            inputChannel.close()
        }
        state.peerConnection?.delegate = nil
        state.peerConnection?.close()
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !closed else { return }
        Task {
            await callbacks.sendSignal(OPNRemoteCoOpWirePeerSignal(kind: .iceCandidate, candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex)))
        }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        bindInputChannel(dataChannel)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !closed else { return }
        let packets = OPNRemoteCoOpHostPeerInputDecoder.decodePackets(buffer.data as Data, expectedParticipantID: participantID)
        guard !packets.isEmpty else { return }
        Task {
            for packet in packets { await callbacks.receiveInput(packet) }
        }
    }

    public func renderVideoFrame(_ frame: RTCVideoFrame) {
        renderSharedVideoFrame(OPNRemoteCoOpSharedVideoFrame(sourceFrame: frame))
    }

    public func renderSharedVideoFrame(_ frame: OPNRemoteCoOpSharedVideoFrame) {
        guard stateLock.withLock({ !isClosed && videoCapturer != nil }) else { return }
        videoQueue.async { [weak self] in
            self?.forwardVideoFrame(frame)
        }
    }

    public func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
        stateLock.withLock { audioDevice }?.renderAudioFrame(frame)
    }

    var closed: Bool {
        stateLock.withLock { isClosed }
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let existing = stateLock.withLock { peerConnection }
        if let existing { return existing }

        let encoderFactory = RTCDefaultVideoEncoderFactory()
        // Constrained High rather than libwebrtc's Baseline: same hardware encoder, but CABAC and 8x8
        // transforms are worth ~15-20% bitrate at equal quality. Only reorders the offer, so a guest
        // that cannot do it still negotiates what it can.
        encoderFactory.preferredCodec = RTCVideoCodecInfo(name: kRTCVideoCodecH264Name, parameters: [
            "profile-level-id": kRTCMaxSupportedH264ProfileLevelConstrainedHigh,
            "level-asymmetry-allowed": "1",
            // Mode 1 splits a NAL unit across packets, which a keyframe at these resolutions needs.
            "packetization-mode": "1"
        ])
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        let audioDevice = OPNRemoteCoOpHostAudioDevice()
        let factory = RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoderFactory, audioDevice: audioDevice)
        let configuration = RTCConfiguration()
        configuration.iceServers = iceServers()
        configuration.iceTransportPolicy = networkConfiguration.iceTransportPolicy == .relay ? .relay : .all
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .enabled
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.iceConnectionReceivingTimeout = 30_000
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw OPNRemoteCoOpHostPeerError.negotiationFailed("Unable to create Remote Co-Op WebRTC peer connection.")
        }
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.connection", level: .info, message: "Remote Co-Op peer connection created.", attributes: ["participantID": participantID.uuidString, "iceServers": String(configuration.iceServers.count), "policy": networkConfiguration.iceTransportPolicy.rawValue])
        attachVideoTrack(peerConnection: peerConnection, factory: factory)
        attachAudioTrack(peerConnection: peerConnection, factory: factory)
        stateLock.withLock {
            self.factory = factory
            self.peerConnection = peerConnection
            self.audioDevice = audioDevice
        }
        return peerConnection
    }

    private func createInputChannel(peerConnection: RTCPeerConnection) {
        guard networkConfiguration.dataChannelInputEnabled else { return }
        let hasHostChannel = stateLock.withLock { inputChannels.contains { $0.label == Self.inputChannelLabel } }
        guard !hasHostChannel else { return }
        let configuration = RTCDataChannelConfiguration()
        configuration.isOrdered = false
        configuration.maxRetransmits = 0
        guard let channel = peerConnection.dataChannel(forLabel: Self.inputChannelLabel, configuration: configuration) else { return }
        bindInputChannel(channel)
    }

    private func bindInputChannel(_ channel: RTCDataChannel) {
        let shouldBind = stateLock.withLock { () -> Bool in
            guard !inputChannels.contains(where: { $0 === channel }) else { return false }
            inputChannels.append(channel)
            return true
        }
        if shouldBind { channel.delegate = self }
    }

    var currentQualityPreset: OPNRemoteCoOpQualityPreset {
        stateLock.withLock { qualityPreset }
    }

    @discardableResult
    public func updateQualityPreset(_ preset: OPNRemoteCoOpQualityPreset) async -> Bool {
        // `isSettled` separates "nothing to do" from "cannot do it yet". Only the second wants a retry,
        // and the caller records the preset as applied on anything else.
        var isSettled = true
        let state = stateLock.withLock { () -> (RTCVideoSource, RTCRtpSender?)? in
            guard !isClosed, qualityPreset != preset else { return nil }
            guard let videoSource else {
                isSettled = false
                return nil
            }
            qualityPreset = preset
            return (videoSource, videoSender)
        }
        guard let state else { return isSettled }
        applyOutputFormat(to: state.0, preset: preset)
        if let sender = state.1 { configureVideoSender(sender, preset: preset) }
        // The limiter is owned by `videoQueue`, not `stateLock`.
        videoQueue.async { [weak self] in
            self?.videoRateLimiter = OPNRemoteCoOpVideoRateLimiter(targetFps: preset.fps)
        }
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.peer.quality", level: .info, message: "Remote Co-Op guest quality retargeted.", attributes: [
            "participantID": participantID.uuidString,
            "preset": "\(preset.width)x\(preset.height)@\(preset.fps)",
            "maxBitrateBps": String(preset.videoMaxBitrateBps(for: latencyMode))
        ])
        return true
    }

    /// Requests a box shaped like the *source*, not like the preset.
    ///
    /// `adaptOutputFormat` is not a bounding box: libwebrtc's `VideoAdapter` reads the dimensions as a
    /// target aspect ratio and **crops** the frame to it before scaling. Asking for a preset's literal
    /// 3840x2160 against a 5120x2160 seat therefore cut 25% off the width - measured as a guest
    /// receiving 2880x1620 - discarding picture rather than scaling it.
    ///
    /// Fitting the source into the preset first gives an equal aspect ratio, so there is nothing for
    /// the adapter to crop and the preset does what it reads like: a ceiling on size, not a reshape.
    func applyOutputFormat(to source: RTCVideoSource, preset: OPNRemoteCoOpQualityPreset) {
        let box = adaptBox(for: preset)
        let alreadyApplied = stateLock.withLock { () -> Bool in
            guard appliedAdaptBox == box else {
                appliedAdaptBox = box
                return false
            }
            return true
        }
        guard !alreadyApplied else { return }
        source.adaptOutputFormat(toWidth: Int32(box.width), height: Int32(box.height), fps: Int32(box.fps))
    }

    /// Falls back to the preset's own shape until a frame has been seen, which is the best available
    /// guess and matches what the encoder would have been configured with anyway.
    func adaptBox(for preset: OPNRemoteCoOpQualityPreset) -> (width: Int, height: Int, fps: Int) {
        let source = stateLock.withLock { (width: lastSourceWidth, height: lastSourceHeight) }
        guard source.width > 0, source.height > 0 else { return (preset.width, preset.height, preset.fps) }
        let fitted = OPNRemoteCoOpHostVideoRelay.adaptedSize(
            sourceWidth: source.width,
            sourceHeight: source.height,
            maximumWidth: preset.width,
            maximumHeight: preset.height
        )
        return (fitted.width, fitted.height, preset.fps)
    }

    private func attachVideoTrack(peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
        let preset = currentQualityPreset
        let source = factory.videoSource(forScreenCast: true)
        applyOutputFormat(to: source, preset: preset)
        let capturer = RTCVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "remote-coop-video-\(participantID.uuidString)")
        track.isEnabled = true
        let sender = peerConnection.add(track, streamIds: ["remote-coop-stream-\(participantID.uuidString)"])
        if let sender { configureVideoSender(sender, preset: preset) }
        stateLock.withLock {
            videoSource = source
            videoCapturer = capturer
            videoTrack = track
            videoSender = sender
        }
    }

    /// Hands a frame to libwebrtc immediately, or drops it. Nothing is ever delayed - the decision
    /// and the reasoning behind it live in `OPNRemoteCoOpVideoRateLimiter`.
    private func configureVideoSender(_ sender: RTCRtpSender, preset: OPNRemoteCoOpQualityPreset) {
        let parameters = sender.parameters
        let encodings = parameters.encodings.isEmpty ? [RTCRtpEncodingParameters()] : parameters.encodings
        let maxBitrateBps = preset.videoMaxBitrateBps(for: latencyMode)
        for encoding in encodings {
            encoding.isActive = true
            encoding.maxBitrateBps = NSNumber(value: maxBitrateBps)
            // Without a floor the receiver's jitter buffer target climbs to the worst pacing delay it
            // sees during the ramp (~200 ms on loopback) and decays at roughly 1 ms/s.
            encoding.minBitrateBps = NSNumber(value: preset.videoMinBitrateBps(for: latencyMode) ?? maxBitrateBps / 2)
            encoding.maxFramerate = NSNumber(value: preset.fps)
            encoding.scaleResolutionDownBy = 1
            encoding.bitratePriority = latencyMode == .lowLatency ? 1 : 2
            encoding.networkPriority = .high
        }
        if latencyMode == .lowLatency {
            parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainFramerate.rawValue)
        }
        parameters.encodings = encodings
        sender.parameters = parameters
    }

    /// `maxaveragebitrate` in the SDP is what the encoder *may* use; this is what the allocator will
    /// give it. Without both, the stereo mix is encoded down into a voice-call slice.
    private func configureAudioSender(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        let encodings = parameters.encodings.isEmpty ? [RTCRtpEncodingParameters()] : parameters.encodings
        for encoding in encodings {
            encoding.isActive = true
            encoding.maxBitrateBps = NSNumber(value: 256_000)
            encoding.networkPriority = .high
        }
        parameters.encodings = encodings
        sender.parameters = parameters
    }

    private func attachAudioTrack(peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "remote-coop-audio-\(participantID.uuidString)")
        track.isEnabled = true
        let sender = peerConnection.add(track, streamIds: ["remote-coop-stream-\(participantID.uuidString)"])
        if let sender { configureAudioSender(sender) }
        stateLock.withLock {
            audioSource = source
            audioTrack = track
            audioSender = sender
        }
    }

    private func createAndSendOffer(peerConnection: RTCPeerConnection) async throws {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.offer.create", level: .info, message: "Creating Remote Co-Op WebRTC offer.", attributes: ["participantID": participantID.uuidString])
        let generatedOffer = try await createOffer(peerConnection: peerConnection, constraints: constraints)
        // The guest has to be offered the same description this side sets locally, so the tuning is
        // applied once and both uses read from it.
        let offer = RTCSessionDescription(type: generatedOffer.type, sdp: OPNRemoteCoOpSDPTuning.tunedForGameStreaming(generatedOffer.sdp))
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.offer.created", level: .info, message: "Remote Co-Op WebRTC offer created.", attributes: ["participantID": participantID.uuidString, "sdpBytes": String(offer.sdp.utf8.count), "audioTuned": String(offer.sdp != generatedOffer.sdp)])
        try await setLocalDescription(offer, peerConnection: peerConnection)
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.offer.local_description", level: .info, message: "Remote Co-Op local offer description set.", attributes: ["participantID": participantID.uuidString])
        await callbacks.sendSignal(OPNRemoteCoOpWirePeerSignal(kind: .offer, sdp: offer.sdp))
    }

    private func createOffer(peerConnection: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.offer(for: constraints) { offer, error in
                if let offer {
                    continuation.resume(returning: offer)
                } else {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error?.localizedDescription ?? "Unable to create Remote Co-Op WebRTC offer."))
                }
            }
        }
    }

    private func setLocalDescription(_ description: RTCSessionDescription, peerConnection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func setRemoteDescription(_ description: RTCSessionDescription) async throws {
        guard let peerConnection = stateLock.withLock({ peerConnection }) else { throw OPNRemoteCoOpHostPeerError.peerNotFound }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func addIceCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let peerConnection = stateLock.withLock({ peerConnection }) else { throw OPNRemoteCoOpHostPeerError.peerNotFound }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func iceServers() -> [RTCIceServer] {
        networkConfiguration.iceServers.compactMap { server in
            guard !server.urls.isEmpty else { return nil }
            return RTCIceServer(urlStrings: server.urls, username: emptyNil(server.username), credential: emptyNil(server.credential))
        }
    }

    private func emptyNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
