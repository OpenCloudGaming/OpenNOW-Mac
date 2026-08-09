import Foundation

public protocol NativeNVSTSessionProvider: Sendable {
    func startNativeNVSTSession(configuration: StreamLaunchConfiguration) async throws -> NativeNVSTSessionAllocation
    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws
}

extension OpenNOWStreamSessionCoordinator: NativeNVSTSessionProvider {}

public struct NativeNVSTTransportConnection: Equatable, Sendable {
    public let session: StreamSessionDescriptor
    public let runtimeStatus: NVSTNativeBridgeStatus
    public let startedAt: Date

    public init(session: StreamSessionDescriptor, runtimeStatus: NVSTNativeBridgeStatus, startedAt: Date = Date()) {
        self.session = session
        self.runtimeStatus = runtimeStatus
        self.startedAt = startedAt
    }
}

public protocol NativeNVSTTransport: Sendable {
    func prepare() async throws -> NVSTNativeBridgeStatus
    func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection
    func send(_ event: UserInputEvent) async throws
    func disconnect() async
}

public enum NativeNVSTError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case invalidSession(String)
    case runtimeUnavailable(String)
    case privateABIUnavailable(String)
    case transportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Native NVST stream is already running."
        case .notRunning:
            "Native NVST stream is not running."
        case .invalidSession(let message), .runtimeUnavailable(let message), .privateABIUnavailable(let message), .transportFailed(let message):
            message
        }
    }
}

