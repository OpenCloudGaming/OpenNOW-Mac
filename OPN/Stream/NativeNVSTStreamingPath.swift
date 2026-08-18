import Foundation

public protocol NativeNVSTSessionProvider: Sendable {
    func startNativeNVSTSession(configuration: StreamLaunchConfiguration) async throws -> NativeNVSTSessionAllocation
    func recoverNativeNVSTSession(configuration: StreamLaunchConfiguration, session: StreamSessionDescriptor) async throws -> NativeNVSTSessionAllocation
    func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws
}

extension OpenNOWStreamSessionCoordinator: NativeNVSTSessionProvider {}

public extension NativeNVSTSessionProvider {
    func recoverNativeNVSTSession(configuration: StreamLaunchConfiguration, session: StreamSessionDescriptor) async throws -> NativeNVSTSessionAllocation {
        throw NativeNVSTError.transportFailed("Native NVST session recovery is unavailable.")
    }
}

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

public struct NativeNVSTTerminationValue: Equatable, Sendable {
    public let code: Int32
    public let name: String?

    public init(code: Int32, name: String? = nil) {
        self.code = code
        self.name = name
    }
}

public struct NativeNVSTTerminationReason: Equatable, Sendable {
    public let rawValue: UInt32
    public let resultName: String?

    public init(rawValue: UInt32, resultName: String? = nil) {
        self.rawValue = rawValue
        self.resultName = resultName
    }
}

public struct NativeNVSTSessionTermination: Equatable, Sendable {
    public let reason: NativeNVSTTerminationReason
    public let extendedResult: NativeNVSTTerminationValue
    public let isResumable: Bool
    public let isSessionAlive: Bool
    public let message: String

    public init(reason: NativeNVSTTerminationReason,
                extendedResult: NativeNVSTTerminationValue,
                isResumable: Bool,
                isSessionAlive: Bool,
                message: String) {
        self.reason = reason
        self.extendedResult = extendedResult
        self.isResumable = isResumable
        self.isSessionAlive = isSessionAlive
        self.message = message
    }

    public var permitsSameSessionRecovery: Bool {
        isResumable && isSessionAlive && NativeNVSTRecoveryPolicy.isTransient(reason) && NativeNVSTRecoveryPolicy.isTransient(extendedResult)
    }
}

public struct NativeNVSTTransportFailure: Equatable, Sendable {
    public enum RecoveryClassification: Equatable, Sendable {
        case transientNetwork
        case permanent
    }

    public let message: String
    public let result: NativeNVSTTerminationValue?
    public let recoveryClassification: RecoveryClassification

    public init(message: String,
                result: NativeNVSTTerminationValue? = nil,
                recoveryClassification: RecoveryClassification) {
        self.message = message
        self.result = result
        self.recoveryClassification = recoveryClassification
    }
}

public enum NativeNVSTTransportTermination: Equatable, Sendable {
    case sessionTerminated(NativeNVSTSessionTermination)
    case transportFailed(NativeNVSTTransportFailure)
}

public enum NativeNVSTRecoveryPolicy {
    private static let transientResults: Set<String> = [
        "NVB_R_ADDRESS_RESOLVE_FAILED",
        "NVB_R_CONNECT_FAILED",
        "NVB_R_CONNECTION_TIMEOUT",
        "NVB_R_DATA_RECEIVE_FAILURE",
        "NVB_R_DATA_RECEIVE_TIMEOUT",
        "NVB_R_DATA_SEND_FAILURE",
        "NVB_R_NETWORK_ERROR",
        "NVB_R_NETWORK_ERROR_UNKNOWN",
        "NVB_R_PEER_NO_RESPONSE",
        "NVB_R_SERVER_INTERNAL_TIMEOUT",
        "NVB_R_SOCKET_ERROR",
        "NVB_R_STREAMER_NETWORK_ERROR",
    ]

    public static func isTransient(_ value: NativeNVSTTerminationValue) -> Bool {
        guard let name = value.name else { return false }
        return transientResults.contains(name)
    }

