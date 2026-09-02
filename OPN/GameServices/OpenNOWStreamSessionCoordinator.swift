import Foundation

private final class OpenNOWSessionStopCompletion: @unchecked Sendable {
    let lock = NSLock()
    private var continuation: CheckedContinuation<Error?, Never>?

    init(continuation: CheckedContinuation<Error?, Never>) {
        self.continuation = continuation
    }

    func resume(_ error: Error?) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: error)
    }
}

public struct NativeNVSTSessionAllocation: Equatable, Sendable {
    public let session: StreamSessionDescriptor
    public let isResume: Bool
    public let signalingServer: String
    public let signalingURL: String
    public let signalingQueryParameters: String
    public let signalingHeaders: [String]
    public let streamingBaseURL: String
    public let mediaHost: String
    public let mediaPort: Int
    public let serverType: Int
    public let authTokenType: String
    public let authToken: String
    public let settingsJSON: String
    public let sessionInfoJSON: String
    public let rawSessionJSON: String

    public init(session: StreamSessionDescriptor,
                isResume: Bool = false,
                signalingServer: String,
                signalingURL: String,
                signalingQueryParameters: String,
                signalingHeaders: [String],
                streamingBaseURL: String,
                mediaHost: String,
                mediaPort: Int,
                serverType: Int,
                authTokenType: String = "",
                authToken: String = "",
                settingsJSON: String,
                sessionInfoJSON: String,
                rawSessionJSON: String) {
        self.session = session
        self.isResume = isResume
        self.signalingServer = signalingServer
        self.signalingURL = signalingURL
        self.signalingQueryParameters = signalingQueryParameters
        self.signalingHeaders = signalingHeaders
        self.streamingBaseURL = streamingBaseURL
        self.mediaHost = mediaHost
        self.mediaPort = max(0, mediaPort)
        self.serverType = serverType
        self.authTokenType = authTokenType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.settingsJSON = settingsJSON.isEmpty ? "{}" : settingsJSON
        self.sessionInfoJSON = sessionInfoJSON.isEmpty ? "{}" : sessionInfoJSON
        self.rawSessionJSON = rawSessionJSON.isEmpty ? "{}" : rawSessionJSON
    }
}

public final class OpenNOWStreamSessionCoordinator: StreamSessionProvider, StreamSignalingChannel, StreamSessionStartCancellable, @unchecked Sendable {
    static let maxBufferedIceCandidates = 120

    let lock = NSLock()
    var signaling: NVSTWebSocketSignalingClient?
    private var activeSession: StreamSessionDescriptor?
    var iceContinuation: AsyncStream<StreamIceCandidate>.Continuation?
    var pendingIceCandidates: [StreamIceCandidate] = []
    var remoteEndContinuation: AsyncStream<String>.Continuation?
    var pendingRemoteEndMessage: String?
    var offerContinuation: CheckedContinuation<StreamOffer, Error>?
    let sessionManager: any StreamSessionManaging
    let adPresenter: (any StreamSessionAdPresenter)?
    let progressHandler: (@Sendable (StreamProgress) -> Void)?

    init(sessionManager: any StreamSessionManaging = OPNSessionManager.shared, adPresenter: (any StreamSessionAdPresenter)? = nil, progressHandler: (@Sendable (StreamProgress) -> Void)? = nil) {
        self.sessionManager = sessionManager
        self.adPresenter = adPresenter
        self.progressHandler = progressHandler
    }

