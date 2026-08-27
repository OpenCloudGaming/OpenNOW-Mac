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
    private var lastVideoFrameTimestampNs: Int64 = 0
    private var pendingVideoFrame: RTCVideoFrame?
    private var isVideoFrameDeliveryScheduled = false
    private var nextVideoFrameDeliveryNanoseconds: UInt64 = 0
    private var deliveredVideoFrameCount: UInt64 = 0
    private var droppedVideoFrameCount: UInt64 = 0
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
        super.init()
    }

    public func start() async throws {
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.host_peer.start", level: .info, message: "Starting WebRTC Remote Co-Op host peer.", attributes: ["participantID": participantID.uuidString])
        let peerConnection = try makePeerConnection()
        createInputChannel(peerConnection: peerConnection)
        try await createAndSendOffer(peerConnection: peerConnection)
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
        videoQueue.async { [weak self] in
            self?.pendingVideoFrame = nil
            self?.isVideoFrameDeliveryScheduled = false
        }
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
            self?.enqueueVideoFrame(frame)
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

    private func enqueueVideoFrame(_ frame: RTCVideoFrame) {
        guard !closed else {
            pendingVideoFrame = nil
            return
        }
        if pendingVideoFrame != nil { droppedVideoFrameCount &+= 1 }
        pendingVideoFrame = frame
        scheduleVideoFrameDeliveryIfNeeded()
    }

    private func scheduleVideoFrameDeliveryIfNeeded() {
        guard !isVideoFrameDeliveryScheduled else { return }
        isVideoFrameDeliveryScheduled = true
        let now = DispatchTime.now().uptimeNanoseconds
        let deadlineNanoseconds = max(now, nextVideoFrameDeliveryNanoseconds)
        videoQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadlineNanoseconds)) { [weak self] in
            self?.deliverPendingVideoFrame()
        }
    }

    private func deliverPendingVideoFrame() {
        isVideoFrameDeliveryScheduled = false
        guard !closed else {
            pendingVideoFrame = nil
            return
        }
        guard let frame = pendingVideoFrame else { return }
        pendingVideoFrame = nil
        guard let capturer = stateLock.withLock({ videoCapturer }), let relayFrame = makeRelayVideoFrame(from: frame) else { return }
        capturer.delegate?.capturer(capturer, didCapture: relayFrame)
        deliveredVideoFrameCount &+= 1
        nextVideoFrameDeliveryNanoseconds = DispatchTime.now().uptimeNanoseconds &+ videoFrameIntervalNanoseconds
        captureVideoPacingTelemetryIfNeeded()
        if pendingVideoFrame != nil { scheduleVideoFrameDeliveryIfNeeded() }
    }

    private var videoFrameIntervalNanoseconds: UInt64 {
        UInt64(1_000_000_000 / max(1, qualityPreset.fps))
    }

    private func captureVideoPacingTelemetryIfNeeded() {
        guard deliveredVideoFrameCount.isMultiple(of: 240), droppedVideoFrameCount > 0 else { return }
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.video.paced", level: .debug, message: "Remote Co-Op video pacing dropped stale frames.", attributes: [
            "participantID": participantID.uuidString,
            "deliveredFrames": String(deliveredVideoFrameCount),
            "droppedFrames": String(droppedVideoFrameCount),
            "fps": String(qualityPreset.fps),
            "latencyMode": latencyMode.rawValue
        ])
    }

    private func makeRelayVideoFrame(from frame: RTCVideoFrame) -> RTCVideoFrame? {
        let buffer = frame.buffer is RTCI420Buffer ? frame.buffer : frame.newI420().buffer
        guard buffer.width > 0, buffer.height > 0 else { return nil }
        return RTCVideoFrame(buffer: buffer, rotation: frame.rotation, timeStampNs: nextVideoFrameTimestampNs())
    }

    private func nextVideoFrameTimestampNs() -> Int64 {
        stateLock.withLock {
            let now = Int64(truncatingIfNeeded: DispatchTime.now().uptimeNanoseconds)
            let timestamp = max(now, lastVideoFrameTimestampNs + 1)
            lastVideoFrameTimestampNs = timestamp
            return timestamp
        }
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