    public static func isTransient(_ reason: NativeNVSTTerminationReason) -> Bool {
        guard let name = reason.resultName else { return false }
        return transientResults.contains(name)
    }

    public static func permitsRecovery(_ termination: NativeNVSTTransportTermination) -> Bool {
        switch termination {
        case .sessionTerminated(let info):
            info.permitsSameSessionRecovery
        case .transportFailed(let failure):
            failure.recoveryClassification == .transientNetwork && failure.result.map(isTransient) != false
        }
    }

}

public enum NativeNVSTAutomaticRecovery: Equatable, Sendable {
    case disabled
    case singleAttempt
}

public enum NativeNVSTDynamicStreamingMode: UInt32, Equatable, Sendable {
    case off = 0
    case preferFrameRate = 1
    case preferResolution = 2
    case on = 3
}

public struct NativeNVSTMicrophoneConfiguration: Equatable, Sendable {
    public let volume: Double
    public let voiceActivityEnabled: Bool
    public let captureRequested: Bool
    public let initiallyEnabled: Bool

    public init(volume: Double, voiceActivityEnabled: Bool, captureRequested: Bool, initiallyEnabled: Bool) {
        self.volume = min(max(volume.isFinite ? volume : 1, 0), 1)
        self.captureRequested = captureRequested
        self.voiceActivityEnabled = voiceActivityEnabled && captureRequested
        self.initiallyEnabled = initiallyEnabled && captureRequested
    }

    public static func settings(volume: Double, mode: String) -> NativeNVSTMicrophoneConfiguration {
        switch mode.lowercased() {
        case "voice-activity":
            NativeNVSTMicrophoneConfiguration(volume: volume, voiceActivityEnabled: true, captureRequested: true, initiallyEnabled: true)
        case "push-to-talk":
            NativeNVSTMicrophoneConfiguration(volume: volume, voiceActivityEnabled: false, captureRequested: true, initiallyEnabled: false)
        default:
            NativeNVSTMicrophoneConfiguration(volume: volume, voiceActivityEnabled: false, captureRequested: false, initiallyEnabled: false)
        }
    }
}

public struct NativeNVSTHapticCommand: Equatable, Sendable {
    public let playerIndex: Int
    public let lowFrequency: UInt16
    public let highFrequency: UInt16
    public let durationMilliseconds: UInt16

    public init(playerIndex: Int, lowFrequency: UInt16, highFrequency: UInt16, durationMilliseconds: UInt16) {
        self.playerIndex = playerIndex
        self.lowFrequency = lowFrequency
        self.highFrequency = highFrequency
        self.durationMilliseconds = durationMilliseconds
    }
}

public protocol NativeNVSTTransport: Sendable {
    func prepare() async throws -> NVSTNativeBridgeStatus
    func connect(allocation: NativeNVSTSessionAllocation, mediaReceiver: any NativeNVSTMediaReceiver) async throws -> NativeNVSTTransportConnection
    func send(_ event: UserInputEvent) async throws
    func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws
    func setMicrophoneEnabled(_ enabled: Bool) async throws
    func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws
    func togglePerformanceOverlay() async throws
    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot?
    func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws
    func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws
    func setL4SEnabled(_ enabled: Bool) async throws
    func updateGamepadTopology(_ topology: NativeWebRTCGamepadTopology) async throws
    func pause() async throws
    func disconnect() async
    func resetForRecovery() async
    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination>
    func diagnosticMetadata() async -> [String: String]
}