    public func startSession(configuration: StreamLaunchConfiguration) async throws -> StreamOffer {
        guard let launchAppId = OPNLaunchAppId.resolve(configuration.applicationID) else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("This game does not include a launchable GeForce NOW app id.")
        }
        let configuration = normalizedConfiguration(configuration, appId: launchAppId.stringValue)
        let launch = await prepareLaunch(configuration: configuration)
        try Task.checkCancellation()
        let sessionInfo = try await allocateSession(configuration: configuration, launch: launch)
        let descriptor = streamDescriptor(sessionInfo: sessionInfo, configuration: configuration)
        if Task.isCancelled {
            await releaseSession(descriptor, reason: .userRequested)
            throw CancellationError()
        }
        activeSession = descriptor
        do {
            let offer = try await connectSignaling(sessionInfo: sessionInfo, settings: launch.settings, descriptor: descriptor)
            if Task.isCancelled {
                await releaseSession(descriptor, reason: .userRequested)
                throw CancellationError()
            }
            return offer
        } catch {
            if error is CancellationError || Task.isCancelled {
                await releaseSession(descriptor, reason: .userRequested)
            }
            throw error
        }
    }

    public func startNativeNVSTSession(configuration: StreamLaunchConfiguration) async throws -> NativeNVSTSessionAllocation {
        guard let launchAppId = OPNLaunchAppId.resolve(configuration.applicationID) else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("This game does not include a launchable GeForce NOW app id.")
        }
        let configuration = normalizedConfiguration(configuration, appId: launchAppId.stringValue)
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: capabilities)
        guard profile.transportMode.value.caseInsensitiveCompare("nvst") == .orderedSame else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("Native NVST session requested while WebRTC transport is selected.")
        }
        let launch = await prepareLaunch(configuration: configuration)
        guard string(launch.settings["transportMode"]).caseInsensitiveCompare("nvst") == .orderedSame else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("Native NVST session requested while WebRTC transport is selected.")
        }
        let serverType: Int
        do {
            serverType = try await OPNStreamPreferences.fetchServerType(token: configuration.accessToken, streamingBaseUrl: launch.streamingBaseUrl) ?? 0
        } catch {
            try Task.checkCancellation()
            serverType = 0
        }
        try Task.checkCancellation()
        let sessionInfo = try await allocateSession(configuration: configuration, launch: launch)
        let descriptor = streamDescriptor(sessionInfo: sessionInfo, configuration: configuration)
        if Task.isCancelled {
            await releaseSession(descriptor, reason: .userRequested)
            throw CancellationError()
        }
        activeSession = descriptor
        startNativeSignalingSniffer(sessionInfo: sessionInfo, descriptor: descriptor)
        return NativeNVSTSessionAllocation(
            session: descriptor,
            isResume: configuration.resumesExistingSession || sessionInfo.isResume,
            signalingServer: sessionInfo.signalingServer,
            signalingURL: sessionInfo.signalingUrl,
            signalingQueryParameters: sessionInfo.signalingQueryParameters,
            signalingHeaders: sessionInfo.signalingHeaders,
            streamingBaseURL: sessionInfo.streamingBaseUrl,
            mediaHost: sessionInfo.mediaConnectionHost,
            mediaPort: sessionInfo.mediaConnectionPort,
            serverType: serverType,
            authTokenType: "JWT_GFN",
            authToken: configuration.accessToken,
            settingsJSON: jsonString(launch.settings),
            sessionInfoJSON: sessionInfo.rawJSON,
            rawSessionJSON: sessionInfo.rawSessionJSON
        )
    }

    public func recoverNativeNVSTSession(configuration: StreamLaunchConfiguration, session: StreamSessionDescriptor) async throws -> NativeNVSTSessionAllocation {
        let recoveryConfiguration = StreamLaunchConfiguration(
            id: configuration.id,
            title: configuration.title,
            applicationID: session.applicationID,
            accessToken: configuration.accessToken,
            accountLinked: configuration.accountLinked,
            selectedStore: configuration.selectedStore,
            resumeSessionID: session.id,
            resumeServer: session.serverAddress,
            metadata: configuration.metadata
        )
        return try await startNativeNVSTSession(configuration: recoveryConfiguration)
    }

    /// Teardown for a session this launch attempt may not own. A resumed session belongs to
    /// whichever device started it, so it is released locally (`.paused`, which reports nothing to
    /// CloudMatch) instead of being stopped — stopping it ended the other device's stream.
    func releaseSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async {
        let resumed = session.metadata["isResume"] == "true"
        try? await finishSession(session, reason: resumed ? .paused : reason)
    }

    public func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {
        let disconnected = lock.withLock { () -> NVSTWebSocketSignalingClient? in
            let client = signaling
            signaling = nil
            iceContinuation?.finish()
            iceContinuation = nil
            remoteEndContinuation?.finish()
            remoteEndContinuation = nil
            pendingIceCandidates.removeAll()
            pendingRemoteEndMessage = nil
            offerContinuation = nil
            if activeSession?.id == session.id { activeSession = nil }
            return client
        }
        if let disconnected { await disconnected.disconnect() }
        guard shouldReportFinishedSession(reason) else { return }
        let stopError = await stopCloudMatchSession(session)
        if stopError == nil { StreamSessionLimitStartStore.clear(sessionId: session.id) }
        await reportUDSEndOfSession(session, reason: reason)
        if let stopError { throw stopError }
    }

    public func lookupActiveSessionConflict(excludingSessionID sessionID: String, applicationID: String) async -> StreamSessionConflict? {
        // The server response ([[String: Any]]) is not Sendable, so resolve the blocker and
        // build the (Sendable) conflict from it locally and only hand that back.
        let (_, sessions, _) = await sessionManager.getActiveSessions()
        let candidates = sessions.filter { string($0["sessionId"]) != sessionID }
        guard !candidates.isEmpty,
              let blocker = sessionManager.selectSessionLimitReuseEntry(candidates, requestedAppId: Int(applicationID) ?? 0) else {
            return nil
        }
        let blockerSessionID = string(blocker["sessionId"])
        guard !blockerSessionID.isEmpty else {
            return nil
        }
        let blockerAppID = string(blocker["appId"])
        return StreamSessionConflict(
            sessionID: blockerSessionID,
            applicationID: blockerAppID.isEmpty ? applicationID : blockerAppID,
            serverAddress: string(blocker["serverIp"]),
            isResumable: bool(blocker["isResumable"])
        )
    }

    public func cancelSessionStart() async {
        let cancelled = lock.withLock { () -> (CheckedContinuation<StreamOffer, Error>?, StreamSessionDescriptor?, NVSTWebSocketSignalingClient?) in
            let client = signaling
            signaling = nil
            iceContinuation?.finish()
            iceContinuation = nil
            remoteEndContinuation?.finish()
            remoteEndContinuation = nil
            pendingIceCandidates.removeAll()
            pendingRemoteEndMessage = nil
            let continuation = offerContinuation
            offerContinuation = nil
            let session = activeSession
            activeSession = nil
            return (continuation, session, client)
        }
        cancelled.0?.resume(throwing: CancellationError())
        if let client = cancelled.2 { await client.disconnect() }
        if let session = cancelled.1 {
            await releaseSession(session, reason: .userRequested)
        }
    }

    public func sendAnswer(_ answer: StreamAnswer, for session: StreamSessionDescriptor) async throws {
        guard let signaling = lock.withLock({ self.signaling }) else {
            throw OpenNOWStreamSessionError.signalingUnavailable
        }
        await signaling.sendAnswerSdp(answer.sdp, nvstSdp: answer.metadata["nvstSdp"] ?? "")
    }

    public func sendLocalIceCandidate(_ candidate: StreamIceCandidate, for session: StreamSessionDescriptor) async throws {
        guard let signaling = lock.withLock({ self.signaling }) else {
            throw OpenNOWStreamSessionError.signalingUnavailable
        }
        await signaling.sendIceCandidate(NVSTIceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, usernameFragment: candidate.usernameFragment, isEndOfCandidates: candidate.isEndOfCandidates))
    }

    public func remoteIceCandidates(for session: StreamSessionDescriptor) async throws -> AsyncStream<StreamIceCandidate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(120)) { continuation in
            let buffered = lock.withLock { () -> [StreamIceCandidate] in
                iceContinuation = continuation
                let values = pendingIceCandidates
                pendingIceCandidates.removeAll()
                return values
            }
            for candidate in buffered {
                continuation.yield(candidate)
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.iceContinuation = nil }
            }
        }
    }

    public func remoteEndEvents(for session: StreamSessionDescriptor) async throws -> AsyncStream<String> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let buffered = lock.withLock { () -> String? in
                remoteEndContinuation = continuation
                let value = pendingRemoteEndMessage
                pendingRemoteEndMessage = nil
                return value
            }
            if let buffered {
                continuation.yield(buffered)
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.remoteEndContinuation = nil }
            }
        }
    }

    /// Diagnostic only: connects the WebSocket signaling read-only on the native path to capture
    /// the server's offer (which carries `nvstSdp`, the raw-SRTP video handoff), without answering
    /// or disturbing the Bifrost/Geronimo client. Gated on OPNProtocolDebug logging.
    private func startNativeSignalingSniffer(sessionInfo: AllocatedStreamSession, descriptor: StreamSessionDescriptor) {
        guard OPNProtocolDebug.loggingEnabled() else { return }
        Task { @MainActor in
            let client = NVSTWebSocketSignalingClient(
                signalingServer: sessionInfo.signalingServer,
                sessionId: descriptor.id,
                signalingUrl: sessionInfo.signalingUrl,
                queryParameters: sessionInfo.signalingQueryParameters,
                additionalSubprotocols: sessionInfo.signalingHeaders
            )
            client.onOffer = { offer in
                if !offer.nvstSdp.isEmpty {
                    let handoff = (try? JSONSerialization.jsonObject(with: Data(offer.nvstSdp.utf8))) ?? offer.nvstSdp
                    OPNProtocolDebug.logJSONObject(label: "nvst-signaling-handoff", object: handoff)
                } else {
                    OPNProtocolDebug.logJSONObject(label: "nvst-signaling-offer-empty", object: ["sdpLength": offer.sdp.count])
                }
            }
            client.onClosed = { _, _ in
                OPNProtocolDebug.logJSONObject(label: "nvst-signaling-sniffer-closed", object: ["sessionId": descriptor.id])
            }
            client.connect { [weak client] _, _ in
                // The sniffer holds no state; the client is retained for the offer's lifetime by
                // the URLSession it owns; nothing further is required here.
                _ = client
            }
        }
    }

    func offerMetadata(sessionInfo: AllocatedStreamSession, settingsJSON: String, descriptor: StreamSessionDescriptor) -> [String: String] {
        var metadata = descriptor.metadata
        metadata["sessionInfoJSON"] = sessionInfo.rawJSON
        metadata["settings"] = settingsJSON
        return metadata
    }

    func streamDescriptor(sessionInfo: AllocatedStreamSession, configuration: StreamLaunchConfiguration) -> StreamSessionDescriptor {
        let isSessionLimited = isFreeTierSession(configuration: configuration, sessionInfo: sessionInfo)
        var metadata = configuration.metadata
        metadata.merge([
            "accessToken": configuration.accessToken,
            "signalingUrl": sessionInfo.signalingUrl,
            "streamingBaseUrl": sessionInfo.streamingBaseUrl,
        ]) { _, new in new }
        if configuration.resumesExistingSession || sessionInfo.isResume {
            metadata["isResume"] = "true"
        }
        if isSessionLimited {
            metadata["sessionLimitSeconds"] = String(sessionLimitSeconds(sessionInfo: sessionInfo))
            metadata["sessionLimitReason"] = sessionInfo.remainingSessionLimitSeconds > 0 ? "serverBacked" : "freeTier"
            metadata["startedAtEpochSeconds"] = String(startedAtEpochSeconds(sessionInfo: sessionInfo, isSessionLimited: true))
        } else {
            metadata["startedAtEpochSeconds"] = String(Date().timeIntervalSince1970)
        }
        return StreamSessionDescriptor(
            id: sessionInfo.sessionId,
            applicationID: configuration.applicationID,
            serverAddress: sessionInfo.serverIp,
            title: configuration.title,
            metadata: metadata
        )
    }

    private func startedAtEpochSeconds(sessionInfo: AllocatedStreamSession, isSessionLimited: Bool) -> TimeInterval {
        guard isSessionLimited, !sessionInfo.sessionId.isEmpty else { return Date().timeIntervalSince1970 }
        if sessionInfo.remainingSessionLimitSeconds > 0 {
            return Date().timeIntervalSince1970 - Double(max(0, sessionLimitSeconds(sessionInfo: sessionInfo) - sessionInfo.remainingSessionLimitSeconds))
        }
        return StreamSessionLimitStartStore.startedAtEpochSeconds(for: sessionInfo.sessionId)
    }

    private func sessionLimitSeconds(sessionInfo: AllocatedStreamSession) -> Int {
        sessionInfo.remainingSessionLimitSeconds > 0 ? max(3600, sessionInfo.remainingSessionLimitSeconds) : 3600
    }

    private func isFreeTierSession(configuration: StreamLaunchConfiguration, sessionInfo: AllocatedStreamSession) -> Bool {
        if sessionInfo.remainingSessionLimitSeconds > 0 { return true }
        if sessionInfo.requiredAdGateObserved { return true }
        let tier = (configuration.metadata["membershipTier"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return tier == "free" || tier.contains("free")
    }

    private func shouldReportFinishedSession(_ reason: StreamEndReason) -> Bool {
        reason == .userRequested || reason == .completed || reason == .remoteEnded || reason == .failed
    }

    private func stopCloudMatchSession(_ session: StreamSessionDescriptor) async -> Error? {
        await withCheckedContinuation { continuation in
            let completion = OpenNOWSessionStopCompletion(continuation: continuation)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) {
                completion.resume(OpenNOWStreamSessionError.sessionStopFailed("Cloud session stop timed out."))
            }
            OPNActiveSessionService.stopSession(
                accessToken: session.metadata["accessToken"] ?? "",
                sessionId: session.id,
                serverIp: session.serverAddress,
                streamingBaseUrl: session.metadata["streamingBaseUrl"] ?? OPNStreamPreferences.loadSelectedStreamingBaseUrl()
            ) { success, error in
                if success || (session.metadata["accessToken"] ?? "").isEmpty {
                    completion.resume(nil)
                } else {
                    completion.resume(OpenNOWStreamSessionError.sessionStopFailed(error.isEmpty ? "Unable to stop stream session." : error))
                }
            }
        }
    }

    private func reportUDSEndOfSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async {
        let accessToken = session.metadata["accessToken"] ?? ""
        guard !accessToken.isEmpty, !session.id.isEmpty else { return }
        let payload = UDSReportPayload(
            source: .endOfSession,
            locale: OPNLocale.currentGFNLocale(),
            deviceId: OPNDeviceIdentity.stableCloudmatchDeviceId(),
            sessionId: session.id,
            sessionDurationInSeconds: sessionDurationSeconds(session)
        )
        let service = UDSService(configuration: .production, transport: UDSURLSessionTransport())
        do {
            _ = try await service.fetchEndOfSessionReport(payload: payload, accessToken: accessToken)
            OPNTelemetryRecorder.record(OPNTelemetryEvent(name: .udsEndOfSessionReport, parameters: ["status": "success", "reason": reason.rawValue]))
        } catch {
            OPNSentry.logWarningMessage(OPNSentry.formattedLogMessage(level: "warning", area: "UDS", message: "End-of-session report failed reason=\(reason.rawValue) error=\(error.localizedDescription)"))
            OPNTelemetryRecorder.record(OPNTelemetryEvent(name: .udsEndOfSessionReport, parameters: ["status": "failure", "reason": reason.rawValue, "error": error.localizedDescription]))
        }
    }

    private func sessionDurationSeconds(_ session: StreamSessionDescriptor) -> Int {
        let now = Date().timeIntervalSince1970
        let startedAt = Double(session.metadata["startedAtEpochSeconds"] ?? "") ?? now
        return max(0, Int(now - startedAt))
    }

    func makeSettings(configuration: StreamLaunchConfiguration) -> [String: Any] {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: capabilities)
        let resolved = WebRTCMediaStreamSettingsResolver.resolve(
            profile: webRTCMediaProfile(from: profile),
            capabilities: webRTCMediaCapabilities(from: capabilities),
            cloudVariables: webRTCMediaCloudVariables(from: OPNStreamPreferences.loadCachedCloudVariables())
        )
        return resolved.dictionary(gameLanguage: OPNLocale.currentGFNLocale(), accountLinked: configuration.accountLinked, selectedStore: configuration.selectedStore)
    }

    private func normalizedConfiguration(_ configuration: StreamLaunchConfiguration, appId: String) -> StreamLaunchConfiguration {
        StreamLaunchConfiguration(
            id: configuration.id,
            title: configuration.title,
            applicationID: appId,
            accessToken: configuration.accessToken,
            accountLinked: configuration.accountLinked,
            selectedStore: configuration.selectedStore,
            resumeSessionID: configuration.resumeSessionID,
            resumeServer: configuration.resumeServer,
            metadata: configuration.metadata
        )
    }

    func resumeOffer(_ offer: StreamOffer) {
        let continuation = lock.withLock { () -> CheckedContinuation<StreamOffer, Error>? in
            let value = offerContinuation
            offerContinuation = nil
            return value
        }
        continuation?.resume(returning: offer)
    }

    func resumeOffer(error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<StreamOffer, Error>? in
            let value = offerContinuation
            offerContinuation = nil
            return value
        }
        continuation?.resume(throwing: error)
    }
}

/// Coercions for the loosely typed CloudMatch dictionaries the coordinator threads around. They
/// carry no coordinator state, so they live out here and keep the class body to its size budget.
extension OpenNOWStreamSessionCoordinator {
    func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.isEmpty ? fallback : value }
        if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    func bool(_ value: Any?, fallback: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
        return fallback
    }
}
