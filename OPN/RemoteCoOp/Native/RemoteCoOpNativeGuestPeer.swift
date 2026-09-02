//
//  RemoteCoOpNativeGuestPeer.swift
//  OpenNOW
//
//  The guest's end of a native Remote Co-Op media session: a receive-only `RTCPeerConnection`
//  that answers the host's offer and surfaces the tracks it gets.
//
//  The host (`OPNRemoteCoOpWebRTCHostPeer`) owns the offer, the video source and the input data
//  channel; this side only applies descriptions, trickles candidates back, and hands the decoded
//  video track to whoever renders it. Audio plays through libwebrtc's default device - the guest
//  factory deliberately does not install the host's silent audio device.
//

import Foundation
@preconcurrency import WebRTC

/// What only the guest can measure. "Feels laggy" has four distinct causes - slow route, deep jitter
/// buffer, slow decode, host not sending - and these fields are what tell them apart.
public struct OPNRemoteCoOpGuestStats: Equatable, Sendable {
    /// Negative until ICE nominates a pair.
    public var roundTripMilliseconds: Double
    /// How long a frame waits after arriving before it may be shown - the largest controllable term in
    /// a WebRTC receive path.
    public var jitterBufferMilliseconds: Double
    public var decodeMillisecondsPerFrame: Double
    public var decodedFramesPerSecond: Double
    public var frameWidth: Int
    public var frameHeight: Int
    public var freezeCount: Int

    public init(roundTripMilliseconds: Double = -1,
                jitterBufferMilliseconds: Double = -1,
                decodeMillisecondsPerFrame: Double = -1,
                decodedFramesPerSecond: Double = 0,
                frameWidth: Int = 0,
                frameHeight: Int = 0,
                freezeCount: Int = 0) {
        self.roundTripMilliseconds = roundTripMilliseconds
        self.jitterBufferMilliseconds = jitterBufferMilliseconds
        self.decodeMillisecondsPerFrame = decodeMillisecondsPerFrame
        self.decodedFramesPerSecond = decodedFramesPerSecond
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.freezeCount = freezeCount
    }

    public var overlayText: String {
        var parts: [String] = []
        if frameWidth > 0, frameHeight > 0 { parts.append("\(frameWidth)x\(frameHeight)") }
        parts.append(decodedFramesPerSecond > 0 ? String(format: "%.0f fps", decodedFramesPerSecond) : "— fps")
        parts.append(roundTripMilliseconds >= 0 ? String(format: "rtt %.1f ms", roundTripMilliseconds) : "rtt —")
        parts.append(jitterBufferMilliseconds >= 0 ? String(format: "buffer %.1f ms", jitterBufferMilliseconds) : "buffer —")
        if decodeMillisecondsPerFrame >= 0 { parts.append(String(format: "decode %.1f ms", decodeMillisecondsPerFrame)) }
        if freezeCount > 0 { parts.append("freezes \(freezeCount)") }
        return parts.joined(separator: "  ·  ")
    }
}

public final class OPNRemoteCoOpNativeGuestPeer: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate, @unchecked Sendable {
    public let participantID: UUID

    /// Called on libwebrtc's thread when the host's tracks arrive. Hop to the main actor before
    /// touching UI.
    public var onVideoTrack: (@Sendable (RTCVideoTrack) -> Void)?
    /// Answers and candidates to carry back over signaling.
    public var onSignal: (@Sendable (OPNRemoteCoOpWirePeerSignal) async -> Void)?
    /// Called off the main actor.
    public var onStats: (@Sendable (OPNRemoteCoOpGuestStats) -> Void)?

    private let stateLock = NSLock()
    private var factory: RTCPeerConnectionFactory?
    private var peerConnection: RTCPeerConnection?
    private var inputChannels: [RTCDataChannel] = []
    private var deliveredVideoTrackIDs: Set<String> = []
    private var isClosed = false
    private var statsTask: Task<Void, Never>?
    private var previousInboundStats: (jitterBufferDelay: Double, jitterBufferEmitted: Int, framesDecoded: Int, timestamp: Date)?
    private var previousDecode: (decodeTime: Double, framesDecoded: Int)?

