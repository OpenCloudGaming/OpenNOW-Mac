import Foundation

public protocol StreamSessionProvider: Sendable {
    func startSession(configuration: StreamLaunchConfiguration) async throws -> StreamOffer
    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws
}

public protocol WebRTCStreamTransport: Sendable {
    func connect(offer: StreamOffer, mediaReceiver: any MediaFrameReceiver) async throws -> StreamAnswer
    func addRemoteIceCandidate(_ candidate: StreamIceCandidate) async throws
    func send(_ event: UserInputEvent) async throws
    func disconnect() async
}

public protocol StreamSignalingChannel: Sendable {
    func sendAnswer(_ answer: StreamAnswer, for session: StreamSessionDescriptor) async throws
    func remoteIceCandidates(for session: StreamSessionDescriptor) async throws -> AsyncStream<StreamIceCandidate>
}

public actor WebRTCStreamingPath {
    private let sessionProvider: any StreamSessionProvider
    private let transport: any WebRTCStreamTransport
    private let signaling: (any StreamSignalingChannel)?
    private let mediaSession: WebRTCMediaSession
    private var state: StreamingPathState = .idle
    private var activeSession: StreamSessionDescriptor?
    private var startedAt: ContinuousClock.Instant?
    private var iceCandidateTask: Task<Void, Never>?

    public init(sessionProvider: any StreamSessionProvider,
                transport: any WebRTCStreamTransport,
                signaling: (any StreamSignalingChannel)? = nil,
                mediaSession: WebRTCMediaSession = WebRTCMediaSession()) {
        self.sessionProvider = sessionProvider
        self.transport = transport
        self.signaling = signaling
        self.mediaSession = mediaSession
    }

    public func currentState() -> StreamingPathState {
        state
    }

    public func mediaFrames(bufferingPolicy: AsyncStream<MediaFrame>.Continuation.BufferingPolicy = .bufferingNewest(120)) async -> AsyncStream<MediaFrame> {
        await mediaSession.mediaFrames(bufferingPolicy: bufferingPolicy)
    }

    public func start(configuration: StreamLaunchConfiguration,
                      progress: (@Sendable (StreamProgress) async -> Void)? = nil) async throws -> StreamSessionDescriptor {
        guard activeSession == nil else { throw StreamingPathError.alreadyRunning }
        WebRTCMediaTelemetry.capture("webrtc.path.start", level: .info, message: "Starting WebRTC streaming path.", attributes: ["configurationId": configuration.id.uuidString, "applicationID": configuration.applicationID])

        try await publishProgress(configuration: configuration, step: .checkNetworkRoute, message: "Checking network route...", progress: progress)
        try await publishProgress(configuration: configuration, step: .allocateCloudSession, message: "Allocating cloud session...", progress: progress)
        let offer: StreamOffer
        do {
            offer = try await sessionProvider.startSession(configuration: configuration)
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.path.session_provider.error", level: .error, message: error.localizedDescription, attributes: ["applicationID": configuration.applicationID])
            throw error
        }
        guard !offer.sdp.isEmpty else { throw StreamingPathError.invalidOffer }

        try await publishProgress(configuration: configuration, step: .receiveStreamOffer, message: "Received stream offer.", progress: progress)
        try await publishProgress(configuration: configuration, step: .negotiateWebRTC, message: "Negotiating WebRTC...", progress: progress)
        let answer: StreamAnswer
        do {
            answer = try await transport.connect(offer: offer, mediaReceiver: mediaSession)
        } catch {
            WebRTCMediaTelemetry.capture("webrtc.path.transport.error", level: .error, message: error.localizedDescription, attributes: ["sessionId": offer.session.id])
            throw error
        }
        if let signaling {
            do {
                try await signaling.sendAnswer(answer, for: offer.session)
            } catch {
                WebRTCMediaTelemetry.capture("webrtc.path.signaling_answer.error", level: .error, message: error.localizedDescription, attributes: ["sessionId": offer.session.id])
                throw error
            }
            startRemoteIceCandidateForwarding(session: offer.session, signaling: signaling)
        }

        let runningSession = StreamSessionDescriptor(
            id: offer.session.id,
            applicationID: offer.session.applicationID,
            serverAddress: offer.session.serverAddress,
            title: offer.session.title,
            metadata: offer.session.metadata.merging(offer.metadata) { current, _ in current }
        )
        activeSession = runningSession
        startedAt = .now
        state = .running(runningSession)
        try await publishProgress(configuration: configuration, step: .connected, message: "Connected.", isReady: true, progress: progress)
        WebRTCMediaTelemetry.capture("webrtc.path.connected", level: .info, message: "WebRTC streaming path connected.", attributes: ["sessionId": offer.session.id, "applicationID": offer.session.applicationID])
        return runningSession
    }

    public func send(_ event: UserInputEvent) async throws {
        guard activeSession != nil else { throw StreamingPathError.notRunning }
        try await transport.send(event)
    }

    public func addRemoteIceCandidate(_ candidate: StreamIceCandidate) async throws {
        guard activeSession != nil else { throw StreamingPathError.notRunning }
        try await transport.addRemoteIceCandidate(candidate)
    }

    public func stop(reason: StreamEndReason = .userRequested, message: String = "Stream ended.") async throws -> StreamReport {
        guard let activeSession else { throw StreamingPathError.notRunning }
        WebRTCMediaTelemetry.capture("webrtc.path.stop", level: .info, message: message, attributes: ["sessionId": activeSession.id, "reason": String(describing: reason)])
        iceCandidateTask?.cancel()
        iceCandidateTask = nil
        await transport.disconnect()
        try await sessionProvider.finishSession(activeSession, reason: reason)
        await mediaSession.finish()

        let report = StreamReport(
            title: activeSession.title,
            success: reason != .failed,
            reason: reason,
            message: message,
            durationSeconds: streamDurationSeconds()
        )
        self.activeSession = nil
        startedAt = nil
        state = .ended(report)
        return report
    }

    private func publishProgress(configuration: StreamLaunchConfiguration,
                                 step: StreamLaunchStep,
                                 message: String,
                                 isReady: Bool = false,
                                 progress: (@Sendable (StreamProgress) async -> Void)?) async throws {
        let value = StreamProgress(configuration: configuration, step: step, message: message, isReady: isReady)
        state = .starting(value)
        await progress?(value)
    }

    private func startRemoteIceCandidateForwarding(session: StreamSessionDescriptor, signaling: any StreamSignalingChannel) {
        iceCandidateTask?.cancel()
        iceCandidateTask = Task { [transport] in
            do {
                let candidates = try await signaling.remoteIceCandidates(for: session)
                for await candidate in candidates {
                    try await transport.addRemoteIceCandidate(candidate)
                    WebRTCMediaTelemetry.record("webrtc.media.remote_ice_candidate.count", kind: .counter, value: 1, attributes: ["sessionId": session.id])
                }
            } catch {
                WebRTCMediaTelemetry.capture("webrtc.path.remote_ice.error", level: .warning, message: error.localizedDescription, attributes: ["sessionId": session.id])
                return
            }
        }
    }

    private func streamDurationSeconds() -> Double {
        guard let startedAt else { return 0 }
        let duration = startedAt.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