public extension NativeNVSTTransport {
    func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        throw NativeNVSTError.notRunning
    }

    func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        nil
    }

    func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws { throw NativeNVSTError.notRunning }
    func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws { throw NativeNVSTError.notRunning }
    func setL4SEnabled(_ enabled: Bool) async throws { throw NativeNVSTError.notRunning }
    func updateGamepadTopology(_ topology: NativeWebRTCGamepadTopology) async throws { throw NativeNVSTError.notRunning }
    func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {}

    func pause() async throws {
        throw NativeNVSTError.notRunning
    }

    func terminalEvents() async -> AsyncStream<NativeNVSTTransportTermination> {
        AsyncStream { $0.finish() }
    }

    func resetForRecovery() async { await disconnect() }
    func diagnosticMetadata() async -> [String: String] { [:] }
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
    private let automaticRecovery: NativeNVSTAutomaticRecovery
    private var state: StreamingPathState = .idle
    private var activeSession: StreamSessionDescriptor?
    private var activeAllocation: NativeNVSTSessionAllocation?
    private var launchConfiguration: StreamLaunchConfiguration?
    private var startedAt: ContinuousClock.Instant?
    private var terminalTask: Task<Void, Never>?
    private var cancelStartTask: Task<Void, Never>?
    private var reportContinuations: [UUID: AsyncStream<StreamReport>.Continuation] = [:]

    public init(sessionProvider: any NativeNVSTSessionProvider,
                transport: any NativeNVSTTransport,
                mediaSession: NativeNVSTMediaSession = NativeNVSTMediaSession(),
                automaticRecovery: NativeNVSTAutomaticRecovery = .disabled) {
        self.sessionProvider = sessionProvider
        self.transport = transport
        self.mediaSession = mediaSession
        self.automaticRecovery = automaticRecovery
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
                    serverAddress: allocation.session.serverAddress,
                    isResumable: allocation.isResume
                ))
            }
            try? await sessionProvider.finishSession(allocation.session, reason: Task.isCancelled ? .userRequested : .failed)
            if error is CancellationError || Task.isCancelled { throw error }
            WebRTCMediaTelemetry.capture("nvst.path.transport.error", level: .error, message: Self.message(for: error), attributes: ["sessionId": allocation.session.id])
            throw error
        }

        activeSession = allocation.session
        activeAllocation = allocation
        launchConfiguration = configuration
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

    public func sendAbsoluteMouseMove(_ event: NativeNVSTAbsoluteMouseEvent) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.sendAbsoluteMouseMove(event)
    }

    public func togglePerformanceOverlay() async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.togglePerformanceOverlay()
    }

    public func setMicrophoneEnabled(_ enabled: Bool) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setMicrophoneEnabled(enabled)
    }

    public func setMicrophoneConfiguration(_ configuration: NativeNVSTMicrophoneConfiguration) async throws {
        try await transport.setMicrophoneConfiguration(configuration)
    }

    public func performanceSnapshot() async -> NativeNVSTPerformanceSnapshot? {
        guard activeSession != nil else { return nil }
        return await transport.performanceSnapshot()
    }

    public func diagnosticMetadata() async -> [String: String] {
        await transport.diagnosticMetadata()
    }

    public func setMaximumBitrateKbps(_ bitrateKbps: UInt32) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setMaximumBitrateKbps(bitrateKbps)
    }

    public func setDynamicStreamingMode(_ mode: NativeNVSTDynamicStreamingMode) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setDynamicStreamingMode(mode)
    }

    public func setL4SEnabled(_ enabled: Bool) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.setL4SEnabled(enabled)
    }

    public func updateGamepadTopology(_ topology: NativeWebRTCGamepadTopology) async throws {
        guard activeSession != nil else { throw NativeNVSTError.notRunning }
        try await transport.updateGamepadTopology(topology)
    }

    public func stop(reason: StreamEndReason = .userRequested, message: String = "Native NVST stream ended.") async throws -> StreamReport {
        if reason == .paused { return try await pause(message: message) }
        guard let activeSession else { throw NativeNVSTError.notRunning }
        terminalTask?.cancel()
        terminalTask = nil
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        activeAllocation = nil
        launchConfiguration = nil
        startedAt = nil
        WebRTCMediaTelemetry.capture("nvst.path.stop", level: .info, message: message, attributes: ["sessionId": activeSession.id, "reason": reason.rawValue])
        let diagnostics = await transport.diagnosticMetadata()
        await transport.disconnect()
        try await sessionProvider.finishSession(activeSession, reason: reason)
        await mediaSession.finish()
        var metadata = ["transport": "nvst"]
        metadata.merge(diagnostics) { current, _ in current }
        let report = StreamReport(title: activeSession.title, success: reason != .failed, reason: reason, message: message, durationSeconds: durationSeconds, metadata: metadata)
        state = .ended(report)
        publish(report)
        return report
    }

    public func pause(message: String = "Native NVST stream paused.") async throws -> StreamReport {
        guard let activeSession else { throw NativeNVSTError.notRunning }
        terminalTask?.cancel()
        terminalTask = nil
        let originalStartedAt = startedAt
        let originalAllocation = activeAllocation
        let originalConfiguration = launchConfiguration
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        activeAllocation = nil
        launchConfiguration = nil
        startedAt = nil
        WebRTCMediaTelemetry.capture("nvst.path.pause", level: .info, message: message, attributes: ["sessionId": activeSession.id])
        do {
            try await transport.pause()
            try? await sessionProvider.finishSession(activeSession, reason: .paused)
            await mediaSession.finish()
            var metadata = ["transport": "nvst"]
            metadata.merge(await transport.diagnosticMetadata()) { current, _ in current }
            let report = StreamReport(title: activeSession.title, success: true, reason: .paused, message: message, durationSeconds: durationSeconds, metadata: metadata)
            state = .ended(report)
            publish(report)
            return report
        } catch {
            self.activeSession = activeSession
            activeAllocation = originalAllocation
            launchConfiguration = originalConfiguration
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
        terminalTask = nil
        if automaticRecovery == .singleAttempt,
           NativeNVSTRecoveryPolicy.permitsRecovery(termination), activeAllocation != nil, let launchConfiguration,
           await recover(session: activeSession, configuration: launchConfiguration) {
            return
        }
        guard self.activeSession?.id == activeSession.id else { return }
        let durationSeconds = streamDurationSeconds()
        self.activeSession = nil
        activeAllocation = nil
        launchConfiguration = nil
        startedAt = nil
        let reason: StreamEndReason
        let message: String
        switch termination {
        case .sessionTerminated(let info):
            reason = .remoteEnded
            message = info.message.isEmpty ? "Native NVST stream ended remotely." : info.message
        case .transportFailed(let failure):
            reason = .failed
            message = failure.message.isEmpty ? "Native NVST transport failed." : failure.message
        }
        let diagnostics = await transport.diagnosticMetadata()
        await transport.disconnect()
        try? await sessionProvider.finishSession(activeSession, reason: reason)
        await mediaSession.finish()
        var metadata = ["transport": "nvst"]
        metadata.merge(diagnostics) { current, _ in current }
        let report = StreamReport(title: activeSession.title, success: reason != .failed, reason: reason, message: message, durationSeconds: durationSeconds, metadata: metadata)
        state = .ended(report)
        publish(report)
    }

    private func recover(session: StreamSessionDescriptor, configuration: StreamLaunchConfiguration) async -> Bool {
        await transport.resetForRecovery()
        guard activeSession?.id == session.id, !Task.isCancelled else { return false }
        do {
            let refreshed = try await sessionProvider.recoverNativeNVSTSession(configuration: configuration, session: session)
            guard refreshed.session.id == session.id, refreshed.session.applicationID == session.applicationID else {
                throw NativeNVSTError.invalidSession("Native NVST recovery returned a different cloud session.")
            }
            guard activeSession?.id == session.id, !Task.isCancelled else { return false }
            _ = try await transport.connect(allocation: refreshed, mediaReceiver: mediaSession)
            guard activeSession?.id == session.id, !Task.isCancelled else {
                await transport.resetForRecovery()
                return false
            }
            activeAllocation = refreshed
            monitorTransportTermination()
            WebRTCMediaTelemetry.capture("nvst.path.recovered", level: .info, message: "Native NVST session recovered.", attributes: ["sessionId": session.id, "attempt": "1"])
            return true
        } catch {
            WebRTCMediaTelemetry.capture("nvst.path.recovery.failed", level: .warning, message: Self.message(for: error), attributes: ["sessionId": session.id, "attempt": "1"])
            await transport.resetForRecovery()
        }
        return false
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