    public init(participantID: UUID) {
        self.participantID = participantID
        super.init()
    }

    /// Creates the peer connection. Must run before the first offer is handled.
    public func start(networkConfiguration: OPNRemoteCoOpNetworkConfiguration) throws {
        guard stateLock.withLock({ peerConnection == nil && !isClosed }) else { return }
        // Explicit factories: the default codec set is what makes VideoToolbox's hardware H264 decoder
        // available, and software decode would not keep up at 1440p120.
        let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
        let configuration = RTCConfiguration()
        configuration.iceServers = networkConfiguration.iceServers.map { server in
            RTCIceServer(urlStrings: server.urls, username: server.username, credential: server.credential)
        }
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.tcpCandidatePolicy = .enabled
        configuration.continualGatheringPolicy = .gatherOnce
        // Guests on a LAN/VPN have a fast, stable path: shallow audio buffering and fast
        // acceleration keep NetEQ from adding latency it would want on the open internet.
        configuration.audioJitterBufferMaxPackets = 50
        configuration.audioJitterBufferFastAccelerate = true
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peerConnection = factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw OPNRemoteCoOpHostPeerError.negotiationFailed("Unable to create the guest Remote Co-Op peer connection.")
        }
        stateLock.withLock {
            self.factory = factory
            self.peerConnection = peerConnection
        }
        startStatsPolling()
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.guest_peer.started", level: .info, message: "Native Remote Co-Op guest peer created.", attributes: ["participantID": participantID.uuidString])
    }

    /// Drops silently before the channel opens: approval is what opens the peer, so early packets have
    /// nowhere to go. Sent as a binary frame rather than JSON - see `OPNRemoteCoOpInputBinaryCodec`.
    public func sendInput(_ packet: OPNRemoteCoOpInputPacket) {
        let channel = stateLock.withLock {
            inputChannels.first { $0.label == OPNRemoteCoOpDataChannelLabel.input && $0.readyState == .open }
        }
        guard let channel, !stateLock.withLock({ isClosed }) else { return }
        channel.sendData(RTCDataBuffer(data: OPNRemoteCoOpInputBinaryCodec.encode(packet), isBinary: true))
    }

    public func handle(_ signal: OPNRemoteCoOpWirePeerSignal) async throws {
        switch signal.kind {
        case .offer:
            guard let sdp = signal.sdp, !sdp.isEmpty else { throw OPNRemoteCoOpHostPeerError.invalidSignal }
            try await setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp))
            let generatedAnswer = try await createAnswer()
            // The answer must carry the host's Opus parameters back, or the negotiated result falls to
            // whichever side asked for less.
            let answer = RTCSessionDescription(type: generatedAnswer.type, sdp: OPNRemoteCoOpSDPTuning.tunedForGameStreaming(generatedAnswer.sdp))
            try await setLocalDescription(answer)
            if let onSignal {
                await onSignal(OPNRemoteCoOpWirePeerSignal(kind: .answer, sdp: answer.sdp))
            }
        case .iceCandidate:
            guard let candidate = signal.candidate, !candidate.isEmpty else { throw OPNRemoteCoOpHostPeerError.invalidSignal }
            // `Int32(_:)` traps on anything a 32-bit integer cannot hold, and this value is decoded
            // straight out of a guest's JSON, so an m-line index of 2147483648 crashed the whole
            // process from the far side of the wire.
            guard let mLineIndex = Int32(exactly: signal.sdpMLineIndex ?? 0) else { throw OPNRemoteCoOpHostPeerError.invalidSignal }
            try await addIceCandidate(RTCIceCandidate(sdp: candidate, sdpMLineIndex: mLineIndex, sdpMid: signal.sdpMid))
        case .answer:
            throw OPNRemoteCoOpHostPeerError.invalidSignal
        }
    }

    public func close() {
        let state = stateLock.withLock { () -> (RTCPeerConnection?, [RTCDataChannel]) in
            guard !isClosed else { return (nil, []) }
            isClosed = true
            let peerConnection = self.peerConnection
            let inputChannels = self.inputChannels
            self.factory = nil
            self.peerConnection = nil
            self.inputChannels = []
            return (peerConnection, inputChannels)
        }
        stateLock.withLock {
            statsTask?.cancel()
            statsTask = nil
        }
        for channel in state.1 {
            channel.delegate = nil
            channel.close()
        }
        state.0?.delegate = nil
        state.0?.close()
    }

    // MARK: - RTCPeerConnectionDelegate

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        guard let track = stream.videoTracks.first else { return }
        deliverVideoTrack(track)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    /// The unified-plan path to the same tracks; only this callback is guaranteed to fire. An audio
    /// track that arrives without being enabled here plays silence while every counter looks healthy.
    public func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard !stateLock.withLock({ isClosed }) else { return }
        guard let track = transceiver.receiver.track else { return }
        track.isEnabled = true
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.guest_peer.track", level: .info, message: "Native Remote Co-Op guest received a track.", attributes: [
            "participantID": participantID.uuidString,
            "kind": track.kind
        ])
        guard let videoTrack = track as? RTCVideoTrack else { return }
        deliverVideoTrack(videoTrack)
    }

    /// Both track callbacks can fire for the same track, and a second delivery would tear down the
    /// guest's Metal renderer mid-stream.
    private func deliverVideoTrack(_ track: RTCVideoTrack) {
        let shouldDeliver = stateLock.withLock { () -> Bool in
            guard !isClosed, !deliveredVideoTrackIDs.contains(track.trackId) else { return false }
            deliveredVideoTrackIDs.insert(track.trackId)
            return true
        }
        guard shouldDeliver else { return }
        onVideoTrack?(track)
    }

    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard let onSignal, !stateLock.withLock({ isClosed }) else { return }
        let signal = OPNRemoteCoOpWirePeerSignal(kind: .iceCandidate, candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: Int(candidate.sdpMLineIndex))
        Task { await onSignal(signal) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        let shouldBind = stateLock.withLock { () -> Bool in
            guard !inputChannels.contains(where: { $0 === dataChannel }) else { return false }
            inputChannels.append(dataChannel)
            return true
        }
        if shouldBind { dataChannel.delegate = self }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {}

    // MARK: - RTCDataChannelDelegate

    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}

    // MARK: - Stats

    private func startStatsPolling() {
        let task = Task { [weak self] in
            var samplesSinceLog = 0
            while !Task.isCancelled {
                // One second for the overlay; the log line stays on the old five-second cadence.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, !stateLock.withLock({ self.isClosed }) else { return }
                samplesSinceLog += 1
                let shouldLog = samplesSinceLog >= 5
                if shouldLog { samplesSinceLog = 0 }
                await self.captureStats(shouldLog: shouldLog)
            }
        }
        // Stored under the lock, and cancelled immediately if `close()` won the race - otherwise the
        // poller outlives the peer it is polling.
        let isClosedNow = stateLock.withLock { () -> Bool in
            guard !isClosed else { return true }
            statsTask?.cancel()
            statsTask = task
            return false
        }
        if isClosedNow { task.cancel() }
    }

    private func captureStats(shouldLog: Bool) async {
        guard let peerConnection = stateLock.withLock({ peerConnection }) else { return }
        let report: RTCStatisticsReport = await withCheckedContinuation { continuation in
            peerConnection.statistics { continuation.resume(returning: $0) }
        }
        var attributes: [String: String] = ["participantID": participantID.uuidString]
        var stats = OPNRemoteCoOpGuestStats()
        if let inbound = report.statistics.values.first(where: { $0.type == "inbound-rtp" && ($0.values["kind"] as? String) == "video" }) {
            let jitterDelay = (inbound.values["jitterBufferDelay"] as? NSNumber)?.doubleValue ?? 0
            let jitterEmitted = (inbound.values["jitterBufferEmittedCount"] as? NSNumber)?.intValue ?? 0
            let framesDecoded = (inbound.values["framesDecoded"] as? NSNumber)?.intValue ?? 0
            let now = Date()
            var averageJitterBufferMs = -1.0
            if let previous = previousInboundStats {
                let emittedDelta = jitterEmitted - previous.jitterBufferEmitted
                if emittedDelta > 0 {
                    averageJitterBufferMs = ((jitterDelay - previous.jitterBufferDelay) / Double(emittedDelta)) * 1_000
                }
                let elapsed = now.timeIntervalSince(previous.timestamp)
                if elapsed > 0 { stats.decodedFramesPerSecond = Double(framesDecoded - previous.framesDecoded) / elapsed }
            }
            previousInboundStats = (jitterDelay, jitterEmitted, framesDecoded, now)
            stats.jitterBufferMilliseconds = averageJitterBufferMs
            stats.decodeMillisecondsPerFrame = decodeMsPerFrame(inbound: inbound, framesDecoded: framesDecoded)
            stats.frameWidth = (inbound.values["frameWidth"] as? NSNumber)?.intValue ?? 0
            stats.frameHeight = (inbound.values["frameHeight"] as? NSNumber)?.intValue ?? 0
            stats.freezeCount = (inbound.values["freezeCount"] as? NSNumber)?.intValue ?? 0
            attributes["jitterBufferMsPerFrame"] = String(format: "%.1f", averageJitterBufferMs)
            // Target vs. actual: if the target is the deep one, the receiver chose the buffering
            // (timing estimate learned during a rough patch); if the target is small but the
            // actual is deep, frames genuinely arrive late.
            attributes["jitterBufferTargetMs"] = String(format: "%.1f", ((inbound.values["jitterBufferTargetDelay"] as? NSNumber)?.doubleValue ?? -1) * 1_000)
            attributes["jitterBufferMinimumMs"] = String(format: "%.1f", ((inbound.values["jitterBufferMinimumDelay"] as? NSNumber)?.doubleValue ?? -1) * 1_000)
            attributes["decodeMsPerFrame"] = String(format: "%.1f", stats.decodeMillisecondsPerFrame)
            attributes["decodedFps"] = String(format: "%.1f", stats.decodedFramesPerSecond)
            attributes["framesDecoded"] = String(framesDecoded)
            attributes["freezeCount"] = String(stats.freezeCount)
            attributes["frameWidth"] = String(stats.frameWidth)
            attributes["frameHeight"] = String(stats.frameHeight)
        }
        if let pair = report.statistics.values.first(where: { $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true }) {
            let rtt = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? -1
            stats.roundTripMilliseconds = rtt >= 0 ? rtt * 1_000 : -1
            attributes["rttMs"] = String(format: "%.1f", stats.roundTripMilliseconds)
        }
        onStats?(stats)
        guard shouldLog else { return }
        WebRTCMediaTelemetry.capture("webrtc.remote_coop.guest.inbound", level: .info, message: "Native Remote Co-Op guest inbound video.", attributes: attributes)
    }

    private func decodeMsPerFrame(inbound: RTCStatistics, framesDecoded: Int) -> Double {
        let decodeTime = (inbound.values["totalDecodeTime"] as? NSNumber)?.doubleValue ?? 0
        defer { previousDecode = (decodeTime, framesDecoded) }
        guard let previous = previousDecode, framesDecoded > previous.framesDecoded else { return -1 }
        return ((decodeTime - previous.decodeTime) / Double(framesDecoded - previous.framesDecoded)) * 1_000
    }

    // MARK: - SDP plumbing

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

    private func setLocalDescription(_ description: RTCSessionDescription) async throws {
        guard let peerConnection = stateLock.withLock({ peerConnection }) else { throw OPNRemoteCoOpHostPeerError.peerNotFound }
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

    private func createAnswer() async throws -> RTCSessionDescription {
        guard let peerConnection = stateLock.withLock({ peerConnection }) else { throw OPNRemoteCoOpHostPeerError.peerNotFound }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peerConnection.answer(for: constraints) { answer, error in
                if let answer {
                    continuation.resume(returning: answer)
                } else {
                    continuation.resume(throwing: OPNRemoteCoOpHostPeerError.negotiationFailed(error?.localizedDescription ?? "Unable to create the Remote Co-Op answer."))
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
}
