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

public struct NativeNVSTPerformanceSnapshot: Equatable, Sendable {
    public let available: Bool
    public let gameFramesPerSecond: Double
    public let streamFramesPerSecond: Double
    public let latencyMilliseconds: Double
    public let jitterMilliseconds: Double
    public let frameLoss: UInt64
    public let totalFrameLoss: UInt64
    public let packetLoss: UInt64
    public let totalPacketLoss: UInt64
    public let bitrateMegabitsPerSecond: Double
    public let bandwidthUtilizationPercent: Double
    public let resolution: String
    public let codec: String
    public let serverLocation: String

    public init(available: Bool,
                gameFramesPerSecond: Double,
                streamFramesPerSecond: Double,
                latencyMilliseconds: Double,
                jitterMilliseconds: Double,
                frameLoss: UInt64,
                totalFrameLoss: UInt64,
                packetLoss: UInt64,
                totalPacketLoss: UInt64,
                bitrateMegabitsPerSecond: Double,
                bandwidthUtilizationPercent: Double,
                resolution: String,
                codec: String,
                serverLocation: String) {
        self.available = available
        self.gameFramesPerSecond = gameFramesPerSecond
        self.streamFramesPerSecond = streamFramesPerSecond
        self.latencyMilliseconds = latencyMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.frameLoss = frameLoss
        self.totalFrameLoss = totalFrameLoss
        self.packetLoss = packetLoss
        self.totalPacketLoss = totalPacketLoss
        self.bitrateMegabitsPerSecond = bitrateMegabitsPerSecond
        self.bandwidthUtilizationPercent = bandwidthUtilizationPercent
        self.resolution = resolution
        self.codec = codec
        self.serverLocation = serverLocation
    }
}

public enum NativeNVSTTransportTermination: Equatable, Sendable {
    case remoteStopped(String)
    case failed(String)
}

public protocol NativeNVSTTransport: Sendable {
    func prepare() async throws -> NVSTNativeBridgeStatus
    func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection
    func send(_ event: UserInputEvent) async throws
    func togglePerformanceOverlay() async throws
    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot?
    func pause() async throws
    func disconnect() async
    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination>
}

public extension NativeNVSTTransport {
    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        nil
    }

    func pause() async throws {
        throw NativeNVSTError.notRunning
    }

    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        AsyncStream { $0.finish() }
    }
}

