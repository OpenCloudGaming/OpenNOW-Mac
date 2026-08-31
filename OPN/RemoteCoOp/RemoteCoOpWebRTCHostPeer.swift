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
    private static let inputChannelLabel = "remote-coop-input"
    private let networkConfiguration: OPNRemoteCoOpNetworkConfiguration
    private let qualityPreset: OPNRemoteCoOpQualityPreset
    private let latencyMode: OPNRemoteCoOpLatencyMode
    private let callbacks: OPNRemoteCoOpHostPeerCallbacks
    private let stateLock = NSLock()
    private let videoQueue: DispatchQueue
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var videoCapturer: RTCVideoCapturer?
    private var videoTrack: RTCVideoTrack?
    private var videoSender: RTCRtpSender?
    private var audioDevice: OPNRemoteCoOpHostAudioDevice?
    private var audioSource: RTCAudioSource?
    private var audioTrack: RTCAudioTrack?
    private var audioSender: RTCRtpSender?
    private var inputChannels: [RTCDataChannel] = []
    /// Owned by `videoQueue`. See `OPNRemoteCoOpVideoRateLimiter` for why frames are never delayed.
    private var videoRateLimiter: OPNRemoteCoOpVideoRateLimiter
    private var senderStatsTask: Task<Void, Never>?
    /// Previous outbound sample, so rates can be differenced rather than reported as lifetime sums.
    private var previousSenderStats: (framesEncoded: Int, framesSent: Int, encodeTime: Double, timestamp: Date)?
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
            try await addIceCandidate(RTCIceCandidate(sdp: candidate, sdpMLineIndex: Int32(signal.sdpMLineIndex ?? 0), sdpMid: signal.sdpMid))
        case .offer:
            throw OPNRemoteCoOpHostPeerError.invalidSignal
        }
    }

    public func close() async {
        let state = stateLock.withLock { () -> (RTCPeerConnection?, [RTCDataChannel]) in
            guard !isClosed else { return (nil, []) }
            isClosed = true
            let peerConnection = peerConnection
            let inputChannels = inputChannels
            let videoTrack = videoTrack
            let videoSender = videoSender
            let audioDevice = audioDevice
            let audioTrack = audioTrack
            let audioSender = audioSender
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
            if let videoSender { _ = peerConnection?.removeTrack(videoSender) }
            if let audioSender { _ = peerConnection?.removeTrack(audioSender) }
            videoTrack?.isEnabled = false
            audioTrack?.isEnabled = false
            audioDevice?.shutdown()
            return (peerConnection, inputChannels)
        }
        senderStatsTask?.cancel()
        senderStatsTask = nil
        // Nothing is buffered on the video queue any more - frames are forwarded or dropped on
        // arrival - so close only has to stop accepting them, which `isClosed` above already did.
        for inputChannel in state.1 {
            inputChannel.delegate = nil
            inputChannel.close()
        }
        state.0?.delegate = nil
        state.0?.close()
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
        guard stateLock.withLock({ !isClosed && videoCapturer != nil }) else { return }
        videoQueue.async { [weak self] in
            self?.forwardVideoFrame(frame)
        }
    }

    public func renderAudioFrame(_ frame: OPNRemoteCoOpHostAudioFrame) {
        stateLock.withLock { audioDevice }?.renderAudioFrame(frame)
    }

    private var closed: Bool {
        stateLock.withLock { isClosed }
    }

    private func makePeerConnection() throws -> RTCPeerConnection {
        let existing = stateLock.withLock { peerConnection }
        if let existing { return existing }

        let encoderFactory = RTCDefaultVideoEncoderFactory()
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

    private func attachVideoTrack(peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
        let source = factory.videoSource(forScreenCast: true)
        source.adaptOutputFormat(toWidth: Int32(qualityPreset.width), height: Int32(qualityPreset.height), fps: Int32(qualityPreset.fps))
        let capturer = RTCVideoCapturer(delegate: source)
        let track = factory.videoTrack(with: source, trackId: "remote-coop-video-\(participantID.uuidString)")
        track.isEnabled = true
        let sender = peerConnection.add(track, streamIds: ["remote-coop-stream-\(participantID.uuidString)"])
        if let sender { configureVideoSender(sender) }
        stateLock.withLock {
            videoSource = source
            videoCapturer = capturer
            videoTrack = track
            videoSender = sender
        }
    }

    /// Hands a frame to libwebrtc immediately, or drops it. Nothing is ever delayed - the decision
    /// and the reasoning behind it live in `OPNRemoteCoOpVideoRateLimiter`.
    private func forwardVideoFrame(_ frame: RTCVideoFrame) {
        guard !closed else { return }
        let arrivalNs = Int64(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds)
        guard case .forward(let timestampNs) = videoRateLimiter.decide(sourceTimestampNs: frame.timeStampNs, arrivalNs: arrivalNs) else { return }
        guard let capturer = stateLock.withLock({ videoCapturer }),
              let relayFrame = makeRelayVideoFrame(from: frame, timeStampNs: timestampNs) else { return }
        capturer.delegate?.capturer(capturer, didCapture: relayFrame)
        captureVideoPacingTelemetryIfNeeded()
    }

    /// Reports what the *sender* is doing, because the guest's own numbers cannot distinguish the
    /// possible causes of a deep jitter buffer.
    ///
    /// A guest sees only that frames arrive irregularly. Whether that is the encoder falling behind,
    /// the source delivering fewer frames than the preset asks for, or this relay dropping them is
    /// only visible here. `qualityLimitationReason` is the decisive field: libwebrtc sets it to
    /// `cpu` when the encoder cannot keep up and `bandwidth` when the estimate is the constraint,
    /// which are opposite problems with opposite fixes.
    private func startSenderStatsPolling(peerConnection: RTCPeerConnection) {
        senderStatsTask?.cancel()
        senderStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, !self.closed else { return }
                await self.captureSenderStats(peerConnection: peerConnection)
            }
        }
    }

    private func captureSenderStats(peerConnection: RTCPeerConnection) async {
        let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
            peerConnection.statistics { continuation.resume(returning: $0) }
        }
        guard let outbound = report.statistics.values.first(where: { $0.type == "outbound-rtp" && ($0.values["kind"] as? String) == "video" }) else { return }

        let framesEncoded = (outbound.values["framesEncoded"] as? NSNumber)?.intValue ?? 0
        let framesSent = (outbound.values["framesSent"] as? NSNumber)?.intValue ?? 0
        let encodeTime = (outbound.values["totalEncodeTime"] as? NSNumber)?.doubleValue ?? 0
        let now = Date()

        // Rates over the interval, not since the session began: a lifetime average cannot show a
        // problem that started after the first few seconds.
        var encodedPerSecond = 0.0
        var msPerEncodedFrame = 0.0
        if let previous = previousSenderStats {
            let elapsed = now.timeIntervalSince(previous.timestamp)
            let deltaEncoded = framesEncoded - previous.framesEncoded
            if elapsed > 0 { encodedPerSecond = Double(deltaEncoded) / elapsed }
            if deltaEncoded > 0 { msPerEncodedFrame = ((encodeTime - previous.encodeTime) / Double(deltaEncoded)) * 1_000 }
        }
        previousSenderStats = (framesEncoded, framesSent, encodeTime, now)

        let limitation = (outbound.values["qualityLimitationReason"] as? String) ?? "unknown"
        let forwarded = videoRateLimiter.forwardedCount
        let dropped = videoRateLimiter.droppedCount

        WebRTCMediaTelemetry.capture("webrtc.remote_coop.sender.video", level: .info, message: "Remote Co-Op outbound video.", attributes: [
            "participantID": participantID.uuidString,
            // "cpu" means the encoder is the constraint, "bandwidth" the network estimate, "none"
            // neither - in which case a low frame rate is the source's, not ours.
            "qualityLimitationReason": limitation,
            "encodedFps": String(format: "%.1f", encodedPerSecond),
            "encodeMsPerFrame": String(format: "%.1f", msPerEncodedFrame),
            "frameWidth": String((outbound.values["frameWidth"] as? NSNumber)?.intValue ?? 0),
            "frameHeight": String((outbound.values["frameHeight"] as? NSNumber)?.intValue ?? 0),
            "framesEncoded": String(framesEncoded),
            "framesSent": String(framesSent),
            // If `relayForwarded` tracks the preset rate but `encodedFps` is lower, the encoder is
            // dropping. If `relayForwarded` is itself low, the source is not producing more.
            "relayForwarded": String(forwarded),
            "relayDropped": String(dropped),
            "preset": "\(qualityPreset.width)x\(qualityPreset.height)@\(qualityPreset.fps)"
        ])
    }

    private func captureVideoPacingTelemetryIfNeeded() {
        guard videoRateLimiter.forwardedCount.isMultiple(of: 240), videoRateLimiter.droppedCount > 0 else { return }
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.video.paced", level: .debug, message: "Remote Co-Op video rate limiter dropped frames above the preset rate.", attributes: [
            "participantID": participantID.uuidString,
            "deliveredFrames": String(videoRateLimiter.forwardedCount),
            "droppedFrames": String(videoRateLimiter.droppedCount),
            "fps": String(qualityPreset.fps),
            "latencyMode": latencyMode.rawValue
        ])
    }

    /// Carries the source's own capture timestamp through rather than re-stamping. See
    /// `forwardVideoFrame` for why that matters to the receiver's jitter buffer.
    /// Re-stamps the frame and passes its buffer through untouched.
    ///
    /// This used to force `frame.newI420()` for any buffer that was not already I420, which on the
    /// native NVST path meant a full NV12-to-I420 conversion of every frame - scaled to the guest
    /// preset - performed synchronously on this peer's serial video queue, once per guest. Two
    /// things were wrong with that:
    ///
    /// - It was wasted work. `RTCCVPixelBuffer` is exactly what libwebrtc's macOS H264 encoder wants
    ///   natively; converting to I420 first only forced the encoder to convert back to feed the
    ///   hardware. A software codec that genuinely needs I420 calls `toI420()` itself, on its own
    ///   thread, where the cost belongs.
    /// - It made delivery bursty. Frames arrive on the decode thread at the source's cadence but
    ///   left through one serial queue doing per-frame conversion, so the queue fell behind and
    ///   caught up in bursts. A receiver reads irregular arrival as jitter and deepens its buffer to
    ///   absorb it - which is what kept the guest's jitter buffer around 390 ms even with
    ///   `jitterBufferTarget` and `playoutDelayHint` both asking for zero on a 5 ms LAN route.
    ///
    /// The buffer already carries the adapted size (see `OPNRemoteCoOpHostVideoRelay`), so scaling
    /// still happens - just inside the encoder's own pass rather than an extra one of ours.
    private func makeRelayVideoFrame(from frame: RTCVideoFrame, timeStampNs: Int64) -> RTCVideoFrame? {
        let buffer = frame.buffer
        guard buffer.width > 0, buffer.height > 0 else { return nil }
        return RTCVideoFrame(buffer: buffer, rotation: frame.rotation, timeStampNs: timeStampNs)
    }

    private func configureVideoSender(_ sender: RTCRtpSender) {
        let parameters = sender.parameters
        let encodings = parameters.encodings.isEmpty ? [RTCRtpEncodingParameters()] : parameters.encodings
        for encoding in encodings {
            encoding.isActive = true
            encoding.maxBitrateBps = NSNumber(value: qualityPreset.videoMaxBitrateBps(for: latencyMode))
            encoding.minBitrateBps = qualityPreset.videoMinBitrateBps(for: latencyMode).map(NSNumber.init(value:))
            encoding.maxFramerate = NSNumber(value: qualityPreset.fps)
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

    private func attachAudioTrack(peerConnection: RTCPeerConnection, factory: RTCPeerConnectionFactory) {
        let source = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = factory.audioTrack(with: source, trackId: "remote-coop-audio-\(participantID.uuidString)")
        track.isEnabled = true
        let sender = peerConnection.add(track, streamIds: ["remote-coop-stream-\(participantID.uuidString)"])
        stateLock.withLock {
            audioSource = source
            audioTrack = track
            audioSender = sender
        }
    }

    private func createAndSendOffer(peerConnection: RTCPeerConnection) async throws {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.offer.create", level: .info, message: "Creating Remote Co-Op WebRTC offer.", attributes: ["participantID": participantID.uuidString])
        let offer = try await createOffer(peerConnection: peerConnection, constraints: constraints)
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.offer.created", level: .info, message: "Remote Co-Op WebRTC offer created.", attributes: ["participantID": participantID.uuidString, "sdpBytes": String(offer.sdp.utf8.count)])
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
