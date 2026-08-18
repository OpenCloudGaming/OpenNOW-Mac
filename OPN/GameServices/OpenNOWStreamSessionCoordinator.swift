import Foundation

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
    private static let maxBufferedIceCandidates = 120

    private let lock = NSLock()
    private var signaling: NVSTWebSocketSignalingClient?
    private var activeSession: StreamSessionDescriptor?
    private var iceContinuation: AsyncStream<StreamIceCandidate>.Continuation?
    private var pendingIceCandidates: [StreamIceCandidate] = []
    private var remoteEndContinuation: AsyncStream<String>.Continuation?
    private var pendingRemoteEndMessage: String?
    private var offerContinuation: CheckedContinuation<StreamOffer, Error>?
    private let adPresenter: (any StreamSessionAdPresenter)?
    private let progressHandler: (@Sendable (StreamProgress) -> Void)?

    public init(adPresenter: (any StreamSessionAdPresenter)? = nil, progressHandler: (@Sendable (StreamProgress) -> Void)? = nil) {
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
            try? await finishSession(descriptor, reason: .userRequested)
            throw CancellationError()
        }
        activeSession = descriptor
        do {
            let offer = try await connectSignaling(sessionInfo: sessionInfo, settings: launch.settings, descriptor: descriptor)
            if Task.isCancelled {
                try? await finishSession(descriptor, reason: .userRequested)
                throw CancellationError()
            }
            return offer
        } catch {
            if error is CancellationError || Task.isCancelled {
                try? await finishSession(descriptor, reason: .userRequested)
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
            try? await finishSession(descriptor, reason: .userRequested)
            throw CancellationError()
        }
        activeSession = descriptor
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

    public func finishSession(_ session: StreamSessionDescriptor, reason: StreamEndReason) async throws {
        lock.withLock {
            signaling?.disconnect()
            signaling = nil
            iceContinuation?.finish()
            iceContinuation = nil
            remoteEndContinuation?.finish()
            remoteEndContinuation = nil
            pendingIceCandidates.removeAll()
            pendingRemoteEndMessage = nil
            offerContinuation = nil
            if activeSession?.id == session.id { activeSession = nil }
        }
        guard shouldReportFinishedSession(reason) else { return }
        let stopError = await stopCloudMatchSession(session)
        if stopError == nil { StreamSessionLimitStartStore.clear(sessionId: session.id) }
        await reportUDSEndOfSession(session, reason: reason)
        if let stopError { throw stopError }
    }

    public func cancelSessionStart() async {
        let cancelled = lock.withLock { () -> (CheckedContinuation<StreamOffer, Error>?, StreamSessionDescriptor?) in
            signaling?.disconnect()
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
            return (continuation, session)
        }
        cancelled.0?.resume(throwing: CancellationError())
        if let session = cancelled.1 {
            try? await finishSession(session, reason: .userRequested)
        }
    }

    public func sendAnswer(_ answer: StreamAnswer, for session: StreamSessionDescriptor) async throws {
        guard let signaling = lock.withLock({ self.signaling }) else {
            throw OpenNOWStreamSessionError.signalingUnavailable
        }
        signaling.sendAnswerSdp(answer.sdp, nvstSdp: answer.metadata["nvstSdp"] ?? "")
    }

    public func sendLocalIceCandidate(_ candidate: StreamIceCandidate, for session: StreamSessionDescriptor) async throws {
        guard let signaling = lock.withLock({ self.signaling }) else {
            throw OpenNOWStreamSessionError.signalingUnavailable
        }
        signaling.sendIceCandidate(NVSTIceCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex, usernameFragment: candidate.usernameFragment, isEndOfCandidates: candidate.isEndOfCandidates))
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

    private func allocateSession(configuration: StreamLaunchConfiguration, launch: PreparedStreamLaunch) async throws -> AllocatedStreamSession {
        OPNSessionManager.shared.setAccessToken(configuration.accessToken)
        OPNSessionManager.shared.setStreamingBaseUrl(launch.streamingBaseUrl)

        if configuration.resumesExistingSession {
            let claimed = try await claimSession(configuration: configuration, settings: launch.settings)
            return try await waitForReadySession(claimed, configuration: configuration)
        }

        let created = try await createSession(configuration: configuration, settings: launch.settings)
        do {
            return try await waitForReadySession(created, configuration: configuration)
        } catch {
            let descriptor = streamDescriptor(sessionInfo: created, configuration: configuration)
            try? await finishSession(descriptor, reason: Task.isCancelled ? .userRequested : .failed)
            throw error
        }
    }

    private func createSession(configuration: StreamLaunchConfiguration, settings: [String: Any]) async throws -> AllocatedStreamSession {
        return try await withCheckedThrowingContinuation { continuation in
            OPNSessionManager.shared.createSession(appId: configuration.applicationID, internalTitle: configuration.title.isEmpty ? "OpenNOW" : configuration.title, settings: settings) { success, info, error in
                if success {
                    continuation.resume(returning: AllocatedStreamSession(info))
                } else if info["isSessionLimitConflict"] as? Bool == true {
                    let applicationID = self.string(info["appId"])
                    continuation.resume(throwing: OpenNOWStreamSessionError.activeSessionConflict(StreamSessionConflict(
                        sessionID: self.string(info["sessionId"]),
                        applicationID: applicationID.isEmpty ? configuration.applicationID : applicationID,
                        serverAddress: self.string(info["serverIp"]),
                        isResumable: self.bool(info["isResumable"])
                    )))
                } else {
                    continuation.resume(throwing: OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to allocate stream session." : error))
                }
            }
        }
    }

    private func claimSession(configuration: StreamLaunchConfiguration, settings: [String: Any]) async throws -> AllocatedStreamSession {
        try await withCheckedThrowingContinuation { continuation in
            OPNSessionManager.shared.claimSession(sessionId: configuration.resumeSessionID, serverIp: configuration.resumeServer, appId: configuration.applicationID, settings: settings, recoveryMode: false) { success, info, error in
                if success {
                    continuation.resume(returning: AllocatedStreamSession(info))
                } else {
                    continuation.resume(throwing: OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to resume stream session." : error))
                }
            }
        }
    }

    private func waitForReadySession(_ initial: AllocatedStreamSession, configuration: StreamLaunchConfiguration) async throws -> AllocatedStreamSession {
        if initial.isReady { return initial }
        guard !initial.sessionId.isEmpty, !initial.serverIp.isEmpty else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("Cloud session is missing session id or server address.")
        }

        var attempts = 0
        var lastPollWasPendingProgress = initial.isPendingProgress
        var latest = initial
        var requiredAdGateObserved = initial.requiredAdGateObserved
        var completedAdIds: Set<String> = []
        publishAllocationProgress(latest, configuration: configuration)
        while !latest.isReady {
            try Task.checkCancellation()
            if let ad = latest.pendingAd, !completedAdIds.contains(ad.adId) {
                requiredAdGateObserved = true
                latest = latest.markingRequiredAdGateObserved()
                publishAllocationProgress(latest, configuration: configuration, overrideMessage: "Playing sponsored message before your free-tier session continues...")
                latest = try await playRequiredAd(ad, session: latest)
                latest = latest.markingRequiredAdGateObserved()
                completedAdIds.insert(ad.adId)
                attempts = 0
                lastPollWasPendingProgress = latest.isPendingProgress
                publishAllocationProgress(latest, configuration: configuration)
                continue
            }
            if attempts >= 60, !lastPollWasPendingProgress {
                throw OpenNOWStreamSessionError.sessionAllocationFailed("Session poll timeout")
            }
            if attempts >= 60, lastPollWasPendingProgress { attempts = 0 }
            attempts += 1
            try await Task.sleep(nanoseconds: pollDelayNanoseconds(attempt: attempts))
            latest = try await pollSession(sessionId: initial.sessionId, serverIp: initial.serverIp)
            if latest.status > 3, ![4, 5, 6].contains(latest.status) {
                throw OpenNOWStreamSessionError.sessionAllocationFailed("Session in terminal error state")
            }
            if requiredAdGateObserved { latest = latest.markingRequiredAdGateObserved() }
            lastPollWasPendingProgress = latest.isPendingProgress
            publishAllocationProgress(latest, configuration: configuration)
        }
        if requiredAdGateObserved { latest = latest.markingRequiredAdGateObserved() }
        return latest
    }

    private func playRequiredAd(_ ad: AllocatedSessionAd, session: AllocatedStreamSession) async throws -> AllocatedStreamSession {
        guard !ad.mediaUrl.isEmpty else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("GeForce NOW requires an ad before launch, but no playable ad media was returned.")
        }
        guard let adPresenter else {
            throw OpenNOWStreamSessionError.sessionAllocationFailed("GeForce NOW requires an ad before launch, but the loading screen ad player is not available.")
        }
        let startedSession = try await reportSessionAd(session: session, ad: ad, action: "start", watchedTimeInMs: -1, cancelReason: "")
        let playbackSession = startedSession.sessionId.isEmpty ? session : startedSession
        do {
            let watchedTimeInMs = try await adPresenter.playRequiredSessionAd(ad.presentation)
            let updated = try await reportSessionAd(session: playbackSession, ad: ad, action: "finish", watchedTimeInMs: watchedTimeInMs, cancelReason: "")
            return updated.sessionId.isEmpty ? playbackSession : updated
        } catch {
            _ = try? await reportSessionAd(session: playbackSession, ad: ad, action: "cancel", watchedTimeInMs: -1, cancelReason: "playback_failed")
            throw error
        }
    }

    private func publishAllocationProgress(_ session: AllocatedStreamSession, configuration: StreamLaunchConfiguration, overrideMessage: String = "") {
        guard let progressHandler else { return }
        progressHandler(StreamProgress(
            title: configuration.title.isEmpty ? "GeForce NOW" : configuration.title,
            message: overrideMessage.isEmpty ? allocationProgressMessage(session) : overrideMessage,
            steps: StreamLaunchStep.allCases.map(\.title),
            currentStepIndex: StreamLaunchStep.allocateCloudSession.rawValue,
            isReady: session.isReady,
            queuePosition: session.queuePosition > 0 ? session.queuePosition : nil
        ))
    }

    private func allocationProgressMessage(_ session: AllocatedStreamSession) -> String {
        if session.queuePosition > 0 { return "Queue position: \(session.queuePosition)" }
        if session.adsRequired { return "Preparing sponsored message before your free-tier session continues..." }
        if session.seatSetupStep > 0 { return "Setting up your cloud gaming rig..." }
        return "Allocating cloud session..."
    }

    private func reportSessionAd(session: AllocatedStreamSession, ad: AllocatedSessionAd, action: String, watchedTimeInMs: Int, cancelReason: String) async throws -> AllocatedStreamSession {
        try await withCheckedThrowingContinuation { continuation in
            OPNSessionManager.shared.reportSessionAd(session: session.reportableSession, adId: ad.adId, action: action, watchedTimeInMs: watchedTimeInMs, pausedTimeInMs: -1, cancelReason: cancelReason) { success, info, error in
                if success {
                    continuation.resume(returning: AllocatedStreamSession(info))
                } else {
                    continuation.resume(throwing: OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to update required ad state." : error))
                }
            }
        }
    }

    private func pollSession(sessionId: String, serverIp: String) async throws -> AllocatedStreamSession {
        try await withCheckedThrowingContinuation { continuation in
            OPNSessionManager.shared.pollSession(sessionId: sessionId, serverIp: serverIp) { success, info, error in
                if success {
                    continuation.resume(returning: AllocatedStreamSession(info))
                } else {
                    continuation.resume(throwing: OpenNOWStreamSessionError.sessionAllocationFailed(error.isEmpty ? "Unable to poll stream session." : error))
                }
            }
        }
    }

    private func pollDelayNanoseconds(attempt: Int) -> UInt64 {
        if attempt <= 12 { return 300_000_000 }
        if attempt <= 20 { return 500_000_000 }
        return 1_000_000_000
    }

    private func prepareLaunch(configuration: StreamLaunchConfiguration) async -> PreparedStreamLaunch {
        let baseSettings = makeSettings(configuration: configuration)
        let cloudVariables = await fetchCloudVariables(configuration: configuration)
        var settings = settingsByApplyingCloudVariables(baseSettings, variables: cloudVariables)
        let requestedMaxBitrateMbps = int(settings["maxBitrateMbps"])
        let preflight = await runNetworkPreflight(token: configuration.accessToken, requestedMaxBitrateMbps: requestedMaxBitrateMbps)
        if preflight.serverReportedWarning || !preflight.continueRecommended || !preflight.warningMessage.isEmpty {
            OPNTelemetryRecorder.record(OPNTelemetryEvent(name: .networkTest, parameters: [
                "status": "warning",
                "continued": "true",
                "message": preflight.warningMessage.isEmpty ? "Network preflight reported a warning. Launch will continue." : preflight.warningMessage,
            ]))
        }
        settings["networkTestSessionId"] = preflight.networkTestSessionId
        settings["networkType"] = preflight.networkType
        settings["networkLatencyMs"] = preflight.latencyMs >= 0 ? String(preflight.latencyMs) : "Unknown"
        if preflight.maxPacketSize >= 512 { settings["maxPacketSize"] = preflight.maxPacketSize }
        if preflight.recommendedMaxBitrateMbps > 0 {
            settings["maxBitrateMbps"] = min(int(settings["maxBitrateMbps"]), preflight.recommendedMaxBitrateMbps)
        }
        let streamingBaseUrl = preflight.streamingBaseUrl.isEmpty ? OPNStreamPreferences.loadSelectedStreamingBaseUrl(forGame: configuration.applicationID) : preflight.streamingBaseUrl
        return PreparedStreamLaunch(settings: settings, streamingBaseUrl: streamingBaseUrl)
    }

    private func fetchCloudVariables(configuration: StreamLaunchConfiguration) async -> OPNStreamCloudVariables {
        await withCheckedContinuation { continuation in
            OPNStreamPreferences.fetchCloudVariables(token: configuration.accessToken, userId: configuration.metadata["userId"] ?? "", idpId: configuration.metadata["idpId"] ?? "") { variables in
                continuation.resume(returning: variables)
            }
        }
    }

    private func runNetworkPreflight(token: String, requestedMaxBitrateMbps: Int) async -> OPNStreamNetworkPreflightResult {
        await withCheckedContinuation { continuation in
            OPNStreamPreferences.runNetworkPreflight(
                token: token,
                providerStreamingBaseUrl: OPNGameService.shared.providerStreamingBaseURL(),
                requestedMaxBitrateMbps: requestedMaxBitrateMbps,
                completion: { preflight in continuation.resume(returning: preflight) }
            )
        }
    }

    private func settingsByApplyingCloudVariables(_ settings: [String: Any], variables: OPNStreamCloudVariables) -> [String: Any] {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let resolved = WebRTCMediaStreamSettingsResolver.resolve(
            profile: webRTCMediaProfile(from: settings),
            capabilities: webRTCMediaCapabilities(from: capabilities),
            cloudVariables: webRTCMediaCloudVariables(from: variables),
            libWebRTCAvailable: true
        )
        var result = settings
        result.merge(resolved.dictionary(gameLanguage: string(settings["gameLanguage"], fallback: OPNLocale.currentGFNLocale()), accountLinked: bool(settings["accountLinked"], fallback: true), selectedStore: string(settings["selectedStore"]))) { _, new in new }
        return result
    }

    private func connectSignaling(sessionInfo: AllocatedStreamSession, settings: [String: Any], descriptor: StreamSessionDescriptor) async throws -> StreamOffer {
        try await withCheckedThrowingContinuation { continuation in
            let client = NVSTWebSocketSignalingClient(
                signalingServer: sessionInfo.signalingServer,
                sessionId: descriptor.id,
                signalingUrl: sessionInfo.signalingUrl,
                queryParameters: sessionInfo.signalingQueryParameters,
                additionalSubprotocols: sessionInfo.signalingHeaders
            )
            let settingsJSON = jsonString(settings)
            client.onOffer = { [weak self] sessionOffer in
                guard let self else { return }
                let metadata = self.offerMetadata(sessionInfo: sessionInfo, settingsJSON: settingsJSON, descriptor: descriptor)
                    .merging([
                        "nvstSdp": sessionOffer.nvstSdp,
                        "nvstServerOverrides": sessionOffer.nvstServerOverrides,
                    ]) { current, _ in current }
                    .filter { !$0.value.isEmpty }
                let offer = StreamOffer(session: descriptor, sdp: sessionOffer.sdp, metadata: metadata)
                self.resumeOffer(offer)
            }
            client.onIceCandidate = { [weak self] candidate in
                guard let self else { return }
                self.handleRemoteIceCandidate(StreamIceCandidate(
                    sdp: candidate.candidate,
                    sdpMid: candidate.sdpMid,
                    sdpMLineIndex: candidate.sdpMLineIndex,
                    usernameFragment: candidate.usernameFragment,
                    isEndOfCandidates: candidate.isEndOfCandidates
                ))
            }
            client.onClosed = { [weak self] clean, reason in
                guard let self else { return }
                let isWaitingForOffer = self.lock.withLock { self.offerContinuation != nil }
                guard !clean || isWaitingForOffer else { return }
                if !isWaitingForOffer, Self.isRemoteEndReason(reason) {
                    self.handleRemoteEnd(reason.isEmpty ? "Stream ended by remote peer." : reason)
                    return
                }
                self.resumeOffer(error: OpenNOWStreamSessionError.signalingFailed(reason.isEmpty ? "Signaling connection closed before receiving an offer." : reason))
            }

            lock.withLock {
                signaling = client
                offerContinuation = continuation
            }
            client.connect { [weak self] success, error in
                guard let self else { return }
                if success {
                    self.startOfferTimeout(client: client, descriptor: descriptor)
                    return
                }
                self.resumeOffer(error: OpenNOWStreamSessionError.signalingFailed(error.isEmpty ? "Unable to connect signaling." : error))
            }
        }
    }

    private func startOfferTimeout(client: NVSTWebSocketSignalingClient, descriptor: StreamSessionDescriptor) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20.0) { [weak self, weak client] in
            guard let self, let client else { return }
            let shouldFail = self.lock.withLock { self.signaling === client && self.offerContinuation != nil }
            guard shouldFail else { return }
            client.disconnect()
            self.resumeOffer(error: OpenNOWStreamSessionError.signalingFailed("Signaling connected but no stream offer was received within 20 seconds for session \(descriptor.id)."))
        }
    }

    private func handleRemoteIceCandidate(_ candidate: StreamIceCandidate) {
        guard !candidate.sdp.isEmpty || candidate.isEndOfCandidates else { return }
        lock.withLock {
            if let iceContinuation {
                iceContinuation.yield(candidate)
                return
            }
            pendingIceCandidates.append(candidate)
            if pendingIceCandidates.count > Self.maxBufferedIceCandidates {
                pendingIceCandidates.removeFirst(pendingIceCandidates.count - Self.maxBufferedIceCandidates)
            }
        }
    }

    private func handleRemoteEnd(_ message: String) {
        lock.withLock {
            if let remoteEndContinuation {
                remoteEndContinuation.yield(message)
                remoteEndContinuation.finish()
                self.remoteEndContinuation = nil
            } else {
                pendingRemoteEndMessage = message
            }
        }
    }

    private static func isRemoteEndReason(_ reason: String) -> Bool {
        reason.contains("peerRemoved") || reason.contains("BYE")
    }

    private func offerMetadata(sessionInfo: AllocatedStreamSession, settingsJSON: String, descriptor: StreamSessionDescriptor) -> [String: String] {
        var metadata = descriptor.metadata
        metadata["sessionInfoJSON"] = sessionInfo.rawJSON
        metadata["settings"] = settingsJSON
        return metadata
    }

    private func streamDescriptor(sessionInfo: AllocatedStreamSession, configuration: StreamLaunchConfiguration) -> StreamSessionDescriptor {
        let isSessionLimited = isFreeTierSession(configuration: configuration, sessionInfo: sessionInfo)
        var metadata = configuration.metadata
        metadata.merge([
            "accessToken": configuration.accessToken,
            "signalingUrl": sessionInfo.signalingUrl,
            "streamingBaseUrl": sessionInfo.streamingBaseUrl,
        ]) { _, new in new }
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
            OPNActiveSessionService.stopSession(
                accessToken: session.metadata["accessToken"] ?? "",
                sessionId: session.id,
                serverIp: session.serverAddress,
                streamingBaseUrl: session.metadata["streamingBaseUrl"] ?? OPNStreamPreferences.loadSelectedStreamingBaseUrl()
            ) { success, error in
                if success || (session.metadata["accessToken"] ?? "").isEmpty {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: OpenNOWStreamSessionError.sessionStopFailed(error.isEmpty ? "Unable to stop stream session." : error))
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

    private func makeSettings(configuration: StreamLaunchConfiguration) -> [String: Any] {
        let capabilities = OPNStreamPreferences.loadDeviceCapabilities()
        let profile = OPNStreamPreferences.launchProfile(forGame: configuration.applicationID, capabilities: capabilities)
        let resolved = WebRTCMediaStreamSettingsResolver.resolve(
            profile: webRTCMediaProfile(from: profile),
            capabilities: webRTCMediaCapabilities(from: capabilities),
            cloudVariables: webRTCMediaCloudVariables(from: OPNStreamPreferences.loadCachedCloudVariables()),
            libWebRTCAvailable: true
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

    private func resumeOffer(_ offer: StreamOffer) {
        let continuation = lock.withLock { () -> CheckedContinuation<StreamOffer, Error>? in
            let value = offerContinuation
            offerContinuation = nil
            return value
        }
        continuation?.resume(returning: offer)
    }

    private func resumeOffer(error: Error) {
        let continuation = lock.withLock { () -> CheckedContinuation<StreamOffer, Error>? in
            let value = offerContinuation
            offerContinuation = nil
            return value
        }
        continuation?.resume(throwing: error)
    }

    private func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.isEmpty ? fallback : value }
        if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    private func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private func bool(_ value: Any?, fallback: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
        return fallback
    }
}

private struct PreparedStreamLaunch {
    let settings: [String: Any]
    let streamingBaseUrl: String
}

private enum StreamSessionLimitStartStore {
    private static let lock = NSLock()
    private static let key = "OpenNOW.Stream.SessionLimitStartedAtEpochSeconds"
    private static let maxStoredAgeSeconds: TimeInterval = 24 * 60 * 60

    static func startedAtEpochSeconds(for sessionId: String, now: Date = Date()) -> TimeInterval {
        lock.withLock {
            let nowEpoch = now.timeIntervalSince1970
            var starts = storedStarts(nowEpoch: nowEpoch)
            if let existing = starts[sessionId], existing > 0 {
                persist(starts)
                return existing
            }
            starts[sessionId] = nowEpoch
            persist(starts)
            return nowEpoch
        }
    }

    static func clear(sessionId: String) {
        guard !sessionId.isEmpty else { return }
        lock.withLock {
            var starts = storedStarts(nowEpoch: Date().timeIntervalSince1970)
            guard starts.removeValue(forKey: sessionId) != nil else { return }
            persist(starts)
        }
    }

    private static func storedStarts(nowEpoch: TimeInterval) -> [String: TimeInterval] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.filter { nowEpoch - $0.value <= maxStoredAgeSeconds }
    }

    private static func persist(_ starts: [String: TimeInterval]) {
        UserDefaults.standard.set(starts, forKey: key)
        UserDefaults.standard.synchronize()
    }
}

private struct AllocatedStreamSession: Sendable {
    let sessionId: String
    let title: String
    let serverIp: String
    let signalingServer: String
    let signalingUrl: String
    let signalingQueryParameters: String
    let signalingHeaders: [String]
    let streamingBaseUrl: String
    let mediaConnectionHost: String
    let mediaConnectionPort: Int
    let deviceId: String
    let isResume: Bool
    let status: Int
    let queuePosition: Int
    let seatSetupStep: Int
    let progressState: Int
    let adsRequired: Bool
    let requiredAdGateObserved: Bool
    let remainingSessionLimitSeconds: Int
    let pendingAd: AllocatedSessionAd?
    let rawJSON: String
    let rawSessionJSON: String

    var isReady: Bool {
        (status == 2 || status == 3) && !sessionId.isEmpty && !serverIp.isEmpty
    }

    var isPendingProgress: Bool {
        if [4, 5, 6].contains(status) { return true }
        guard status == 1 else { return false }
        return adsRequired || queuePosition > 0 || seatSetupStep > 0 || [1, 2, 3, 4].contains(progressState)
    }

    init(_ info: [String: Any]) {
        sessionId = Self.string(info["sessionId"])
        title = Self.string(info["title"]).isEmpty ? "GeForce NOW" : Self.string(info["title"])
        serverIp = Self.string(info["serverIp"])
        signalingServer = Self.string(info["signalingServer"])
        signalingUrl = Self.string(info["signalingUrl"])
        signalingQueryParameters = Self.string(info["signalingQueryParameters"])
        signalingHeaders = Self.stringArray(info["signalingHeaders"])
        streamingBaseUrl = Self.string(info["streamingBaseUrl"])
        let mediaConnectionInfo = info["mediaConnectionInfo"] as? [String: Any]
        mediaConnectionHost = Self.string(mediaConnectionInfo?["ip"])
        mediaConnectionPort = Self.int(mediaConnectionInfo?["port"])
        deviceId = Self.string(info["deviceId"])
        isResume = Self.bool(info["isResume"])
        status = Self.int(info["status"])
        queuePosition = Self.int(info["queuePosition"])
        seatSetupStep = Self.int(info["seatSetupStep"])
        progressState = Self.int(info["progressState"])
        let adState = info["adState"] as? [String: Any]
        adsRequired = Self.bool(adState?["isAdsRequired"])
        requiredAdGateObserved = Self.bool(info["requiredAdGateObserved"])
        remainingSessionLimitSeconds = Self.int(info["remainingSessionLimitSeconds"])
        pendingAd = Self.pendingAd(from: adState)
        rawSessionJSON = Self.string(info["rawSessionJSON"], fallback: "{}")
        rawJSON = Self.jsonString(info)
    }

    func markingRequiredAdGateObserved() -> AllocatedStreamSession {
        guard !requiredAdGateObserved else { return self }
        var dictionary = (try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8))) as? [String: Any] ?? [:]
        dictionary["requiredAdGateObserved"] = true
        return AllocatedStreamSession(dictionary)
    }

    var reportableSession: [String: Any] {
        [
            "sessionId": sessionId,
            "serverIp": serverIp,
            "streamingBaseUrl": streamingBaseUrl,
            "deviceId": deviceId,
        ]
    }

    private static func pendingAd(from adState: [String: Any]?) -> AllocatedSessionAd? {
        guard bool(adState?["isAdsRequired"]), let ads = adState?["sessionAds"] as? [[String: Any]] else { return nil }
        return ads.compactMap(AllocatedSessionAd.init(dictionary:)).first
    }

    private static func jsonString(_ value: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func string(_ value: Any?, fallback: String = "") -> String {
        if let value = value as? String { return value.isEmpty ? fallback : value }
        if let value = value as? NSString { let string = value as String; return string.isEmpty ? fallback : string }
        if let value = value as? NSNumber { return value.stringValue }
        return fallback
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.caseInsensitiveCompare("true") == .orderedSame || value.caseInsensitiveCompare("yes") == .orderedSame }
        return false
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [NSString] { return values.map { $0 as String } }
        return []
    }
}