public enum NativeNVSTError: LocalizedError, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case sessionLimitReached
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
        case .sessionLimitReached:
            "GeForce NOW reports that another session is already active."
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
    private var terminalTask: Task<Void, Never>?
    private var cancelStartTask: Task<Void, Never>?
    private var reportContinuations: [UUID: AsyncStream<StreamReport>.Continuation] = [:]

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

    public func endEvents() -> AsyncStream<StreamReport> {
        let id = UUID()
        let pair = AsyncStream<StreamReport>.makeStream(bufferingPolicy: .bufferingNewest(1))
        reportContinuations[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.removeReportContinuation(id) }
        }
        return pair.stream
    }

    public func start(configuration: StreamLaunchConfiguration,
                      progress: (@Sendable (StreamProgress) async -> Void)? = nil) async throws -> StreamSessionDescriptor {
        try await withTaskCancellationHandler {
            try await startStreaming(configuration: configuration, progress: progress)
        } onCancel: {
            Task { await self.cancelStart() }
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
            if error as? NativeNVSTError == .sessionLimitReached {
                throw OpenNOWStreamSessionError.activeSessionConflict(StreamSessionConflict(
                    sessionID: allocation.session.id,
                    applicationID: allocation.session.applicationID,
                    serverAddress: allocation.session.serverAddress
                ))
            }
            try? await sessionProvider.finishSession(allocation.session, reason: Task.isCancelled ? .userRequested : .failed)
            if error is CancellationError || Task.isCancelled { throw error }
            WebRTCMediaTelemetry.capture("nvst.path.transport.error", level: .error, message: Self.message(for: error), attributes: ["sessionId": allocation.session.id])
            throw error
        }

        activeSession = allocation.session
        startedAt = .now
        state = .running(allocation.session)
        monitorTransportTermination()
        try await publishProgress(configuration: configuration, step: .connected, message: "Connected over native NVST.", isReady: true, progress: progress)
        WebRTCMediaTelemetry.capture("nvst.path.connected", level: .info, message: "Native NVST streaming path connected.", attributes: ["sessionId": allocation.session.id, "applicationID": allocation.session.applicationID])
        return allocation.session
    }

    public func send(_ event: UserInputEvent) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.send(event)
    }

    public func togglePerformanceOverlay() async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.togglePerformanceOverlay()
    }

    public func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard activeSession != nil else { return nil }
        return await transport.performanceSnapshot()
    }

    public func stop(reason: StreamEndReason = .userRequested, message: String = "Native NVST stream ended.") async throws -> StreamReport {
        if reason == .paused { return try await pause(message: message) }
        guard let activeSession else { throw NativeNVSTError.notRunning }
        terminalTask?.cancel()
        terminalTask = nil
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        startedAt = nil
        WebRTCMediaTelemetry.capture("nvst.path.stop", level: .info, message: message, attributes: ["sessionId": activeSession.id, "reason": reason.rawValue])
        await transport.disconnect()
        try await sessionProvider.finishSession(activeSession, reason: reason)
        await mediaSession.finish()
        let report = StreamReport(title: activeSession.title, success: reason != .failed, reason: reason, message: message, durationSeconds: durationSeconds, metadata: ["transport": "nvst"])
        state = .ended(report)
        publish(report)
        return report
    }

    public func pause(message: String = "Native NVST stream paused.") async throws -> StreamReport {
        guard let activeSession else { throw NativeNVSTError.notRunning }
        terminalTask?.cancel()
        terminalTask = nil
        let originalStartedAt = startedAt
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        startedAt = nil
        WebRTCMediaTelemetry.capture("nvst.path.pause", level: .info, message: message, attributes: ["sessionId": activeSession.id])
        do {
            try await transport.pause()
            try? await sessionProvider.finishSession(activeSession, reason: .paused)
            await mediaSession.finish()
            let report = StreamReport(title: activeSession.title, success: true, reason: .paused, message: message, durationSeconds: durationSeconds, metadata: ["transport": "nvst"])
            state = .ended(report)
            publish(report)
            return report
        } catch {
            self.activeSession = activeSession
            startedAt = originalStartedAt
            state = .running(activeSession)
            monitorTransportTermination()
            throw error
        }
    }

    public func cancelStart() async {
        if let cancelStartTask {
            await cancelStartTask.value
            return
        }
        let task = Task { [sessionProvider, transport] in
            await transport.disconnect()
            if let cancellable = sessionProvider as? any StreamSessionStartCancellable {
                await cancellable.cancelSessionStart()
            }
        }
        cancelStartTask = task
        await task.value
        cancelStartTask = nil
    }

    private func stopSessionIfCancelled(_ session: StreamSessionDescriptor) async throws {
        guard Task.isCancelled else { return }
        await transport.disconnect()
        try? await sessionProvider.finishSession(session, reason: .userRequested)
        throw CancellationError()
    }

    private func monitorTransportTermination() {
        terminalTask?.cancel()
        terminalTask = Task { [weak self, transport] in
            let events = await transport.terminalEvents()
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleTransportTermination(event)
                return
            }
        }
    }

    private func handleTransportTermination(_ termination: NativeNVSTTransportTermination) async {
        guard let activeSession else { return }
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        startedAt = nil
        terminalTask = nil
        let reason: StreamEndReason
        let message: String
        switch termination {
        case .remoteStopped(let value):
            reason = .remoteEnded
            message = value.isEmpty ? "Native NVST stream ended remotely." : value
        case .failed(let value):
            reason = .failed
            message = value.isEmpty ? "Native NVST transport failed." : value
        }
        await transport.disconnect()
        try? await sessionProvider.finishSession(activeSession, reason: reason)
        await mediaSession.finish()
        let report = StreamReport(title: activeSession.title, success: reason != .failed, reason: reason, message: message, durationSeconds: durationSeconds, metadata: ["transport": "nvst"])
        state = .ended(report)
        publish(report)
    }

    private func publish(_ report: StreamReport) {
        for continuation in reportContinuations.values {
            continuation.yield(report)
        }
    }

    private func removeReportContinuation(_ id: UUID) {
        reportContinuations[id] = nil
    }

    private func publishProgress(configuration: StreamLaunchConfiguration,
                                 step: StreamLaunchStep,
                                 message: String,
                                 isReady: Bool = false,
                                 progress: (@Sendable (StreamProgress) async -> Void)?) async throws {
        let value = StreamProgress(configuration: configuration, step: step, message: message, isReady: isReady)
        if isReady, let activeSession {
            state = .running(activeSession)
        } else {
            state = .starting(value)
        }
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