public actor NativeNVSTStreamingPath {
    private let sessionProvider: any NativeNVSTSessionProvider
    private let transport: any NativeNVSTTransport
    private let mediaSession: NativeNVSTMediaSession
    private var state: StreamingPathState = .idle
    private var activeSession: StreamSessionDescriptor?
    private var startedAt: ContinuousClock.Instant?

    public init(sessionProvider: any NativeNVSTSessionProvider,
                transport: any NativeNVSTTransport,
                mediaSession: NativeNVSTMediaSession = NativeNVSTMediaSession()) {
        self.sessionProvider = sessionProvider
        self.transport = transport
        self.mediaSession = mediaSession
    }

    public func currentState() -> StreamingPathState {
        state
    }

    public func videoFrames(bufferingPolicy: AsyncStream<NativeNVSTVideoFrame>.Continuation.BufferingPolicy = .bufferingNewest(120)) async -> AsyncStream<NativeNVSTVideoFrame> {
        await mediaSession.videoFrames(bufferingPolicy: bufferingPolicy)
    }

    public func audioFrames(bufferingPolicy: AsyncStream<NativeNVSTAudioFrame>.Continuation.BufferingPolicy = .bufferingNewest(240)) async -> AsyncStream<NativeNVSTAudioFrame> {
        await mediaSession.audioFrames(bufferingPolicy: bufferingPolicy)
    }

    public func start(configuration: StreamLaunchConfiguration,
                      progress: (@Sendable (StreamProgress) async -> Void)? = nil) async throws -> StreamSessionDescriptor {
        try await withTaskCancellationHandler {
            try await startStreaming(configuration: configuration, progress: progress)
        } onCancel: {
            Task { await self.cancelStartingSession() }
        }
    }

    private func startStreaming(configuration: StreamLaunchConfiguration,
                                progress: (@Sendable (StreamProgress) async -> Void)?) async throws -> StreamSessionDescriptor {
        guard activeSession == nil else { throw NativeNVSTError.alreadyRunning }
        WebRTCMediaTelemetry.capture("nvst.path.start", level: .info, message: "Starting native NVST streaming path.", attributes: ["configurationId": configuration.id.uuidString, "applicationID": configuration.applicationID])

        try Task.checkCancellation()
        try await publishProgress(configuration: configuration, step: .checkNetworkRoute, message: "Checking native NVST runtime...", progress: progress)
        do {
            _ = try await transport.prepare()
        } catch {
            WebRTCMediaTelemetry.capture("nvst.path.runtime.error", level: .error, message: Self.message(for: error), attributes: ["applicationID": configuration.applicationID])
            throw error
        }

        try Task.checkCancellation()
        try await publishProgress(configuration: configuration, step: .allocateCloudSession, message: "Allocating native NVST cloud session...", progress: progress)
        let allocation: NativeNVSTSessionAllocation
        do {
            allocation = try await sessionProvider.startNativeNVSTSession(configuration: configuration)
        } catch {
            if error is CancellationError || Task.isCancelled { throw error }
            WebRTCMediaTelemetry.capture("nvst.path.session_provider.error", level: .error, message: Self.message(for: error), attributes: ["applicationID": configuration.applicationID])
            throw error
        }

        do {
            try await stopSessionIfCancelled(allocation.session)
            try await publishProgress(configuration: configuration, step: .receiveStreamOffer, message: "Preparing native NVST transport...", progress: progress)
            try validate(allocation: allocation)
            try await publishProgress(configuration: configuration, step: .negotiateWebRTC, message: "Connecting native NVST secure RTSP transport...", progress: progress)
            _ = try await transport.connect(allocation: allocation, mediaReceiver: mediaSession)
            try await stopSessionIfCancelled(allocation.session)
        } catch {
            await transport.disconnect()
            await mediaSession.finish()
            try? await sessionProvider.finishSession(allocation.session, reason: Task.isCancelled ? .userRequested : .failed)
            if error is CancellationError || Task.isCancelled { throw error }
            WebRTCMediaTelemetry.capture("nvst.path.transport.error", level: .error, message: Self.message(for: error), attributes: ["sessionId": allocation.session.id])
            throw error
        }

        activeSession = allocation.session
        startedAt = .now
        state = .running(allocation.session)
        try await publishProgress(configuration: configuration, step: .connected, message: "Connected over native NVST.", isReady: true, progress: progress)
        WebRTCMediaTelemetry.capture("nvst.path.connected", level: .info, message: "Native NVST streaming path connected.", attributes: ["sessionId": allocation.session.id, "applicationID": allocation.session.applicationID])
        return allocation.session
    }

    public func send(_ event: UserInputEvent) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.send(event)
    }

    public func stop(reason: StreamEndReason = .userRequested, message: String = "Native NVST stream ended.") async throws -> StreamReport {
        guard let activeSession else { throw NativeNVSTError.notRunning }
        WebRTCMediaTelemetry.capture("nvst.path.stop", level: .info, message: message, attributes: ["sessionId": activeSession.id, "reason": reason.rawValue])
        await transport.disconnect()
        try await sessionProvider.finishSession(activeSession, reason: reason)
        await mediaSession.finish()
        let report = StreamReport(title: activeSession.title, success: reason != .failed, reason: reason, message: message, durationSeconds: streamDurationSeconds(), metadata: ["transport": "nvst"])
        self.activeSession = nil
        startedAt = nil
        state = .ended(report)
        return report
    }

    private func cancelStartingSession() async {
        await transport.disconnect()
        if let cancellable = sessionProvider as? any StreamSessionStartCancellable {
            await cancellable.cancelSessionStart()
        }
    }

    private func stopSessionIfCancelled(_ session: StreamSessionDescriptor) async throws {
        guard Task.isCancelled else { return }
        await transport.disconnect()
        try? await sessionProvider.finishSession(session, reason: .userRequested)
        throw CancellationError()
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

    private func validate(allocation: NativeNVSTSessionAllocation) throws {
        guard !allocation.session.id.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing a session id.") }
        guard !allocation.session.serverAddress.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing a server address.") }
        guard !allocation.signalingURL.isEmpty || !allocation.signalingServer.isEmpty else { throw NativeNVSTError.invalidSession("Native NVST session is missing signaling connection information.") }
    }

    private func streamDurationSeconds() -> Double {
        guard let startedAt else { return 0 }
        let duration = startedAt.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription, !description.isEmpty { return description }
        return error.localizedDescription.isEmpty ? "Native NVST stream failed." : error.localizedDescription
    }
}