private struct AllocatedSessionAd: Equatable, Sendable {
    let adId: String
    let mediaUrl: String
    let durationMs: Int
    let title: String

    var presentation: StreamSessionAdPresentation {
        StreamSessionAdPresentation(adId: adId, title: title, mediaUrl: mediaUrl, durationMs: durationMs)
    }

    init?(dictionary: [String: Any]) {
        let adId = Self.string(dictionary["adId"])
        guard !adId.isEmpty else { return nil }
        self.adId = adId
        title = Self.string(dictionary["title"])
        durationMs = Self.int(dictionary["durationMs"])
        mediaUrl = Self.bestMediaUrl(dictionary)
    }

    private static func bestMediaUrl(_ dictionary: [String: Any]) -> String {
        let mediaFiles = (dictionary["adMediaFiles"] as? [[String: Any]] ?? [])
            .compactMap { file -> (url: String, rank: Int)? in
                let url = string(file["mediaFileUrl"])
                guard !url.isEmpty else { return nil }
                return (url, mediaProfileRank(string(file["encodingProfile"])))
            }
            .sorted { $0.rank < $1.rank }
        if let url = mediaFiles.first?.url { return url }
        for key in ["mediaUrl", "videoUrl", "url", "adUrl"] {
            let url = string(dictionary[key])
            if !url.isEmpty { return url }
        }
        return ""
    }

    private static func mediaProfileRank(_ profile: String) -> Int {
        switch profile {
        case "mp4deinterlaced720p": return 0
        case "hlsadaptive": return 1
        case "webm": return 2
        default: return 100
        }
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSString { return value as String }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }
}

public enum OpenNOWStreamSessionError: LocalizedError, Sendable {
    case activeSessionConflict(StreamSessionConflict)
    case sessionAllocationFailed(String)
    case sessionStopFailed(String)
    case signalingFailed(String)
    case signalingUnavailable

    public var errorDescription: String? {
        switch self {
        case .activeSessionConflict(let conflict):
            conflict.isResumable
                ? "A GeForce NOW session is already active. Resume it or end it before launching another game."
                : "A GeForce NOW session is already active. End it before launching another game."
        case .sessionAllocationFailed(let message), .sessionStopFailed(let message), .signalingFailed(let message):
            message
        case .signalingUnavailable:
            "Signaling is not connected."
        }
    }
}
